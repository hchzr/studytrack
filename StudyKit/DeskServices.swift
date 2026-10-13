import Foundation
import Observation
import SwiftData

/// Un créneau de l'horaire, avec ce que le bureau en montre (la salle).
struct ScheduledClass: Identifiable, Equatable {
    var id: UUID
    var slot: FocusContext.Slot
    var title: String
    var location: String
    var colorHex: String

    var kindLabel: String { slot.kind.label }
}

/// L'horaire du jour, pour le bureau, le panneau de la barre des menus et
/// l'accueil — une lecture, la même partout.
@MainActor
enum DeskSchedule {
    /// Les créneaux de cours de la journée de `now` (cours suivis, pas manqués).
    static func today(context: ModelContext, now: Date = Date(), calendar: Calendar = .current) -> [ScheduledClass] {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? now
        let descriptor = FetchDescriptor<LinkedCalendarEvent>(
            predicate: #Predicate { $0.startsAt >= start && $0.startsAt < end },
            sortBy: [SortDescriptor(\.startsAt)])
        let events = (try? context.fetch(descriptor)) ?? []
        return classes(from: events)
    }

    static func classes(from events: [LinkedCalendarEvent]) -> [ScheduledClass] {
        events.compactMap { event in
            guard event.isAcademic, !event.isSkipped, let course = event.course, course.isTracked else { return nil }
            return ScheduledClass(id: event.id,
                                  slot: FocusContext.Slot(courseID: course.id, courseCode: course.displayCode, kind: event.kind,
                                                          start: event.startsAt, end: event.endsAt),
                                  title: course.name, location: event.location, colorHex: course.colorHex)
        }
    }

    /// Le cours en cours (ou qui commence dans dix minutes).
    static func current(in classes: [ScheduledClass], at now: Date = Date()) -> ScheduledClass? {
        let slots = classes.map(\.slot)
        guard let slot = LectureClock.current(at: now, in: slots) else { return nil }
        return classes.first { $0.slot == slot }
    }

    /// Le prochain créneau du jour.
    static func next(in classes: [ScheduledClass], after now: Date = Date()) -> ScheduledClass? {
        let slots = classes.map(\.slot)
        guard let slot = LectureClock.next(after: now, in: slots) else { return nil }
        return classes.first { $0.slot == slot }
    }

    /// Le créneau de ce cours qui a commencé le plus récemment aujourd'hui
    /// (l'origine des repères, même après la fin du cours).
    static func latest(of courseID: UUID?, in classes: [ScheduledClass], at now: Date = Date()) -> ScheduledClass? {
        let started = classes.filter { item in
            item.slot.courseID == courseID && item.slot.start.addingTimeInterval(-LectureClock.lead) <= now
        }
        return started.max { $0.slot.start < $1.slot.start }
    }

    /// La forme du bureau pour cette session.
    static func moment(taskType: TaskType, inGroup: Bool, course: Course?) -> DeskMoment {
        DeskMoment.resolve(taskType: taskType, inGroup: inGroup, daysToExam: course?.nextExam?.daysUntil)
    }
}

/// Les repères des cours : un toucher, synchronisé entre l'iPhone et le Mac
/// (iCloud clé-valeur). On touche « Repère » sur l'iPhone en amphi ; le soir,
/// le Mac ouvre l'enregistrement à la bonne minute.
@MainActor
@Observable
final class LectureMarkStore {
    static let shared = LectureMarkStore()
    private static let key = "lecture.marks"

    private(set) var marks: [LectureMark] = []
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        marks = LectureMarks.decode(NSUbiquitousKeyValueStore.default.data(forKey: Self.key))
        observer = NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                                                          object: NSUbiquitousKeyValueStore.default, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func reload() {
        marks = LectureMarks.decode(NSUbiquitousKeyValueStore.default.data(forKey: Self.key))
    }

    /// Pose un repère maintenant, dans le créneau `classStart`.
    @discardableResult
    func mark(courseID: UUID, classStart: Date, at now: Date = Date()) -> Bool {
        let before = marks.count
        marks = LectureMarks.adding(LectureMark(courseID: courseID, classStart: classStart, at: now), to: marks, now: now)
        save()
        return marks.count > before
    }

    func remove(_ mark: LectureMark) {
        marks.removeAll { $0.id == mark.id }
        save()
    }

    func of(courseID: UUID, classStart: Date) -> [LectureMark] {
        LectureMarks.of(courseID: courseID, classStart: classStart, in: marks)
    }

    private func save() {
        NSUbiquitousKeyValueStore.default.set(LectureMarks.encode(marks), forKey: Self.key)
        NSUbiquitousKeyValueStore.default.synchronize()
    }
}
