import Foundation
import SwiftData

/// Miroir local d'un événement du calendrier système (EventKit).
@Model
final class LinkedCalendarEvent {
    var id: UUID = UUID()
    var externalEventID: String?
    var sourceCalendarID: String?
    var title: String = ""
    var startsAt: Date = Date.now
    var endsAt: Date = Date.now
    var location: String = ""
    var kindRaw: String = ""
    var course: Course?
    var isAttended: Bool = false
    /// Cours magistral **manqué**, signalé à la main. Un cours de l'horaire
    /// compte dès qu'il est fini, sauf s'il est marqué ici.
    var isSkipped: Bool = false
    /// Le type a été choisi **à la main** (« c'est une séance d'exercices ») :
    /// aucune synchronisation ne le recalcule, et les autres semaines du même
    /// créneau le reprennent.
    var kindIsManual: Bool = false
    var notes: String = ""
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

    /// Le cours magistral compte dans les heures d'amphi : fini, et pas manqué.
    /// Une **séance d'exercices** ne compte jamais d'elle-même — on y reste plus
    /// ou moins longtemps : elle se chronomètre.
    /// (La règle complète, choisie par l'étudiant·e : `StudyTime.Counting`.)
    var countsAsAttendedLecture: Bool {
        isLecture && StudyTime.Counting.current.counts(self)
    }

    /// La séance peut-elle être cochée (« j'y étais » / « manqué ») selon ce qui compte ?
    func isCheckable(_ counting: StudyTime.Counting = .current, now: Date = Date()) -> Bool {
        guard course != nil, startsAt <= now else { return false }
        switch kind {
        case .lecture: return counting.lectures != .off
        case .exerciseSession: return counting.exerciseSessions
        default: return false
        }
    }

    /// Cochée : elle compte dans les heures.
    func isChecked(_ counting: StudyTime.Counting = .current, now: Date = Date()) -> Bool {
        counting.counts(self, now: now)
    }

    /// Le geste de la coche : en mode « si confirmés », confirmer (« J'y étais ») ; sinon
    /// marquer manqué ou compter de nouveau.
    func toggleChecked(_ counting: StudyTime.Counting = .current, now: Date = Date()) {
        let on = isChecked(counting, now: now)
        if kind == .lecture && counting.lectures == .confirmed {
            isAttended = !on
            if !on { isSkipped = false }
        } else {
            isSkipped = on
            if on { isAttended = false } else if endsAt > now { isAttended = true }
        }
    }

    /// Ce qui a sa place dans l'agenda : l'horaire (cours, exercices), les
    /// évaluations, les sessions de révision — pas l'agenda personnel.
    var isAcademic: Bool {
        switch kind {
        case .lecture, .exerciseSession, .midterm, .exam, .study: return true
        default: return course != nil
        }
    }
}
