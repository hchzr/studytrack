import SwiftUI

// MARK: - Type de tâche (traçage du temps par sous-catégorie)

/// Ce sur quoi une session a porté.
///
/// Le travail d'un cours se range en **trois** catégories — Théorie, Séries,
/// Correction — et c'est tout ce que l'étudiant·e choisit. Neuf types côte à
/// côte (« Vidéo », « Théorie », « Résumé », « Cours »…) posaient une question
/// sans réponse : regarder la vidéo 1.2, est-ce « Vidéo » ou « Théorie » ?
///
/// Les anciennes valeurs brutes restent décodables — des sessions, des widgets
/// et des raccourcis les ont enregistrées — mais `canonical` les replie sur la
/// catégorie qui compte. `.flashcards` n'est jamais choisi à la main : c'est le
/// temps passé dans **Anki**, importé tout seul et marqué comme tel.
enum TaskType: String, Codable, CaseIterable, Identifiable {
    case lecture, video, exercise, theory, flashcards, summary, correction, project, other

    var id: String { rawValue }

    /// Les seules catégories proposées dans un sélecteur.
    static let choices: [TaskType] = [.theory, .exercise, .correction, .other]

    /// Les catégories d'un bilan, dans l'ordre d'affichage.
    static let reportCategories: [TaskType] = [.theory, .exercise, .correction, .flashcards, .lecture, .other]

    /// La catégorie qui compte : une vidéo ou un résumé, c'est de la théorie.
    var canonical: TaskType {
        switch self {
        case .video, .summary, .theory: return .theory
        case .project: return .other
        default: return self
        }
    }

    var label: String {
        switch canonical {
        case .lecture: return "Cours en amphi"
        case .exercise: return "Séries"
        case .theory: return "Théorie"
        case .flashcards: return "Anki"
        case .correction: return "Correction"
        default: return "Autre"
        }
    }

    var shortLabel: String {
        switch canonical {
        case .lecture: return "Amphi"
        case .exercise: return "Séries"
        case .theory: return "Théorie"
        case .flashcards: return "Anki"
        case .correction: return "Corr."
        default: return "Autre"
        }
    }

    var icon: String {
        switch canonical {
        case .lecture: return "building.columns.fill"
        case .exercise: return "list.number"
        case .theory: return "book.fill"
        case .flashcards: return "rectangle.stack.fill"
        case .correction: return "checkmark.seal.fill"
        default: return "ellipsis.circle.fill"
        }
    }

    /// Une teinte par catégorie, jamais vert / orange / rouge : ces trois-là
    /// portent un verdict (sureté, correction), pas une catégorie.
    var tint: Color {
        switch canonical {
        case .lecture: return .gray
        case .exercise: return .blue
        case .theory: return .purple
        case .flashcards: return .pink
        case .correction: return .teal
        default: return .gray
        }
    }
}

// MARK: - Niveau de confiance (code couleur de sureté de la réponse)

enum ConfidenceLevel: String, Codable, CaseIterable, Identifiable {
    case high = "green"
    case medium = "orange"
    case low = "red"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .high: return "Sûr·e"
        case .medium: return "Moyennement sûr·e"
        case .low: return "Pas sûr·e"
        }
    }

    var shortLabel: String {
        switch self {
        case .high: return "Vert"
        case .medium: return "Orange"
        case .low: return "Rouge"
        }
    }

    var color: Color {
        switch self {
        case .high: return .green
        case .medium: return .orange
        case .low: return .red
        }
    }

    var icon: String { "circle.fill" }

    /// Glyphe porté par la pastille sélectionnée.
    ///
    /// Le sureté ne doit pas être encodée **par la couleur seule** : vert /
    /// orange / rouge est précisément la triade que le daltonisme rouge-vert
    /// confond. La forme est l'indice redondant.
    var glyph: String {
        switch self {
        case .high: return "checkmark"
        case .medium: return "equal"
        case .low: return "questionmark"
        }
    }
}

// MARK: - Résultat de correction

enum Correctness: String, Codable, CaseIterable, Identifiable {
    case correct, partial, wrong

    var id: String { rawValue }

    var label: String {
        switch self {
        case .correct: return "Juste"
        case .partial: return "Moyennement juste"
        case .wrong: return "Faux"
        }
    }

    var shortLabel: String {
        switch self {
        case .correct: return "Juste"
        case .partial: return "Moyen"
        case .wrong: return "Faux"
        }
    }

    var color: Color {
        switch self {
        case .correct: return .green
        case .partial: return .orange
        case .wrong: return .red
        }
    }

    var icon: String {
        switch self {
        case .correct: return "checkmark.circle.fill"
        case .partial: return "minus.circle.fill"
        case .wrong: return "xmark.circle.fill"
        }
    }
}

// MARK: - Type d'évaluation (midterm / examen / …)

enum ExamKind: String, Codable, CaseIterable, Identifiable {
    case midterm, exam, quiz, project, assignment, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .midterm: return "Midterm"
        case .exam: return "Examen"
        case .quiz: return "Quiz"
        case .project: return "Projet"
        case .assignment: return "Devoir"
        case .other: return "Autre"
        }
    }

    var icon: String {
        switch self {
        case .midterm: return "clock.badge.exclamationmark.fill"
        case .exam: return "graduationcap.fill"
        case .quiz: return "questionmark.circle.fill"
        case .project: return "hammer.fill"
        case .assignment: return "doc.text.fill"
        case .other: return "calendar.badge.clock"
        }
    }

    var color: Color {
        switch self {
        case .midterm: return .orange
        case .exam: return .red
        case .quiz: return .yellow
        case .project: return .brown
        case .assignment: return .blue
        case .other: return .gray
        }
    }
}

// MARK: - Semestre

enum TermSeason: String, Codable, CaseIterable, Identifiable {
    case autumn, spring

    var id: String { rawValue }

    var label: String {
        switch self {
        case .autumn: return "Automne"
        case .spring: return "Printemps"
        }
    }
}

// MARK: - Fournisseur de tâches

/// Type de support d'un élément de théorie.
///
/// Certains cours EPFL n'ont aucune vidéo, d'autres mélangent vidéos et supports
/// écrits. Le support appartient donc à l'élément, jamais au cours : aucun écran
/// ne doit supposer qu'une théorie se regarde.
enum TheoryKind: String, Codable, CaseIterable, Identifiable {
    case video, reading, chapter, slides

    var id: String { rawValue }

    var label: String {
        switch self {
        case .video: return "Vidéo"
        case .reading: return "Lecture"
        case .chapter: return "Chapitre"
        case .slides: return "Diapositives"
        }
    }

    /// Au pluriel, pour les en-têtes de section.
    var pluralLabel: String {
        switch self {
        case .video: return "Vidéos"
        case .reading: return "Lectures"
        case .chapter: return "Chapitres"
        case .slides: return "Diapositives"
        }
    }

    var icon: String {
        switch self {
        case .video: return "play.rectangle.fill"
        case .reading: return "book.fill"
        case .chapter: return "doc.text.fill"
        case .slides: return "rectangle.on.rectangle"
        }
    }

    /// Tous les supports sont de la **théorie** : une seule teinte. Le glyphe
    /// suffit à distinguer une vidéo d'une lecture.
    var tint: Color { TaskType.theory.tint }

    /// Une durée a-t-elle un sens pour ce support ? Un chapitre sans durée ne
    /// doit pas s'afficher « 0 min ».
    var hasDuration: Bool {
        switch self {
        case .video, .slides: return true
        case .reading, .chapter: return false
        }
    }
}

enum TaskProvider: String, Codable, CaseIterable, Identifiable {
    case reminders, todoist, things, notion, webhook
    case microsoftToDo, googleTasks, tickTick

    var id: String { rawValue }

    var label: String {
        switch self {
        case .reminders: return "Rappels"
        case .todoist: return "Todoist"
        case .things: return "Things 3"
        case .notion: return "Notion"
        case .webhook: return "Webhook"
        case .microsoftToDo: return "Microsoft To Do"
        case .googleTasks: return "Google Tasks"
        case .tickTick: return "TickTick"
        }
    }

    var icon: String {
        switch self {
        case .reminders: return "checklist"
        case .todoist: return "checkmark.square.fill"
        case .things: return "checkmark.circle"
        case .notion: return "doc.richtext"
        case .webhook: return "bolt.horizontal.circle.fill"
        case .microsoftToDo: return "list.bullet.clipboard.fill"
        case .googleTasks: return "checkmark.circle.fill"
        case .tickTick: return "checkmark.seal.fill"
        }
    }

    /// Ce fournisseur permet-il de **lire** les tâches existantes ?
    ///
    /// Things 3 n'expose pas d'API de lecture : on peut seulement y créer des tâches
    /// via son schéma d'URL. Le webhook est en écriture seule par construction.
    var supportsReading: Bool {
        switch self {
        case .reminders, .todoist, .notion,
             .microsoftToDo, .googleTasks, .tickTick:
            return true
        case .things, .webhook:
            return false
        }
    }

    /// Ce fournisseur permet-il de **créer** des tâches ?
    var supportsWriting: Bool { true }

    /// Clé de réglage associée (jeton, URL…).
    var credentialLabel: String? {
        switch self {
        case .reminders: return nil
        case .todoist: return "Jeton API Todoist"
        case .things: return nil
        case .notion: return "Jeton d'intégration Notion"
        case .webhook: return "URL du webhook"
        case .microsoftToDo: return "Jeton d'accès Microsoft Graph"
        case .googleTasks: return "Refresh token OAuth Google"
        case .tickTick: return "Jeton d'accès TickTick"
        }
    }

    var helpText: String {
        switch self {
        case .reminders:
            return "Synchronisation native avec l'app Rappels. Aucun réglage nécessaire."
        case .todoist:
            return "Créez un jeton dans Todoist › Paramètres › Intégrations › Développeur."
        case .things:
            return "Things 3 est en écriture seule : l'app peut y envoyer des tâches, mais pas les relire."
        case .notion:
            return "Créez une intégration Notion, partagez-lui une base de données, puis collez le jeton et l'ID de la base."
        case .webhook:
            return "StudyTrack envoie un JSON à cette URL (compatible Shortcuts, Home Assistant, Zapier, n8n)."
        case .microsoftToDo:
            return "Jeton d'accès Microsoft Graph : le plus simple est de le prendre dans Graph Explorer, puis de le renouveler quand il expire."
        case .googleTasks:
            return "Identifiant client, secret et refresh token OAuth : l'app renouvelle ensuite l'accès toute seule."
        case .tickTick:
            return "Jeton d'accès de l'API ouverte TickTick (OAuth2)."
        }
    }
}

// MARK: - Type d'événement d'agenda

enum CalendarEventKind: String, Codable, CaseIterable, Identifiable {
    case lecture, exerciseSession, midterm, exam, study, personal, task, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lecture: return "Cours"
        case .exerciseSession: return "Séance d'exercices"
        case .midterm: return "Midterm"
        case .exam: return "Examen"
        case .study: return "Session d'étude"
        case .personal: return "Personnel"
        case .task: return "Tâche"
        case .other: return "Autre"
        }
    }

    var icon: String {
        switch self {
        case .lecture: return "building.columns.fill"
        case .exerciseSession: return "pencil.and.list.clipboard"
        case .midterm: return "clock.badge.exclamationmark.fill"
        case .exam: return "graduationcap.fill"
        case .study: return "timer"
        case .personal: return "person.fill"
        case .task: return "checklist"
        case .other: return "calendar"
        }
    }

    var color: Color {
        switch self {
        case .lecture: return .blue
        case .exerciseSession: return .teal
        case .midterm: return .orange
        case .exam: return .red
        case .study: return .indigo
        case .personal: return .gray
        case .task: return .teal
        case .other: return .gray
        }
    }
}

// MARK: - Événement d'agenda unifié (calendrier + examens + sessions)

enum AgendaItemKind: String, Identifiable {
    case exam, calendar, planned, task, milestone
    var id: String { rawValue }
    var label: String {
        switch self {
        case .milestone: return "Calendrier EPFL"
        case .exam: return "Évaluation"
        case .calendar: return "Calendrier"
        case .planned: return "Session planifiée"
        case .task: return "Tâche"
        }
    }
}

// MARK: - Période pour les récaps visuels

enum StatsPeriod: String, CaseIterable, Identifiable {
    case day, week, month
    var id: String { rawValue }
    var label: String {
        switch self {
        case .day: return "Jour"
        case .week: return "Semaine"
        case .month: return "Mois"
        }
    }
    var days: Int {
        switch self {
        case .day: return 1
        case .week: return 7
        case .month: return 30
        }
    }

    /// Ce que couvrent les totaux, en toutes lettres : « Semaine » seul laissait
    /// croire à la semaine du calendrier, et les totaux contredisaient le graphique.
    var rangeLabel: String {
        switch self {
        case .day: return "Aujourd'hui"
        case .week: return "7 derniers jours"
        case .month: return "30 derniers jours"
        }
    }
}
