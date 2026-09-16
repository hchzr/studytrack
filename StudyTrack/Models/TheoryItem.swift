import Foundation
import SwiftData

/// Élément de théorie : « vidéo 1.1 », « chapitre 2.3 », une lecture, des diapos.
///
/// Tous les cours EPFL ne sont pas filmés — certains n'ont aucune vidéo, d'autres
/// mélangent vidéos et supports écrits. Le type de support appartient donc à
/// l'**élément**, jamais au cours, et rien ne le suppose.
@Model
final class TheoryItem {
    @Attribute(.unique) var id: UUID
    var course: Course?
    /// Section (ex : 1 pour les éléments 1.x).
    var sectionNumber: Int
    /// Numéro affiché : « 1.1 ».
    var number: String
    var title: String
    /// Durée en secondes. `0` = inconnue, ce qui est fréquent pour une lecture
    /// ou un chapitre : aucun écran ne doit en déduire une durée nulle.
    var durationSeconds: Int
    /// Semaine à laquelle l'élément doit être travaillé (1-based).
    var plannedWeek: Int
    var sortOrder: Int

    var kindRaw: String

    /// Date à laquelle l'élément a été fait — vu, lu, parcouru.
    var watchedAt: Date?
    /// Date du résumé.
    var summarizedAt: Date?
    var summaryText: String?
    var urlString: String

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

    /// Libellé : « Vidéo 1.1 », « Chapitre 2.3 »… selon le support.
    var displayNumber: String { "\(kind.label) \(number)" }
}
