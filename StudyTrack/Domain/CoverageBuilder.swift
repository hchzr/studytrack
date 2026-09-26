import Foundation

/// Traduit les modèles SwiftData en entrées de l'audit de couverture.
///
/// Toute la décision est dans `CoverageEngine`, qui est pur ; ici, seulement la
/// lecture des modèles.
enum CoverageBuilder {

    static func input(for course: Course) -> CourseCoverageInput {
        let termWeeks = course.term?.totalWeeks ?? 14
        let currentWeek = course.currentWeek
        let series = course.sortedSeries
        let exercises = course.allExercises

        // Une série dont la semaine est passée et qui n'est pas terminée. On ne
        // reproche rien à une série sans exercice : elle a son propre constat.
        let overdue = series
            .filter { $0.plannedWeek < currentWeek && !$0.isComplete && !$0.requiredExercises.isEmpty }
            .map(\.seriesNumber)

        let misplanned = series
            .filter { $0.plannedWeek < 1 || $0.plannedWeek > termWeeks }
            .map(\.seriesNumber)

        let exams = course.sortedExams
        let now = Date()

        return CourseCoverageInput(
            code: course.displayCode,
            name: course.name,
            isTracked: course.isTracked,
            hasTerm: course.term != nil,
            hasLectures: course.hasLectures,
            currentWeek: currentWeek,
            termWeeks: termWeeks,
            theoryCount: course.theoryItems.count,
            // Une lecture ou un chapitre n'a pas de durée : ce n'est pas un manque.
            theoryWithoutDuration: course.theoryItems.filter {
                $0.kind.hasDuration && $0.durationSeconds <= 0
            }.count,
            theoryWatchedNotSummarized: course.theoryItems.filter {
                $0.watchedAt != nil && $0.summarizedAt == nil
            }.count,
            seriesNumbersWithNoExercise: series.filter { $0.exercises.isEmpty }.map(\.seriesNumber),
            overdueSeries: overdue,
            misplannedSeries: misplanned,
            exerciseCount: exercises.count,
            notDoneExerciseCount: exercises.filter { !$0.isDone }.count,
            doneNotCorrectedCount: exercises.filter { $0.isDone && !$0.isCorrected }.count,
            toRedoCount: exercises.filter(\.redoRequired).count,
            examCount: exams.count,
            upcomingExamCount: exams.filter { $0.date >= now }.count)
    }

    static func report(courses: [Course],
                       term: AcademicTerm?,
                       hasTimetable: Bool) -> CoverageReport {
        CoverageEngine.report(courses: courses.map(input),
                              hasTerm: term != nil,
                              hasTimetable: hasTimetable)
    }
}
