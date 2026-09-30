import SwiftUI

/// Palette et constantes visuelles de l'app.
///
/// Deux familles littérales seulement : **l'encre** (interactif) et la
/// **palette d'identité de cours**. Tout le reste est une couleur sémantique
/// d'iOS. Voir `DESIGN.md`.
enum Theme {

    // MARK: Encre indigo
    //
    // Valeurs **résolues**, pas choisies : la variante sombre est celle qui
    // atteint la cible de contraste sur une carte sombre, tout en gardant le
    // libellé blanc d'un bouton plein au-dessus de 4.5:1. Une seule valeur pour
    // les deux apparences échouait (2.76:1 en mode sombre).

    // « Carnet de verre » : l'encre du carnet en clair (noir chaud), une encre
    // de stylo bleue la nuit — le noir disparaîtrait sur le papier sombre, et
    // un libellé blanc doit rester lisible sur le bouton plein (≥ 4.5:1).
    static let accentHex = "#1D1B16"
    static let accentDarkHex = "#EDE6D6"
    static let accentInkHex = "#1D1B16"
    static let accentInkDarkHex = "#EDE6D6"

    /// Teinte interactive : remplissages, `.tint`, grandes marques.
    static var accent: Color {
        #if canImport(UIKit)
        Color.dynamic(light: accentHex, dark: accentDarkHex)
        #else
        Color(hex: accentHex)
        #endif
    }

    /// Encre interactive : texte courant et glyphes posés sur une surface.
    static var accentInk: Color {
        #if canImport(UIKit)
        Color.dynamic(light: accentInkHex, dark: accentInkDarkHex)
        #else
        Color(hex: accentInkHex)
        #endif
    }

    // MARK: Surfaces

    static let cardCorner: CGFloat = 20

    /// Une feuille de papier (« Carnet de verre ») : les anciennes cartes
    /// prennent la même surface que les nouvelles.
    static var softBackground: Color {
        #if canImport(UIKit)
        Carnet.sheet
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    /// Encre « évidée » : la couleur de la surface de carte, employée comme glyphe
    /// **à l'intérieur** d'un remplissage résolu contre cette même surface.
    ///
    /// Le contraste du glyphe est donc exactement celui du remplissage, dans les
    /// deux apparences, sans avoir à choisir blanc ou noir.
    static var knockedOutInk: Color { softBackground }

    // MARK: Identité de cours

    /// Couleurs attribuées aux nouveaux cours. Ce sont des **remplissages** :
    /// utilisées comme texte, elles sont passées par `.accessibleInk`.
    static let coursePalette: [String] = [
        "#4F46E5", "#0EA5E9", "#10B981", "#F59E0B",
        "#EF4444", "#8B5CF6", "#EC4899", "#14B8A6",
        "#F97316", "#6366F1"
    ]

    static func color(forHex hex: String) -> Color { Color(hex: hex) }
}

extension Color {
    /// `Color(hex: "#4F46E5")` ou `Color(hex: "4F46E5")`.
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r, g, b, a: Double
        switch cleaned.count {
        case 8:
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        case 6:
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        default:
            r = 0.5; g = 0.5; b = 0.5; a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
