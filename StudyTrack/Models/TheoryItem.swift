import Foundation
import SwiftData

/// Élément de théorie : « vidéo 1.1 », « chapitre 2.3 », une lecture, des diapos.
///
/// Tous les cours EPFL ne sont pas filmés — certains n'ont aucune vidéo, d'autres
/// mélangent vidéos et supports écrits. Le type de support appartient donc à
/// l'**élément**, jamais au cours, et rien ne le suppose.
@Model
final class TheoryItem {
    var id: UUID = UUID()
    var course: Course?
    /// Section (ex : 1 pour les éléments 1.x).
    var sectionNumber: Int = 0
    /// Numéro affiché : « 1.1 ».
    var number: String = ""
    var title: String = ""
    /// Durée en secondes. `0` = inconnue, ce qui est fréquent pour une lecture
    /// ou un chapitre : aucun écran ne doit en déduire une durée nulle.
    var durationSeconds: Int = 0
    /// Semaine à laquelle l'élément doit être travaillé (1-based).
    var plannedWeek: Int = 0
    var sortOrder: Int = 0

    var kindRaw: String = ""

    /// Date à laquelle l'élément a été fait — vu, lu, parcouru.
    var watchedAt: Date?
    /// Date du résumé.
    var summarizedAt: Date?
    var summaryText: String?
    var urlString: String = ""

    /// Nombre de vidéos **dans** l'élément. Une section de polycopié en ligne
    /// (Botafogo) ou une leçon de MOOC contient souvent plusieurs vidéos : ce ne
    /// sont pas des éléments à part, c'est la même théorie à travailler.
    var videoCount: Int = 0
    /// Titre du chapitre auquel l'élément appartient (« Suites réelles ») : il
    /// nomme la section dans la liste, là où « Section 3 » ne disait rien.
    var sectionTitle: String = ""
    /// D'où vient l'élément (`ContentSource.rawValue`), vide s'il a été saisi.
    var sourceRaw: String = ""
    /// Tous les liens de l'élément (JSON de `ContentLink`) : l'enregistrement
    /// du cours, ses transparents, ses notes annotées. `urlString` reste le
    /// lien principal.
    var linksRaw: String = ""

    var links: [ContentLink] {
        get { ContentLink.decodeList(linksRaw) }
        set { linksRaw = ContentLink.encodeList(newValue) }
    }

    /// Les sessions et les tâches qui visent cet élément. Inverses de
    /// `StudySession.theoryItem` et `LinkedTask.video`, exigés par iCloud ;
    /// supprimer l'élément laisse les sessions, sans cible.
    @Relationship(deleteRule: .nullify, inverse: \StudySession.theoryItem)
    var targetedSessions: [StudySession]? = []
    @Relationship(deleteRule: .nullify, inverse: \LinkedTask.video)
    var targetedTasks: [LinkedTask]? = []

    init(id: UUID = UUID(),
         course: Course? = nil,
         sectionNumber: Int,
         number: String,
         title: String = "",
         kind: TheoryKind = .video,
         durationSeconds: Int = 0,
         plannedWeek: Int = 1,
         sortOrder: Int = 0,
         urlString: String = "") {
        self.id = id
        self.course = course
        self.sectionNumber = sectionNumber
        self.number = number
        self.title = title
        self.kindRaw = kind.rawValue
        self.durationSeconds = durationSeconds
        self.plannedWeek = plannedWeek
        self.sortOrder = sortOrder
        self.urlString = urlString
    }

    var kind: TheoryKind {
        get { TheoryKind(rawValue: kindRaw) ?? .video }
        set { kindRaw = newValue.rawValue }
    }

    var isWatched: Bool { watchedAt != nil }
    var isSummarized: Bool { summarizedAt != nil }

    /// Une durée est-elle connue ? Un chapitre sans durée ne doit pas s'afficher
    /// « 0 min ».
    var hasDuration: Bool { durationSeconds > 0 }

    var durationLabel: String { DateUtils.durationLabel(seconds: durationSeconds) }
    var durationMinutes: Int { durationSeconds / 60 }

    /// Libellé : « Théorie 1.1 ». Le support (vidéo, lecture…) est une icône,
    /// pas une catégorie : tout élément de théorie se nomme de la même façon.
    /// « Théorie 2.1 » (traduit : la leçon se lit aussi en anglais).
    var displayNumber: String { String(localized: "Théorie \(number)") }

    /// « 1.1 · Introduction », ou le numéro seul.
    var numberAndTitle: String { title.isEmpty ? number : "\(number) · \(title)" }
}
