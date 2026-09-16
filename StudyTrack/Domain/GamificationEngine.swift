import SwiftUI

/// Badge de gamification.
struct Badge: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let colorHex: String
    var earnedAt: Date?

    var isEarned: Bool { earnedAt != nil }
    var color: Color { Color(hex: colorHex) }
}

/// Événements générateurs d'XP.
enum XPEvent {
    static let videoWatched = 10
    static let videoSummarized = 5
    static let exerciseDone = 5
    static let exerciseCorrected = 3
    static let exerciseCorrect = 5
    static let seriesCompleted = 25
    static let courseCompleted = 100
    /// 1 XP par tranche de 15 min de travail enregistré.
    static let perQuarterHour = 1
}

/// Moteur de gamification (fonctions pures).
enum GamificationEngine {

    // MARK: XP

    static func xp(for course: Course) -> Int {
        var total = 0
        total += course.theoryItems.filter(\.isWatched).count * XPEvent.videoWatched
        total += course.theoryItems.filter(\.isSummarized).count * XPEvent.videoSummarized

        let all = course.allExercises
        total += all.filter(\.isDone).count * XPEvent.exerciseDone
        total += all.filter(\.isCorrected).count * XPEvent.exerciseCorrected
        total += all.filter { $0.correctness == .correct }.count * XPEvent.exerciseCorrect

        for series in course.series where series.isComplete {
            total += XPEvent.seriesCompleted
        }
        if ProgressEngine.progress(for: course).overallPercent >= 0.999 {
            total += XPEvent.courseCompleted
        }
        return total
    }

    static func xp(for sessions: [StudySession]) -> Int {
        let minutes = sessions.reduce(0) { $0 + $1.durationSeconds } / 60
        return (minutes / 15) * XPEvent.perQuarterHour
    }

    static func totalXP(courses: [Course], sessions: [StudySession]) -> Int {
        courses.reduce(0) { $0 + xp(for: $1) } + xp(for: sessions)
    }

    // MARK: Niveaux (courbe racine : palier suivant de plus en plus long)

    static func level(forXP xp: Int) -> Int {
        max(1, Int(sqrt(Double(max(0, xp)) / 100.0)) + 1)
    }

    /// XP cumulés nécessaires pour atteindre `level`.
    static func xpForLevel(_ level: Int) -> Int {
        let l = max(1, level) - 1
        return l * l * 100
    }

    static func xpInLevel(forXP xp: Int) -> Int {
        let level = level(forXP: xp)
        return xp - xpForLevel(level)
    }

    static func xpForNextLevel(_ level: Int) -> Int {
        xpForLevel(level + 1) - xpForLevel(level)
    }

    /// Progression (0…1) vers le niveau suivant.
    static func levelProgress(forXP xp: Int) -> Double {
        let level = level(forXP: xp)
        let need = xpForNextLevel(level)
        guard need > 0 else { return 1 }
        return min(1, max(0, Double(xpInLevel(forXP: xp)) / Double(need)))
    }

    // MARK: Séries (streak)

    /// Nombre de jours consécutifs (en remontant depuis aujourd'hui) avec au moins une session.
    static func currentStreak(sessions: [StudySession], reference: Date = Date()) -> Int {
        let cal = Calendar.current
        let days = Set(sessions.map { cal.startOfDay(for: $0.startedAt) })
        guard !days.isEmpty else { return 0 }

        var streak = 0
        var cursor = cal.startOfDay(for: reference)
        // Si rien aujourd'hui, on autorise la série à partir d'hier.
        if !days.contains(cursor) {
            guard let yesterday = cal.date(byAdding: .day, value: -1, to: cursor),
                  days.contains(yesterday) else { return 0 }
            cursor = yesterday
        }
        while days.contains(cursor) {
            streak += 1
            guard let previous = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }

    static func longestStreak(sessions: [StudySession]) -> Int {
        let cal = Calendar.current
        let days = Set(sessions.map { cal.startOfDay(for: $0.startedAt) }).sorted()
        guard !days.isEmpty else { return 0 }
        var best = 1
        var run = 1
        for index in 1..<days.count {
            let gap = cal.dateComponents([.day], from: days[index - 1], to: days[index]).day ?? 0
            if gap == 1 {
                run += 1
                best = max(best, run)
            } else {
                run = 1
            }
        }
        return best
    }

    // MARK: Badges

    static let catalog: [Badge] = [
        Badge(id: "first_video", title: "Première vidéo", detail: "Regarder une première vidéo de théorie", icon: "play.circle.fill", colorHex: "#8B5CF6"),
        Badge(id: "first_summary", title: "Premier résumé", detail: "Rédiger un premier résumé de vidéo", icon: "doc.text.fill", colorHex: "#14B8A6"),
        Badge(id: "first_exercise", title: "Premier exercice", detail: "Terminer un premier exercice", icon: "checkmark.circle.fill", colorHex: "#10B981"),
        Badge(id: "first_correction", title: "Première correction", detail: "Corriger un premier exercice", icon: "checkmark.seal.fill", colorHex: "#22C55E"),
        Badge(id: "first_series", title: "Série terminée", detail: "Terminer une série complète", icon: "list.bullet.rectangle.fill", colorHex: "#F59E0B"),
        Badge(id: "course_complete", title: "Cours à 100 %", detail: "Atteindre 100 % sur un cours", icon: "trophy.fill", colorHex: "#EAB308"),
        Badge(id: "streak_7", title: "7 jours d'affilée", detail: "Travailler 7 jours consécutifs", icon: "flame.fill", colorHex: "#F97316"),
        Badge(id: "streak_30", title: "30 jours d'affilée", detail: "Travailler 30 jours consécutifs", icon: "flame.circle.fill", colorHex: "#EF4444"),
        Badge(id: "exos_50", title: "50 exercices", detail: "Faire 50 exercices", icon: "50.circle.fill", colorHex: "#0EA5E9"),
        Badge(id: "hours_100", title: "100 h de travail", detail: "Cumuler 100 heures de travail", icon: "clock.badge.checkmark.fill", colorHex: "#6366F1"),
        Badge(id: "flashcards", title: "Roi des flashcards", detail: "Créer une session de flashcards", icon: "rectangle.stack.fill", colorHex: "#EC4899"),
        Badge(id: "group_session", title: "Esprit d'équipe", detail: "Organiser une session de groupe", icon: "person.3.fill", colorHex: "#8B5CF6")
    ]

    static func earnedBadges(courses: [Course],
                             sessions: [StudySession],
                             hasGroupSession: Bool = false) -> [Badge] {
        let allExercises = courses.flatMap(\.allExercises)
        let allVideos = courses.flatMap(\.theoryItems)
        let totalSeconds = sessions.reduce(0) { $0 + $1.durationSeconds }
        let streak = currentStreak(sessions: sessions)
        let anySeriesComplete = courses.contains { $0.series.contains(where: \.isComplete) }
        let anyCourseComplete = courses.contains {
            ProgressEngine.progress(for: $0).overallPercent >= 0.999
        }
        let doneExercises = allExercises.filter(\.isDone).count

        var earned: [Badge] = []
        for badge in catalog {
            let isEarned: Bool
            switch badge.id {
            case "first_video": isEarned = allVideos.contains(where: \.isWatched)
            case "first_summary": isEarned = allVideos.contains(where: \.isSummarized)
            case "first_exercise": isEarned = doneExercises >= 1
            case "first_correction": isEarned = allExercises.contains(where: \.isCorrected)
            case "first_series": isEarned = anySeriesComplete
            case "course_complete": isEarned = anyCourseComplete
            case "streak_7": isEarned = streak >= 7
            case "streak_30": isEarned = streak >= 30
            case "exos_50": isEarned = doneExercises >= 50
            case "hours_100": isEarned = totalSeconds >= 100 * 3600
            case "flashcards": isEarned = sessions.contains { $0.taskType == .flashcards }
            case "group_session": isEarned = hasGroupSession
            default: isEarned = false
            }
            if isEarned {
                var copy = badge
                copy.earnedAt = Date()
                earned.append(copy)
            }
        }
        return earned
    }
}
