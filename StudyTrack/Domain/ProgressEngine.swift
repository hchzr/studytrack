import Foundation

/// Agrégat des pourcentages d'un cours (théorie / exercices / corrections).
struct CourseProgress: Equatable {
    var videoCount: Int = 0
    var watchedCount: Int = 0
    var summarizedCount: Int = 0
    var exerciseCount: Int = 0
    var doneCount: Int = 0
    var correctedCount: Int = 0
    var bonusCount: Int = 0
    var bonusDoneCount: Int = 0
    var wrongOrRedoCount: Int = 0

    static func ratio(_ value: Int, _ total: Int) -> Double {
        total <= 0 ? 0 : Double(value) / Double(total)
    }

    /// Théorie : vidéos regardées / total.
    var theoryPercent: Double { Self.ratio(watchedCount, videoCount) }
    /// Résumés : vidéos résumées / vidéos regardées.
    var summaryPercent: Double { Self.ratio(summarizedCount, watchedCount) }
    /// Exercices : exos (hors bonus) faits / total.
    var exercisePercent: Double { Self.ratio(doneCount, exerciseCount) }
    /// Corrections : exos corrigés / exos faits.
    var correctionPercent: Double { Self.ratio(correctedCount, doneCount) }

    /// Moyenne des trois axes principaux (gamification / récap).
    var overallPercent: Double {
        (theoryPercent + exercisePercent + correctionPercent) / 3
    }

    var hasTheory: Bool { videoCount > 0 }
    var hasExercises: Bool { exerciseCount > 0 }
    var hasCorrections: Bool { doneCount > 0 }
    var remainingVideos: Int { max(0, videoCount - watchedCount) }
    var remainingExercises: Int { max(0, exerciseCount - doneCount) }
}

/// Progression d'une semaine donnée.
struct WeeklyProgress: Identifiable, Equatable {
    var week: Int
    var videoCount: Int = 0
    var watchedCount: Int = 0
    var exerciseCount: Int = 0
    var doneCount: Int = 0
    var correctedCount: Int = 0
    /// Durée totale des vidéos restantes pour cette semaine.
    var remainingVideoSeconds: Int = 0

    var id: Int { week }
    var theoryPercent: Double { CourseProgress.ratio(watchedCount, videoCount) }
    var exercisePercent: Double { CourseProgress.ratio(doneCount, exerciseCount) }
    var correctionPercent: Double { CourseProgress.ratio(correctedCount, doneCount) }
    var overallPercent: Double {
        (theoryPercent + exercisePercent + correctionPercent) / 3
    }
    var hasItems: Bool { videoCount > 0 || exerciseCount > 0 }
}

/// Moteur de calcul des pourcentages (fonctions pures, testables).
enum ProgressEngine {

    // MARK: Global

    static func progress(for course: Course) -> CourseProgress {
        var p = CourseProgress()
        let videos = course.theoryItems
        p.videoCount = videos.count
        p.watchedCount = videos.filter { $0.isWatched }.count
        p.summarizedCount = videos.filter { $0.isSummarized }.count

        let all = course.allExercises
        let required = all.filter { !$0.isBonus }
        p.bonusCount = all.filter(\.isBonus).count
        p.bonusDoneCount = all.filter { $0.isBonus && $0.isDone }.count
        p.exerciseCount = required.count
        p.doneCount = required.filter(\.isDone).count
        p.correctedCount = required.filter(\.isCorrected).count
        p.wrongOrRedoCount = all.filter {
            $0.redoRequired || $0.correctness == .wrong
        }.count
        return p
    }

    // MARK: Par semaine

    static func weekProgress(for course: Course, week: Int) -> WeeklyProgress {
        var w = WeeklyProgress(week: week)

        let videos = course.theoryItems.filter { $0.plannedWeek == week }
        w.videoCount = videos.count
        w.watchedCount = videos.filter(\.isWatched).count
        w.remainingVideoSeconds = videos.filter { !$0.isWatched }
            .reduce(0) { $0 + $1.durationSeconds }

        let exercises = course.series
            .filter { $0.plannedWeek == week }
            .flatMap(\.exercises)
            .filter { !$0.isBonus }
        w.exerciseCount = exercises.count
        w.doneCount = exercises.filter(\.isDone).count
        w.correctedCount = exercises.filter(\.isCorrected).count
        return w
    }

    /// Toutes les semaines qui contiennent au moins une vidéo ou un exercice.
    static func weeklyProgress(for course: Course) -> [WeeklyProgress] {
        var weeks = Set(course.theoryItems.map(\.plannedWeek))
        weeks.formUnion(course.series.map(\.plannedWeek))
        weeks = weeks.filter { $0 > 0 }
        return weeks.sorted().map { weekProgress(for: course, week: $0) }
    }

    // MARK: Durées de vidéo

    /// Total de vidéo à regarder pour une semaine donnée (toutes vidéos planifiées).
    static func plannedVideoSeconds(for course: Course, week: Int) -> Int {
        course.theoryItems.filter { $0.plannedWeek == week }
            .reduce(0) { $0 + $1.durationSeconds }
    }

    /// Vidéos restantes pour une semaine, triées.
    static func remainingVideos(for course: Course, week: Int) -> [TheoryItem] {
        course.sortedTheoryItems.filter { $0.plannedWeek == week && !$0.isWatched }
    }

    /// Exercices restants pour une semaine donnée.
    static func remainingExercises(for course: Course, week: Int) -> [Exercise] {
        course.sortedSeries
            .filter { $0.plannedWeek == week }
            .flatMap(\.sortedExercises)
            .filter { !$0.isDone }
    }
}
