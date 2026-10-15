import Foundation
import SwiftData

/// Une erreur du carnet : ce qui s'est mal passé sur un exercice, assez précis
/// pour être reconnu la prochaine fois (« oubli de vérifier l'hypothèse de
/// continuité en 0 », pas « erreur exo 3 »). Notée au post-mortem — par
/// Claude, confirmée par l'étudiant·e — ou à la main.
///
/// Toute erreur devient une ligne, même une étourderie : c'est la récurrence
/// des types qui dit quoi travailler.
@Model
final class Mistake {
    var id: UUID = UUID()
    var exercise: Exercise?
    var createdAt: Date = Date.now
    var summary: String = ""
    /// `SeriesReview.MistakeKind.rawValue`.
    var kindRaw: String = SeriesReview.MistakeKind.method.rawValue
    /// La bonne démarche, en une ou deux phrases.
    var correction: String = ""
    /// La notion en jeu (« continuité », « critère de d'Alembert »).
    var notion: String = ""
    /// « claude » ou « manual ».
    var source: String = "manual"

    init(exercise: Exercise?, kind: SeriesReview.MistakeKind, summary: String, correction: String = "", notion: String = "",
         source: String = "manual", createdAt: Date = Date()) {
        self.exercise = exercise
        self.kindRaw = kind.rawValue
        self.summary = summary
        self.correction = correction
        self.notion = notion
        self.source = source
        self.createdAt = createdAt
    }

    var kind: SeriesReview.MistakeKind {
        get { SeriesReview.MistakeKind(rawValue: kindRaw) ?? .method }
        set { kindRaw = newValue.rawValue }
    }
}
