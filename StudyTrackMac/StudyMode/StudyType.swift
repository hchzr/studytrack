import SwiftUI

/// Les seules tailles de texte écrites en dur du mode étude : les grands titres,
/// plus grands que le plus grand style de texte de macOS (26 pt). Tout le reste
/// suit les styles du système (`.callout`, `.title3`…), donc la taille de texte
/// choisie dans Réglages Système ; `validate.sh` vérifie qu'aucune autre n'est
/// écrite ailleurs dans `StudyMode/`.
enum StudyType {
    /// « On s'y met ? », l'écran de lancement.
    static let hero = Carnet.serif(52)
    /// « C'est fait. »
    static let heroDone = Carnet.serif(60)
    /// « Safari attendra » sur le voile.
    static let heroShield = Carnet.serif(48)
    /// Le numéro de l'exercice, en grand.
    static let display = Carnet.serif(34)
    /// Le titre de Claude, au repos.
    static let displaySmall = Carnet.serif(30)
    /// L'horloge de la barre du haut.
    static let barClock = Carnet.clock(20)
}
