import Foundation
import SwiftData

/// Le temps de travail **réel**, compté partout de la même façon : Aujourd'hui,
/// Moi, le bilan, la charge EPFL, les widgets, le Mac et les groupes.
///
/// **Ce qui compte, c'est l'étudiant·e qui le choisit** (`Counting`, Réglages › Chrono) :
/// les cours en amphi de l'horaire (tout seuls, seulement ceux confirmés, ou pas du tout),
/// les séances d'exercices de l'horaire, le chrono, les saisies à la main, Anki.
///
/// La règle des séances de l'horaire :
///   • une séance compte une fois **finie**, si elle n'a pas été marquée manquée, et si son
///     cours est **suivi** (un cours retiré ne gonfle plus les heures) ;
///   • un chrono lancé **pendant** une séance — de n'importe quel cours — ne compte pas deux
///     fois : la part qu'il recouvre est retirée de la séance (on ne peut pas être en amphi
///     et sur une autre série en même temps) ;
///   • une même séance lue deux fois (horaire `.ics` et calendrier) ne compte qu'une fois.
enum StudyTime {

    /// Ce qui compte dans les « heures travaillées ».
    struct Counting: Codable, Equatable {
        enum Lectures: String, Codable, CaseIterable { case automatic, confirmed, off }
        /// Les cours en amphi de l'horaire : tout seuls une fois finis, seulement ceux confirmés
        /// (« J'y étais »), ou jamais. Vaut aussi pour les sessions « Cours en amphi ».
        var lectures: Lectures = .automatic
        /// Les séances d'exercices de l'horaire, comptées comme un cours (sinon : seul le chrono
        /// lancé pendant la séance compte).
        var exerciseSessions = false
        var timer = true
        var manual = true
        var anki = true

        static let key = "settings.counting"
        static let standard = Counting()

        /// Le choix enregistré (le même `UserDefaults` que les réglages).
        static var current: Counting {
            get {
                guard let data = UserDefaults.standard.data(forKey: key),
                      let value = try? JSONDecoder().decode(Counting.self, from: data) else { return .standard }
                return value
            }
            set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
        }

        /// Une session (chrono, saisie, Anki) compte-t-elle ?
        func counts(_ session: StudySession) -> Bool {
            counts(taskType: session.taskTypeRaw, manual: session.isManual, anki: session.isFromAnki)
        }

        func counts(taskType raw: String, manual isManual: Bool, anki isAnki: Bool) -> Bool {
            if (TaskType(rawValue: raw) ?? .other).canonical == .lecture, lectures == .off { return false }
            if isAnki { return anki }
            return isManual ? manual : timer
        }

        /// Une séance de l'horaire compte-t-elle d'elle-même ?
        func counts(_ event: LinkedCalendarEvent, now: Date = Date()) -> Bool {
            guard !event.isSkipped, event.durationSeconds > 0,
                  TimeInterval(event.durationSeconds) <= StudyTime.longestLecture else { return false }
            // Un cours retiré (ou une séance sans cours) ne compte pas.
            if let course = event.course, !course.isTracked { return false }
            if event.course == nil { return false }
            switch event.kind {
            case .lecture:
                switch lectures {
                case .off: return false
                case .confirmed: return event.isAttended
                case .automatic: return event.endsAt <= now || event.isAttended
                }
            case .exerciseSession:
                return exerciseSessions && (event.endsAt <= now || event.isAttended)
            default:
                return false
            }
        }
    }

    /// Un intervalle de chrono (début, fin).
    struct Interval: Equatable {
        var start: Date
        var end: Date
    }

    /// Une durée comptée, rangée pour l'agrégation (jour, cours, nature).
    struct Block: Equatable {
        var start: Date
        var seconds: Int
        var courseCode: String?
        /// `TaskType.rawValue` d'une session, `lecture` pour un cours de l'horaire.
        var taskType: String
    }

    /// Au-delà, un « cours » n'en est pas un : journée entière, échéance mal
    /// datée, bloc personnel. Le plus long amphi de l'EPFL tient en 4 h.
    static let longestLecture: TimeInterval = 4.5 * 3600

    /// La part d'un cours qui compte : sa durée moins ce que recouvrent les
    /// chronos donnés (ceux du même cours).
    static func lectureSeconds(start: Date, end: Date, minus sessions: [Interval]) -> Int {
        guard end > start, end.timeIntervalSince(start) <= longestLecture else { return 0 }
        // Les recouvrements, fusionnés : deux chronos qui se chevauchent ne
        // retirent pas deux fois la même minute.
        let clipped = sessions
            .map { Interval(start: max($0.start, start), end: min($0.end, end)) }
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }
        var covered: TimeInterval = 0
        var cursor = start
        for part in clipped {
            let from = max(part.start, cursor)
            if part.end > from {
                covered += part.end.timeIntervalSince(from)
                cursor = part.end
            }
        }
        return max(0, Int(end.timeIntervalSince(start) - covered))
    }

    /// Les séances de l'horaire qui comptent (amphi, et exercices si choisi), moins ce que
    /// recouvrent les chronos comptés — de n'importe quel cours.
    static func lectureBlocks(events: [LinkedCalendarEvent], sessions: [StudySession],
                              counting: Counting = .current, now: Date = Date()) -> [Block] {
        let timers = sessions.filter { !$0.isFromAnki && counting.counts($0) }.map {
            Interval(start: $0.startedAt, end: $0.startedAt.addingTimeInterval(TimeInterval($0.durationSeconds)))
        }
        var seen = Set<String>()
        return events.filter { counting.counts($0, now: now) }
            .sorted { $0.startsAt < $1.startsAt }
            .compactMap { event in
                // La même séance lue deux fois (même cours, mêmes heures) : une seule.
                let key = "\(event.course?.id.uuidString ?? event.title)|\(event.startsAt.timeIntervalSince1970)|\(event.endsAt.timeIntervalSince1970)"
                guard seen.insert(key).inserted else { return nil }
                // Une séance pas encore finie (« J'y suis ») ne compte que jusqu'à maintenant.
                let end = min(event.endsAt, max(event.startsAt, now))
                let seconds = lectureSeconds(start: event.startsAt, end: end, minus: timers)
                guard seconds > 0 else { return nil }
                return Block(start: event.startsAt, seconds: seconds, courseCode: event.course?.code,
                             taskType: event.kind == .lecture ? "lecture" : TaskType.exercise.rawValue)
            }
    }

    /// Tout ce qui compte : les sessions choisies (chrono, saisies, Anki), puis les séances.
    static func blocks(events: [LinkedCalendarEvent], sessions: [StudySession],
                       counting: Counting = .current, now: Date = Date()) -> [Block] {
        sessions.filter { counting.counts($0) }
            .map { Block(start: $0.startedAt, seconds: $0.durationSeconds,
                         courseCode: $0.course?.code, taskType: $0.taskTypeRaw) }
            + lectureBlocks(events: events, sessions: sessions, counting: counting, now: now)
    }

    /// Tout ce qui compte entre deux dates, lu dans la base avec des
    /// prédicats : seules les sessions et les séances de la fenêtre sont chargées.
    ///
    /// C'est **la** définition du temps de travail : Aujourd'hui, Moi, le
    /// bilan, les widgets (iPhone et Mac) et la barre des menus l'utilisent.
    static func blocks(in context: ModelContext, from start: Date, to end: Date) -> [Block] {
        let sessions = (try? context.fetch(FetchDescriptor<StudySession>(
            predicate: #Predicate { $0.startedAt >= start && $0.startedAt < end }))) ?? []
        let events = (try? context.fetch(FetchDescriptor<LinkedCalendarEvent>(
            predicate: #Predicate { $0.startsAt >= start && $0.startsAt < end }))) ?? []
        return blocks(events: events, sessions: sessions)
    }

    /// Le temps compté entre deux dates.
    static func seconds(in context: ModelContext, from start: Date, to end: Date) -> Int {
        total(blocks(in: context, from: start, to: end))
    }

    /// Le temps compté aujourd'hui.
    static func today(in context: ModelContext, now: Date = Date()) -> Int {
        let start = DateUtils.startOfDay(now)
        return seconds(in: context, from: start, to: DateUtils.addDays(1, to: start))
    }

    /// Le temps compté cette semaine (lundi → dimanche).
    static func thisWeek(in context: ModelContext, now: Date = Date()) -> Int {
        let start = DateUtils.startOfWeek(now)
        return seconds(in: context, from: start, to: DateUtils.addDays(7, to: start))
    }

    /// La somme des secondes de ces blocs.
    static func total(_ blocks: [Block]) -> Int {
        blocks.reduce(0) { $0 + $1.seconds }
    }

    /// Les secondes par jour d'une semaine (lundi = 0).
    static func days(of blocks: [Block], weekStart: Date) -> [Int] {
        var days = Array(repeating: 0, count: 7)
        for block in blocks {
            let index = DateUtils.daysBetween(weekStart, block.start)
            if days.indices.contains(index), block.start >= weekStart { days[index] += block.seconds }
        }
        return days
    }
}
