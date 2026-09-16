import Foundation

/// Agrégats de sessions pour l'historique et les graphiques (fonctions pures).
enum SessionStats {

    /// Total par jour sur les `days` derniers jours, le plus ancien en premier.
    ///
    /// Chaque jour est présent, même à zéro : un graphique qui saute les jours vides
    /// masque précisément les jours qu'il faut voir.
    struct DayTotal: Identifiable, Equatable {
        var day: Date
        var seconds: Int
        var id: Date { day }
        var isEmpty: Bool { seconds == 0 }
    }

    static func dailyTotals(_ sessions: [StudySession],
                            days: Int,
                            endingAt reference: Date = Date()) -> [DayTotal] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: reference)
        var buckets: [Date: Int] = [:]
        for session in sessions {
            let day = calendar.startOfDay(for: session.startedAt)
            buckets[day, default: 0] += session.durationSeconds
        }
        return (0..<max(days, 1)).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return DayTotal(day: day, seconds: buckets[day] ?? 0)
        }
    }

    /// Sessions regroupées par jour, le plus récent d'abord, chaque jour trié du
    /// plus récent au plus ancien.
    struct DayGroup: Identifiable {
        var day: Date
        var sessions: [StudySession]
        var id: Date { day }
        var totalSeconds: Int { sessions.reduce(0) { $0 + $1.durationSeconds } }
    }

    static func groupedByDay(_ sessions: [StudySession]) -> [DayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: sessions) { calendar.startOfDay(for: $0.startedAt) }
        return grouped.keys.sorted(by: >).map { day in
            DayGroup(day: day,
                     sessions: (grouped[day] ?? []).sorted { $0.startedAt > $1.startedAt })
        }
    }

    /// Moyenne quotidienne sur les jours **actifs** seulement : une moyenne qui
    /// compte les jours à zéro ne dit rien sur la longueur d'une séance.
    static func averageActiveDaySeconds(_ totals: [DayTotal]) -> Int {
        let active = totals.filter { !$0.isEmpty }
        guard !active.isEmpty else { return 0 }
        return active.reduce(0) { $0 + $1.seconds } / active.count
    }
}
