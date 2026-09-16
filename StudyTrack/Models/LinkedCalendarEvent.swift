import Foundation
import SwiftData

/// Miroir local d'un événement du calendrier système (EventKit).
@Model
final class LinkedCalendarEvent {
    @Attribute(.unique) var id: UUID
    var externalEventID: String?
    var sourceCalendarID: String?
    var title: String
    var startsAt: Date
    var endsAt: Date
    var location: String
    var kindRaw: String
    var course: Course?
    var isAttended: Bool
    var notes: String
    var lastSyncedAt: Date?

    init(id: UUID = UUID(),
         externalEventID: String? = nil,
         sourceCalendarID: String? = nil,
         title: String,
         startsAt: Date,
         endsAt: Date,
         location: String = "",
         kind: CalendarEventKind = .other,
         isAttended: Bool = false) {
        self.id = id
        self.externalEventID = externalEventID
        self.sourceCalendarID = sourceCalendarID
        self.title = title
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.location = location
        self.kindRaw = kind.rawValue
        self.isAttended = isAttended
        self.notes = ""
    }

    var kind: CalendarEventKind {
        get { CalendarEventKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }

    var durationSeconds: Int { max(0, Int(endsAt.timeIntervalSince(startsAt))) }
    var durationLabel: String { DateUtils.durationLabel(seconds: durationSeconds) }
    var isLecture: Bool { kind == .lecture }
}
