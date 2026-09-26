import Foundation
import SwiftData

/// Données d'exemple (semestre EPFL relatif à aujourd'hui) pour démarrer l'app.
enum SeedData {

    static func seedIfNeeded(_ context: ModelContext, settings: SettingsStore) {
        let existing = (try? context.fetchCount(FetchDescriptor<Course>())) ?? 0
        guard existing == 0 else { return }
        seed(context)
        settings.hasSeededSampleData = true
    }

    @discardableResult
    static func seed(_ context: ModelContext) -> AcademicTerm {
        let calendar = Calendar.current
        let today = Date()
        let termStart = DateUtils.currentAutumnOrSpringStart(reference: today).start
        let termEnd = DateUtils.addWeeks(14, to: termStart)
        let month = calendar.component(.month, from: today)
        let season: TermSeason = (month >= 2 && month <= 7) ? .spring : .autumn

        let term = AcademicTerm(year: calendar.component(.year, from: today),
                                season: season,
                                startDate: termStart,
                                endDate: termEnd,
                                totalWeeks: 14)
        context.insert(term)

        // MARK: CS-250
        let cs = Course(code: "CS-250",
                        name: "Algorithms I",
                        credits: 6,
                        colorHex: "#4F46E5",
                        iconName: "chevron.left.forwardslash.chevron.right",
                        term: term,
                        weeklyLectureHours: 3,
                        weeklyExerciseHours: 2,
                        lecturer: "Prof. Exemple")
        context.insert(cs)
        addTheory(to: cs, context: context, specs: [
            (1, "1.1", "Introduction & complexité", 2700, 1),
            (1, "1.2", "Analyse asymptotique", 3120, 1),
            (1, "1.3", "Diviser pour régner", 2400, 1),
            (2, "2.1", "Récurrences & tri", 2880, 2),
            (2, "2.2", "Tas et files de priorité", 3300, 2),
            (3, "3.1", "Graphes : parcours", 3000, 3),
            (3, "3.2", "Plus courts chemins", 3240, 3),
            (4, "4.1", "Programmation dynamique", 3600, 4)
        ])
        addSeries(to: cs, context: context, number: 1, week: 1, exercises: [("1.1", false), ("1.2", false), ("1.3", true)])
        addSeries(to: cs, context: context, number: 2, week: 2, exercises: [("2.1", false), ("2.2", false), ("2.3", true)])
        addSeries(to: cs, context: context, number: 3, week: 3, exercises: [("3.1", false), ("3.2", false)])
        addSeries(to: cs, context: context, number: 4, week: 4, exercises: [("4.1", false), ("4.2", false), ("4.3", true)])
        addExams(to: cs, context: context, termStart: termStart, specs: [
            (.midterm, "Midterm", 6, 30, "SG1"),
            (.exam, "Examen final", 14, 70, "Polydôme")
        ])

        // MARK: MATH-101
        let math = Course(code: "MATH-101",
                          name: "Analyse I",
                          credits: 7,
                          colorHex: "#0EA5E9",
                          iconName: "function",
                          term: term,
                          weeklyLectureHours: 4,
                          weeklyExerciseHours: 2,
                          lecturer: "Prof. Exemple")
        context.insert(math)
        addTheory(to: math, context: context, specs: [
            (1, "1.1", "Suites et limites", 3000, 1),
            (1, "1.2", "Continuité", 2700, 1),
            (2, "2.1", "Dérivées", 2820, 2),
            (2, "2.2", "Théorèmes de la moyenne", 2400, 2),
            (3, "3.1", "Intégration", 3180, 3)
        ])
        addSeries(to: math, context: context, number: 1, week: 1, exercises: [("1.1", false), ("1.2", false)])
        addSeries(to: math, context: context, number: 2, week: 2, exercises: [("2.1", false), ("2.2", false), ("2.3", true)])
        addSeries(to: math, context: context, number: 3, week: 3, exercises: [("3.1", false), ("3.2", true)])
        addExams(to: math, context: context, termStart: termStart, specs: [
            (.midterm, "Midterm", 7, 30, "CM1"),
            (.exam, "Examen final", 14, 70, "Polydôme")
        ])

        // MARK: PHYS-101
        let phys = Course(code: "PHYS-101",
                          name: "Physique générale I",
                          credits: 5,
                          colorHex: "#10B981",
                          iconName: "atom",
                          term: term,
                          weeklyLectureHours: 3,
                          weeklyExerciseHours: 1.5,
                          lecturer: "Prof. Exemple")
        context.insert(phys)
        addTheory(to: phys, context: context, specs: [
            (1, "1.1", "Cinématique", 2400, 1),
            (1, "1.2", "Dynamique", 2640, 1),
            (2, "2.1", "Travail et énergie", 2520, 2)
        ])
        addSeries(to: phys, context: context, number: 1, week: 1, exercises: [("1.1", false), ("1.2", false)])
        addSeries(to: phys, context: context, number: 2, week: 2, exercises: [("2.1", false)])
        addExams(to: phys, context: context, termStart: termStart, specs: [
            (.exam, "Examen final", 14, 100, "Polydôme")
        ])

        // MARK: PROJ-101 — cours sans heures d'amphi
        // Démontre le réglage « ce cours a-t-il un cours ? » : aucune heure d'amphi
        // n'est attendue, tout le travail est du personnel / exercices.
        let project = Course(code: "PROJ-101",
                             name: "Projet de semestre",
                             credits: 8,
                             colorHex: "#8B5CF6",
                             iconName: "hammer.fill",
                             term: term,
                             weeklyLectureHours: 0,
                             weeklyExerciseHours: 0,
                             hasLectures: false,
                             lecturer: "Encadrant·e")
        context.insert(project)
        // Cours sans aucune vidéo : sa théorie est un chapitre à lire, sans durée.
        addTheory(to: project, context: context, kind: .chapter, specs: [
            (1, "1.1", "Consignes et cadrage", 0, 1)
        ])
        addSeries(to: project, context: context, number: 1, week: 2,
                  exercises: [("1.1", false), ("1.2", false)])

        // MARK: Progression d'exemple (théorie + exercices + corrections)
        applySampleProgress(courses: [cs, math, phys], context: context)

        // MARK: Sessions de travail des 10 derniers jours
        applySampleSessions(context: context, courses: [cs, math, phys])

        // MARK: Session d'étude planifiée aujourd'hui
        let planned = PlannedSession(course: cs,
                                     title: "Révisions séries 1–2",
                                     startsAt: calendar.date(bySettingHour: 17, minute: 0, second: 0, of: Date()) ?? Date(),
                                     durationMinutes: 90,
                                     location: "Bibliothèque Rolex",
                                     createdByUserID: "me")
        context.insert(planned)

        let groupPlanned = PlannedSession(course: math,
                                          groupRemoteID: nil,
                                          groupName: "Buddies EPFL",
                                          title: "Analyse I — entraide",
                                          startsAt: DateUtils.addDays(1, to: calendar.date(bySettingHour: 18, minute: 30, second: 0, of: Date()) ?? Date()),
                                          durationMinutes: 120,
                                          location: "BC 01",
                                          createdByUserID: "friend-1",
                                          goingCount: 3,
                                          maybeCount: 1)
        context.insert(groupPlanned)

        try? context.save()
        return term
    }

    // MARK: - Helpers

    /// Ajoute des éléments de théorie.
    ///
    /// Le support est porté par l'élément : un cours sans aucune vidéo reçoit des
    /// chapitres, et un support sans durée n'en invente pas une.
    private static func addTheory(to course: Course,
                                  context: ModelContext,
                                  kind: TheoryKind = .video,
                                  specs: [(Int, String, String, Int, Int)]) {
        for (index, spec) in specs.enumerated() {
            let item = TheoryItem(course: course,
                                  sectionNumber: spec.0,
                                  number: spec.1,
                                  title: spec.2,
                                  kind: kind,
                                  durationSeconds: kind.hasDuration ? spec.3 : 0,
                                  plannedWeek: spec.4,
                                  sortOrder: index)
            context.insert(item)
        }
    }

    private static func addSeries(to course: Course,
                                  context: ModelContext,
                                  number: Int,
                                  week: Int,
                                  exercises: [(String, Bool)]) {
        let series = ExerciseSeries(course: course,
                                    seriesNumber: number,
                                    title: "Série \(number)",
                                    plannedWeek: week)
        context.insert(series)
        for (index, spec) in exercises.enumerated() {
            let exercise = Exercise(series: series,
                                    exerciseNumber: spec.0,
                                    title: spec.1 ? "Exercice bonus" : "",
                                    isBonus: spec.1,
                                    sortOrder: index)
            context.insert(exercise)
        }
    }

    private static func addExams(to course: Course,
                                 context: ModelContext,
                                 termStart: Date,
                                 specs: [(ExamKind, String, Int, Double, String)]) {
        for spec in specs {
            // À 8 h 15, l'heure des examens EPFL — une date à minuit n'a pas d'heure.
            let day = DateUtils.addWeeks(spec.2, to: termStart)
            let exam = Exam(course: course,
                            kind: spec.0,
                            title: spec.1,
                            date: Calendar.current.date(bySettingHour: 8, minute: 15, second: 0, of: day) ?? day,
                            weightPercent: spec.3,
                            location: spec.4)
            context.insert(exam)
        }
    }

    /// Marque une partie du contenu comme fait / corrigé pour que l'UI soit parlante.
    private static func applySampleProgress(courses: [Course], context: ModelContext) {
        guard let cs = courses.first(where: { $0.code == "CS-250" }),
              let math = courses.first(where: { $0.code == "MATH-101" }),
              let phys = courses.first(where: { $0.code == "PHYS-101" }) else { return }

        let calendar = Calendar.current
        let today = Date()

        // CS-250 : théorie avancée, séries 1–2 traitées.
        for video in cs.sortedTheoryItems {
            if ["1.1", "1.2", "1.3", "2.1"].contains(video.number) {
                video.watchedAt = DateUtils.addDays(-6, to: today)
            }
            if ["1.1", "1.2", "1.3"].contains(video.number) {
                video.summarizedAt = DateUtils.addDays(-5, to: today)
                video.summaryText = "Résumé de la vidéo \(video.number)."
            }
        }
        // Une série dont les exercices portent des questions : c'est le cas des
        // polycopiés qui numérotent « 1., 2. » à l'intérieur d'un même exercice.
        // Sans exemple, l'écran de détail ne montrerait jamais cette partie.
        if let s3 = cs.sortedSeries.first(where: { $0.seriesNumber == 3 }) {
            let labels = [["1", "2"], ["1", "2", "3"], [], ["1", "2"]]
            for (index, exercise) in s3.sortedExercises.enumerated() where index < labels.count {
                let questions = labels[index]
                guard !questions.isEmpty else { continue }
                for (order, label) in questions.enumerated() {
                    let question = SubQuestion(exercise: exercise,
                                               label: label,
                                               sortOrder: order)
                    context.insert(question)
                }
            }
            // Le premier exercice est entamé : une question sur deux cochée.
            if let first = s3.sortedExercises.first(where: { $0.hasSubQuestions }),
               let question = first.sortedSubQuestions.first {
                question.isDone = true
                question.doneAt = DateUtils.addDays(-1, to: today)
            }
        }
        if let s1 = cs.sortedSeries.first(where: { $0.seriesNumber == 1 }) {
            for exercise in s1.sortedExercises {
                exercise.doneAt = DateUtils.addDays(-4, to: today)
                exercise.confidence = exercise.isBonus ? .medium : .high
                exercise.correctedAt = DateUtils.addDays(-3, to: today)
                exercise.correctness = .correct
            }
        }
        if let s2 = cs.sortedSeries.first(where: { $0.seriesNumber == 2 }) {
            for exercise in s2.sortedExercises where !exercise.isBonus {
                exercise.doneAt = DateUtils.addDays(-1, to: today)
                exercise.confidence = .medium
            }
            if let first = s2.sortedExercises.first {
                first.correctedAt = DateUtils.addDays(-1, to: today)
                first.correctness = .partial
                first.redoRequired = true
                first.correctionNote = "Revoir la récurrence du cas moyen."
            }
        }

        // MATH-101 : en cours.
        for video in math.sortedTheoryItems where ["1.1", "1.2"].contains(video.number) {
            video.watchedAt = DateUtils.addDays(-3, to: today)
        }
        if let s1 = math.sortedSeries.first(where: { $0.seriesNumber == 1 }) {
            for (index, exercise) in s1.sortedExercises.enumerated() {
                exercise.doneAt = DateUtils.addDays(-2, to: today)
                exercise.confidence = index == 0 ? .high : .low
            }
        }

        // PHYS-101 : à peine commencé.
        for video in phys.sortedTheoryItems where video.number == "1.1" {
            video.watchedAt = DateUtils.addDays(-1, to: today)
        }

        _ = calendar
    }

    private static func applySampleSessions(context: ModelContext, courses: [Course]) {
        guard let cs = courses.first(where: { $0.code == "CS-250" }),
              let math = courses.first(where: { $0.code == "MATH-101" }),
              let phys = courses.first(where: { $0.code == "PHYS-101" }) else { return }

        // (jours en arrière, cours, type, minutes)
        let plan: [(Int, Course, TaskType, Int)] = [
            (9, cs, .video, 90),
            (9, cs, .summary, 30),
            (8, math, .lecture, 120),
            (8, math, .exercise, 75),
            (7, cs, .exercise, 110),
            (7, cs, .correction, 45),
            (6, phys, .video, 60),
            (5, cs, .flashcards, 40),
            (5, math, .theory, 90),
            (4, cs, .exercise, 120),
            (3, cs, .correction, 50),
            (3, math, .exercise, 80),
            (2, phys, .exercise, 70),
            (1, cs, .video, 105),
            (1, math, .theory, 60),
            (0, cs, .exercise, 95),
            (0, cs, .correction, 35)
        ]

        for entry in plan {
            let start = DateUtils.addDays(-entry.0, to: Date())
            let session = StudySession(course: entry.1,
                                       taskType: entry.2,
                                       startedAt: start,
                                       durationSeconds: entry.3 * 60,
                                       isManual: true)
            context.insert(session)
        }
    }
}
