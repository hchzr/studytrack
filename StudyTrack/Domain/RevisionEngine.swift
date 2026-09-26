import Foundation

/// Un élément à réviser : une vidéo à voir, un exercice à faire, une correction.
struct RevisionItem: Equatable, Identifiable {
    enum Kind: String, Comparable {
        case theory
        case exercise
        case correction

        /// L'ordre d'un travail sensé : on voit la théorie, on fait les exercices,
        /// puis on les corrige.
        var rank: Int {
            switch self {
            case .theory: return 0
            case .exercise: return 1
            case .correction: return 2
            }
        }

        var label: String {
            switch self {
            case .theory: return "Théorie"
            case .exercise: return "Exercices"
            case .correction: return "Corrections"
            }
        }

        var icon: String {
            switch self {
            case .theory: return "play.rectangle.fill"
            case .exercise: return "checklist"
            case .correction: return "checkmark.seal"
            }
        }

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rank < rhs.rank }
    }

    var id: String
    var label: String
    var kind: Kind
    /// Semaine prévue par l'EPFL : c'est elle qui donne l'ordre de lecture.
    var week: Int
}

/// Une journée du plan.
struct RevisionDay: Identifiable, Equatable {
    var date: Date
    var items: [RevisionItem]
    /// Journée de relecture avant l'évaluation, sans contenu nouveau.
    var isReview: Bool

    var id: Date { date }

    var isEmpty: Bool { items.isEmpty }
}

/// Ce qui reste à faire avant une évaluation.
struct RevisionWorkload: Equatable {
    var courseCode: String
    var examTitle: String
    var examDate: Date
    var items: [RevisionItem]

    init(courseCode: String,
         examTitle: String,
         examDate: Date,
         items: [RevisionItem]) {
        self.courseCode = courseCode
        self.examTitle = examTitle
        self.examDate = examDate
        self.items = items
    }
}

/// Un plan de révision, jour par jour.
struct RevisionPlan: Equatable {
    var courseCode: String
    var examTitle: String
    var examDate: Date
    var days: [RevisionDay]
    var totalItems: Int
    /// Jours réellement utilisables avant l'évaluation.
    var usableDays: Int
    /// Ce qui est à faire par jour, en moyenne.
    var perDay: Double
    /// Combien de temps viser chaque jour, si l'étudiant·e a donné une durée.
    var minutesPerDay: Int?
    /// Ce qui empêche un plan réaliste, s'il y a lieu.
    var warning: String?

    var isEmpty: Bool { totalItems == 0 }

    var nextDay: RevisionDay? {
        days.first { !$0.isPast }
    }
}

private extension RevisionDay {
    var isPast: Bool { date < Calendar.current.startOfDay(for: Date()) }
}

/// Répartit le travail restant entre aujourd'hui et l'évaluation.
///
/// Fonction **pure** : elle reçoit une liste d'éléments et une date, donc elle se
/// teste sans base. C'est ce qui permet de vérifier les cas qui comptent — un
/// examen demain, un examen sans travail restant, une échéance déjà passée.
enum RevisionEngine {

    /// Part des jours réservée à la relecture, avant l'évaluation.
    ///
    /// Un cinquième, au moins un jour : arriver la veille au soir sans avoir relu
    /// ce qu'on a appris est le meilleur moyen d'oublier la moitié.
    static func reviewDayCount(usableDays: Int) -> Int {
        guard usableDays > 0 else { return 0 }
        return min(usableDays, max(1, usableDays / 5))
    }

    static func plan(_ workload: RevisionWorkload,
                     from start: Date = Date(),
                     calendar: Calendar = .current,
                     minutesPerDay: Int? = nil) -> RevisionPlan {
        let today = calendar.startOfDay(for: start)
        let examDay = calendar.startOfDay(for: workload.examDate)

        // Les jours **avant** l'évaluation. Le jour de l'épreuve n'accueille pas de
        // travail nouveau : on y révise, ou on s'y repose.
        var dates: [Date] = []
        var cursor = today
        while cursor < examDay {
            dates.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        let ordered = workload.items.sorted { lhs, rhs in
            if lhs.week != rhs.week { return lhs.week < rhs.week }
            if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            return lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
        }

        guard !dates.isEmpty else {
            return RevisionPlan(courseCode: workload.courseCode,
                                examTitle: workload.examTitle,
                                examDate: workload.examDate,
                                days: [],
                                totalItems: ordered.count,
                                usableDays: 0,
                                perDay: Double(ordered.count),
                                minutesPerDay: minutesPerDay,
                                warning: ordered.isEmpty
                                    ? nil
                                    : "L'évaluation est passée ou c'est aujourd'hui : il n'y a plus de jour à planifier.")
        }

        let reviewDays = reviewDayCount(usableDays: dates.count)
        let workDays = max(1, dates.count - reviewDays)
        let workDates = Array(dates.prefix(workDays))
        let reviewDates = Array(dates.suffix(from: workDays))

        // Répartition **contiguë** : le premier jour prend les premières semaines,
        // le dernier les dernières. C'est l'ordre naturel d'avancement dans un
        // cours — mélanger les chapitres chaque jour ne construirait rien.
        var days: [RevisionDay] = []
        if !ordered.isEmpty {
            let base = ordered.count / workDates.count
            let extra = ordered.count % workDates.count
            var index = 0
            for (position, date) in workDates.enumerated() {
                let size = base + (position < extra ? 1 : 0)
                let slice = Array(ordered[index..<min(index + size, ordered.count)])
                index += size
                days.append(RevisionDay(date: date, items: slice, isReview: false))
            }
        } else {
            days = workDates.map { RevisionDay(date: $0, items: [], isReview: false) }
        }
        days += reviewDates.map { RevisionDay(date: $0, items: [], isReview: true) }

        let perDay = workDates.isEmpty ? 0 : Double(ordered.count) / Double(workDates.count)

        var warning: String?
        if let minutesPerDay, minutesPerDay > 0 {
            // Une séance de travail utile tourne autour de dix minutes par élément
            // (voir une vidéo, faire un exercice, le corriger). Au-delà, le plan
            // demande plus d'heures que la journée n'en contient.
            let needed = perDay * 10
            if needed > Double(minutesPerDay) {
                let hours = Double(minutesPerDay) / 60
                // Interpolation plutôt que `String(format:)` : `%d` attend un
                // `Int32` et un `Int` y passerait sans avertissement.
                let target = (needed / 60 * 10).rounded() / 10
                warning = "Il reste \(ordered.count) éléments pour \(workDates.count) jours : à \(hours) h par jour, c'est serré. Vise plutôt \(target) h, ou réduis ce que tu veux couvrir."
            }
        } else if perDay > 25 {
            warning = "Il reste \(ordered.count) éléments pour \(workDates.count) jours, soit \(Int(perDay.rounded())) par jour. Commence par la théorie et les séries en retard."
        }

        return RevisionPlan(courseCode: workload.courseCode,
                            examTitle: workload.examTitle,
                            examDate: workload.examDate,
                            days: days,
                            totalItems: ordered.count,
                            usableDays: dates.count,
                            perDay: perDay,
                            minutesPerDay: minutesPerDay,
                            warning: warning)
    }
}

/// Construit la charge de révision depuis un cours.
enum RevisionBuilder {

    /// Ce qui reste à faire pour un cours : théorie non vue ou non résumée,
    /// exercices non faits, exercices faits non corrigés.
    ///
    /// « Reste » au sens strict : ce qui est fait et corrigé n'a pas à figurer dans
    /// un plan de révision. Le relire est utile, mais ce n'est pas ce qui bloque.
    static func workload(course: Course, exam: Exam) -> RevisionWorkload {
        var items: [RevisionItem] = []

        for theory in course.sortedTheoryItems where !theory.isWatched || !theory.isSummarized {
            items.append(RevisionItem(id: "theory.\(theory.id)",
                                      label: "\(theory.kind.label) \(theory.number) · \(theory.title)",
                                      kind: .theory,
                                      week: theory.plannedWeek))
        }
        for series in course.sortedSeries {
            for exercise in series.sortedExercises where !exercise.isDone {
                items.append(RevisionItem(id: "exercise.\(exercise.id)",
                                          label: "Exercice \(exercise.exerciseNumber)\(exercise.isBonus ? " (facultatif)" : "")",
                                          kind: .exercise,
                                          week: series.plannedWeek))
            }
            for exercise in series.sortedExercises where exercise.isDone && !exercise.isCorrected {
                items.append(RevisionItem(id: "correction.\(exercise.id)",
                                          label: "Corriger l'exercice \(exercise.exerciseNumber)",
                                          kind: .correction,
                                          week: series.plannedWeek))
            }
        }

        return RevisionWorkload(courseCode: course.displayCode,
                                examTitle: exam.title,
                                examDate: exam.date,
                                items: items)
    }

    /// Le plan du prochain examen d'un cours, s'il y en a un.
    static func plan(for course: Course,
                     from start: Date = Date(),
                     minutesPerDay: Int? = nil) -> RevisionPlan? {
        guard let exam = course.nextExam else { return nil }
        return RevisionEngine.plan(workload(course: course, exam: exam),
                                   from: start,
                                   minutesPerDay: minutesPerDay)
    }
}
