import Foundation
import EventKit
import SwiftData

/// Événement lu depuis le calendrier système.
struct ExternalCalendarEvent {
    var identifier: String
    var title: String
    var startsAt: Date
    var endsAt: Date
    var location: String
    var calendarTitle: String
    var notes: String
    var isAllDay: Bool = false
}

/// Spécification de création d'un événement dans le calendrier système.
struct CalendarEventSpec {
    var title: String
    var startsAt: Date
    var endsAt: Date
    var location: String = ""
    var notes: String = ""
    var calendarTitle: String = "StudyTrack"
}

/// Abstraction du calendrier (EventKit aujourd'hui, CalDAV demain).
protocol CalendarService: AnyObject {
    var hasAccess: Bool { get }
    var authorizationDenied: Bool { get }
    func requestAccess() async -> Bool
    func availableCalendarTitles() -> [String]
    func fetchEvents(from start: Date, to end: Date) -> [ExternalCalendarEvent]
    func createEvent(_ spec: CalendarEventSpec) -> String?
    func deleteEvent(identifier: String)
}

/// Implémentation EventKit (iOS 17+).
final class EventKitCalendarService: CalendarService {
    private let store = EKEventStore()

    var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    var authorizationDenied: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        return status == .denied || status == .restricted
    }

    func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    func availableCalendarTitles() -> [String] {
        store.calendars(for: .event).map(\.title).sorted()
    }

    func fetchEvents(from start: Date, to end: Date) -> [ExternalCalendarEvent] {
        guard hasAccess else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map { event in
            ExternalCalendarEvent(
                identifier: event.eventIdentifier ?? UUID().uuidString,
                title: event.title ?? "Sans titre",
                startsAt: event.startDate,
                endsAt: event.endDate,
                location: event.location ?? "",
                calendarTitle: event.calendar?.title ?? "",
                notes: event.notes ?? "",
                isAllDay: event.isAllDay
            )
        }
    }

    func createEvent(_ spec: CalendarEventSpec) -> String? {
        guard hasAccess else { return nil }
        let event = EKEvent(eventStore: store)
        event.title = spec.title
        event.startDate = spec.startsAt
        event.endDate = spec.endsAt
        event.location = spec.location
        event.notes = spec.notes
        event.calendar = calendar(named: spec.calendarTitle)
        do {
            try store.save(event, span: .thisEvent, commit: true)
            return event.eventIdentifier
        } catch {
            return nil
        }
    }

    func deleteEvent(identifier: String) {
        guard hasAccess, let event = store.event(withIdentifier: identifier) else { return }
        try? store.remove(event, span: .thisEvent, commit: true)
    }

    private func calendar(named title: String) -> EKCalendar? {
        if let existing = store.calendars(for: .event).first(where: { $0.title == title }) {
            return existing
        }
        guard let source = store.defaultCalendarForNewEvents?.source else {
            return store.defaultCalendarForNewEvents
        }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = title
        calendar.source = source
        try? store.saveCalendar(calendar, commit: true)
        return calendar
    }
}

/// Synchronisation du calendrier système vers les événements locaux liés aux cours.
enum CalendarSync {

    struct SyncResult {
        var imported = 0
        var updated = 0
        var total = 0
    }

    @discardableResult
    static func sync(context: ModelContext,
                     courses: [Course],
                     service: CalendarService,
                     daysBack: Int = 30,
                     daysForward: Int = 150) -> SyncResult {
        var result = SyncResult()
        guard service.hasAccess else { return result }

        let start = DateUtils.addDays(-daysBack, to: Date())
        let end = DateUtils.addDays(daysForward, to: Date())
        let external = service.fetchEvents(from: start, to: end)
        result.total = external.count

        var existing = (try? context.fetch(FetchDescriptor<LinkedCalendarEvent>())) ?? []

        for item in external {
            // L'agenda n'est pas le calendrier personnel : on ne garde que ce qui
            // se rattache à un cours, ou qui est une évaluation ou une révision.
            // Les journées entières (anniversaires, congés) n'y entrent jamais.
            let course = matchCourse(for: item.title, in: courses)
            let kind = classify(title: item.title, course: course)
            let academic = course != nil || [.midterm, .exam, .study].contains(kind)
            guard !item.isAllDay, academic else {
                if let stale = existing.first(where: { $0.externalEventID == item.identifier }) {
                    context.delete(stale)
                    existing.removeAll { $0 === stale }
                }
                continue
            }
            if let match = existing.first(where: { $0.externalEventID == item.identifier }) {
                match.title = item.title
                match.startsAt = item.startsAt
                match.endsAt = item.endsAt
                match.location = item.location
                match.lastSyncedAt = Date()
                if match.course == nil {
                    match.course = matchCourse(for: item.title, in: courses)
                }
                match.kind = classify(title: item.title, course: match.course)
                result.updated += 1
                continue
            }

            let linked = LinkedCalendarEvent(
                externalEventID: item.identifier,
                sourceCalendarID: item.calendarTitle,
                title: item.title,
                startsAt: item.startsAt,
                endsAt: item.endsAt,
                location: item.location,
                kind: classify(title: item.title, course: nil)
            )
            linked.course = matchCourse(for: item.title, in: courses)
            linked.kind = classify(title: item.title, course: linked.course)
            linked.lastSyncedAt = Date()
            context.insert(linked)
            existing.append(linked)
            result.imported += 1
        }

        try? context.save()
        return result
    }

    /// Un événement lié a-t-il sa place dans l'agenda ?
    static func isAcademic(_ event: LinkedCalendarEvent) -> Bool { event.isAcademic }

    /// Devine le cours d'un événement à partir de son titre (code ou nom).
    static func matchCourse(for title: String, in courses: [Course]) -> Course? {
        let haystack = title.uppercased()
        for course in courses where haystack.contains(course.code.uppercased()) {
            return course
        }
        for course in courses {
            let tokens = course.name.uppercased().split(separator: " ").filter { $0.count >= 4 }
            if !tokens.isEmpty, tokens.allSatisfy({ haystack.contains($0) }) {
                return course
            }
        }
        return nil
    }

    /// Devine le type d'événement à partir de son titre.
    static func classify(title: String, course: Course?) -> CalendarEventKind {
        let haystack = title.lowercased()
        if haystack.contains("midterm") || haystack.contains("mid-term") || haystack.contains("contrôle") {
            return .midterm
        }
        if haystack.contains("examen") || haystack.contains("exam") || haystack.contains("final") {
            return .exam
        }
        if haystack.contains("exercice") || haystack.contains("exercise") || haystack.contains("série")
            || haystack.contains("serie") || haystack.contains(" tp") || haystack.contains("labo") {
            return .exerciseSession
        }
        if haystack.contains("cours") || haystack.contains("lecture") || haystack.contains("amphi") {
            return .lecture
        }
        if haystack.contains("révision") || haystack.contains("revision") || haystack.contains("étude") {
            return .study
        }
        return course != nil ? .lecture : .other
    }
}
