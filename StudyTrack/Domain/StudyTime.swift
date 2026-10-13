import Foundation
import SwiftData

/// Le temps de travail **réel**, compté partout de la même façon : Aujourd'hui,
/// Moi, le bilan, la charge EPFL, les widgets, le Mac et les groupes —
/// les sessions (chrono, saisies, Anki) **plus** les cours suivis.
///
/// La règle :
///   • une heure de **cours** (amphi) de l'horaire compte toute seule, une fois
///     passée — sauf si elle a été marquée manquée ;
///   • une séance d'**exercices** officielle ne compte **jamais** d'elle-même :
///     on peut y aller ou pas, y rester une heure ou deux. Seul le chrono lancé
///     pendant la séance compte ;
///   • un chrono lancé **pendant** un cours ne compte pas deux fois : la part du
///     cours qu'il recouvre est retirée du cours.
///
/// Chaque écran avait sa propre somme : Aujourd'hui ignorait les cours, le bilan
/// et la charge les ajoutaient au chrono qui les recouvrait, et les groupes ne
/// voyaient que le chrono.
enum StudyTime {

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

    /// Les cours qui comptent, à partir de l'horaire et des sessions.
    static func lectureBlocks(events: [LinkedCalendarEvent], sessions: [StudySession]) -> [Block] {
        let byCourse = Dictionary(grouping: sessions.filter { $0.course != nil }) { $0.course!.id }
        return events.filter(\.countsAsAttendedLecture).compactMap { event in
            let own = (event.course.flatMap { byCourse[$0.id] } ?? []).map {
                Interval(start: $0.startedAt, end: $0.startedAt.addingTimeInterval(TimeInterval($0.durationSeconds)))
            }
            let seconds = lectureSeconds(start: event.startsAt, end: event.endsAt, minus: own)
            guard seconds > 0 else { return nil }
            return Block(start: event.startsAt, seconds: seconds, courseCode: event.course?.code, taskType: "lecture")
        }
    }

    /// Tout ce qui compte : les sessions (chrono, saisies, Anki), puis les cours.
    static func blocks(events: [LinkedCalendarEvent], sessions: [StudySession]) -> [Block] {
        sessions.map { Block(start: $0.startedAt, seconds: $0.durationSeconds,
                             courseCode: $0.course?.code, taskType: $0.taskTypeRaw) }
            + lectureBlocks(events: events, sessions: sessions)
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
