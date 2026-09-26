import Foundation
import SwiftData

/// Cours EPFL. Racine de la décomposition théorie / exercices.
@Model
final class Course {
    @Attribute(.unique) var id: UUID
    /// Code officiel EPFL (« CS-250 »).
    var code: String
    var name: String
    /// Abréviation choisie par l'étudiant·e, affichée partout où la place manque
    /// (« ALGO », « Ana I »). Le code officiel reste `code`, et rien ne l'écrase.
    var shortName: String = ""
    var credits: Double
    var colorHex: String
    var iconName: String
    var term: AcademicTerm?

    /// Heures de **cours magistral** (amphi) par semaine.
    var weeklyLectureHours: Double
    /// Heures d'**exercices** (séances) par semaine.
    var weeklyExerciseHours: Double

    /// Objectif de travail **personnel** hebdomadaire, en heures.
    ///
    /// `nil` = déduit de la charge ECTS : ce qui reste une fois les heures
    /// encadrées (amphi + exos) retirées. C'est ce champ qui rend l'attendu
    /// **hebdomadaire** — un total semestriel de 120 h ne se compare à rien.
    var weeklySelfStudyHours: Double?

    /// Le cours a-t-il réellement des heures de cours (amphi) ?
    ///
    /// C'est la question posée à l'étudiant·e à l'ajout d'une classe : certains
    /// cours n'ont que des séries d'exercices. Quand ce drapeau est faux, la charge
    /// attendue EPFL ne réserve aucune heure d'amphi, et le suivi de présence est masqué.
    var hasLectures: Bool
    /// Section EPFL du cours (« IN », « MA », …).
    var sectionCode: String
    /// Cours suivi ce semestre (les autres sont archivés).
    var isTracked: Bool

    var isActive: Bool
    var lecturer: String
    var moodleURLString: String
    var notes: String

    @Relationship(deleteRule: .cascade, inverse: \TheoryItem.course)
    var theoryItems: [TheoryItem] = []

    @Relationship(deleteRule: .cascade, inverse: \ExerciseSeries.course)
    var series: [ExerciseSeries] = []

    @Relationship(deleteRule: .cascade, inverse: \StudySession.course)
    var sessions: [StudySession] = []

    @Relationship(deleteRule: .cascade, inverse: \Exam.course)
    var exams: [Exam] = []

    @Relationship(deleteRule: .cascade, inverse: \PastExam.course)
    var pastExams: [PastExam] = []

    @Relationship(deleteRule: .cascade, inverse: \LinkedTask.course)
    var linkedTasks: [LinkedTask] = []

    @Relationship(deleteRule: .cascade, inverse: \LinkedCalendarEvent.course)
    var linkedEvents: [LinkedCalendarEvent] = []

    init(id: UUID = UUID(),
         code: String,
         name: String,
         shortName: String = "",
         credits: Double = 4,
         colorHex: String = "#4F46E5",
         iconName: String = "book.closed.fill",
         term: AcademicTerm? = nil,
         weeklyLectureHours: Double = 2,
         weeklyExerciseHours: Double = 1,
         weeklySelfStudyHours: Double? = nil,
         hasLectures: Bool = true,
         sectionCode: String = "",
         isTracked: Bool = true,
         isActive: Bool = true,
         lecturer: String = "",
         moodleURLString: String = "",
         notes: String = "") {
        self.id = id
        self.code = code
        self.name = name
        self.shortName = shortName
        self.credits = credits
        self.colorHex = colorHex
        self.iconName = iconName
        self.term = term
        self.weeklyLectureHours = weeklyLectureHours
        self.weeklyExerciseHours = weeklyExerciseHours
        self.weeklySelfStudyHours = weeklySelfStudyHours
        self.hasLectures = hasLectures
        self.sectionCode = sectionCode
        self.isTracked = isTracked
        self.isActive = isActive
        self.lecturer = lecturer
        self.moodleURLString = moodleURLString
        self.notes = notes
    }

    // MARK: Convenience

    /// Ce qu'on affiche partout où la place manque : l'abréviation si l'étudiant·e
    /// en a défini une, sinon le code officiel. Le libellé complet reste `name`.
    var displayCode: String {
        let trimmed = shortName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? code : trimmed
    }

    var sortedTheoryItems: [TheoryItem] {
        theoryItems.sorted { lhs, rhs in
            if lhs.sectionNumber != rhs.sectionNumber { return lhs.sectionNumber < rhs.sectionNumber }
            return lhs.number.localizedStandardCompare(rhs.number) == .orderedAscending
        }
    }

    var sortedSeries: [ExerciseSeries] {
        series.sorted { $0.seriesNumber < $1.seriesNumber }
    }

    /// Sections de théorie présentes.
    var theorySections: [Int] {
        Array(Set(theoryItems.map(\.sectionNumber))).sorted()
    }

    var allExercises: [Exercise] { series.flatMap(\.exercises) }

    var sortedExams: [Exam] { exams.sorted { $0.date < $1.date } }

    /// Annales, de la plus récente à la plus ancienne — l'ordre dans lequel on les
    /// travaille.
    var sortedPastExams: [PastExam] {
        pastExams.sorted { lhs, rhs in
            if lhs.year != rhs.year { return lhs.year > rhs.year }
            return lhs.addedAt > rhs.addedAt
        }
    }

    var nextExam: Exam? { sortedExams.first { $0.date >= Date() } }

    /// Semaine courante, bornée à la durée du semestre.
    ///
    /// Bornée volontairement : un semestre importé dont la date de début est loin
    /// dans le passé ne doit pas produire une « semaine 47 » qui vide tous les écrans.
    ///
    /// Sans semestre rattaché, on retombe sur le calendrier académique réel plutôt
    /// que sur `1`. Renvoyer « semaine 1 » était faux et invisible : l'étudiant·e
    /// voyait « 1 / 14 » en pleine semaine 2, sans aucun moyen de comprendre
    /// pourquoi. Le rattachement est fait à l'import et réparé au lancement
    /// (`AcademicTerm.attachOrphanCourses`) ; ceci n'est qu'un dernier filet.
    var currentWeek: Int {
        guard let term else {
            let fallback = DateUtils.currentAutumnOrSpringStart()
            let week = DateUtils.weekNumber(from: fallback.start)
            return min(max(week, 1), max(fallback.weeks, 1))
        }
        return DateUtils.clampedWeek(for: Date(), term: term)
    }

    /// Le semestre de ce cours est-il en cours ?
    var isTermRunning: Bool {
        guard let term else { return true }
        return term.isRunning
    }

    /// La semaine est-elle dans la plage planifiée du cours ?
    func isPlanningRelevant(week: Int) -> Bool {
        isTermRunning && week >= 1 && week <= (term?.totalWeeks ?? 14)
    }
}
