import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Contraste WCAG et dérivation de variantes lisibles.
///
/// Logique **pure** (aucune dépendance UI), placée dans `Shared/` car l'app
/// **et** l'extension widget en ont besoin. Vérifiable hors app : `validate.sh`
/// compile ce fichier et contrôle que chaque couleur du système atteint
/// effectivement sa cible, en clair comme en sombre.
///
/// Règle du système : aucune couleur qui porte du sens n'est choisie à l'œil.
/// Elle est **résolue** — on ne s'éloigne de la teinte que du minimum nécessaire
/// pour atteindre la cible.
enum ColorContrast {

    struct RGB: Equatable {
        var r: Double   // 0…1
        var g: Double
        var b: Double

        static let black = RGB(r: 0, g: 0, b: 0)
        static let white = RGB(r: 1, g: 1, b: 1)
    }

    // MARK: - Cibles

    /// Texte courant (WCAG AA 4.5:1), avec une marge.
    static let textTarget = 4.6
    /// Composants non textuels : icônes, marques, remplissages (WCAG 3:1), avec une marge.
    static let markTarget = 3.1

    // MARK: - Conversion

    static func rgb(fromHex hex: String) -> RGB? {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        guard Scanner(string: cleaned).scanHexInt64(&value) else { return nil }
        switch cleaned.count {
        case 6:
            return RGB(r: Double((value >> 16) & 0xFF) / 255,
                       g: Double((value >> 8) & 0xFF) / 255,
                       b: Double(value & 0xFF) / 255)
        case 8:
            return RGB(r: Double((value >> 24) & 0xFF) / 255,
                       g: Double((value >> 16) & 0xFF) / 255,
                       b: Double((value >> 8) & 0xFF) / 255)
        default:
            return nil
        }
    }

    static func hexString(_ color: RGB) -> String {
        func channel(_ value: Double) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channel(color.r), channel(color.g), channel(color.b))
    }

    // MARK: - Contraste WCAG 2.1

    private static func linear(_ channel: Double) -> Double {
        channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    static func relativeLuminance(_ color: RGB) -> Double {
        0.2126 * linear(color.r) + 0.7152 * linear(color.g) + 0.0722 * linear(color.b)
    }

    /// Rapport de contraste entre deux couleurs opaques.
    static func ratio(_ a: RGB, _ b: RGB) -> Double {
        let la = relativeLuminance(a)
        let lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    // MARK: - Mélange

    /// `base` mélangé vers `other` ; `amount` 0 = base, 1 = other.
    static func blend(_ base: RGB, _ other: RGB, amount: Double) -> RGB {
        let t = min(1, max(0, amount))
        return RGB(r: base.r + (other.r - base.r) * t,
                   g: base.g + (other.g - base.g) * t,
                   b: base.b + (other.b - base.b) * t)
    }

    // MARK: - Résolution

    /// Variante de `hue` atteignant `target` contre `background`, la plus proche
    /// possible de la teinte d'origine.
    ///
    /// Sur fond clair on assombrit, sur fond sombre on éclaircit : la variante
    /// dépend donc de l'apparence, au lieu d'inverser mécaniquement le thème clair.
    static func accessibleVariant(of hue: RGB, against background: RGB, target: Double) -> RGB {
        if ratio(hue, background) >= target { return hue }
        let toward: RGB = relativeLuminance(background) > 0.5 ? .black : .white
        var low = 0.0
        var high = 1.0
        var best = blend(hue, toward, amount: 1)
        for _ in 0..<28 {
            let mid = (low + high) / 2
            let candidate = blend(hue, toward, amount: mid)
            if ratio(candidate, background) >= target {
                best = candidate
                high = mid
            } else {
                low = mid
            }
        }
        return best
    }

    /// Pastille teintée : **fond explicite** — pas de chaîne d'alpha, dont le
    /// contraste dépendrait du contexte — et encre lisible dessus.
    static func badgeStyle(hue: RGB,
                           surface: RGB,
                           tint: Double = 0.16,
                           textTarget: Double = ColorContrast.textTarget) -> (fill: RGB, ink: RGB) {
        let fill = blend(surface, hue, amount: tint)
        let ink = accessibleVariant(of: hue, against: fill, target: textTarget)
        return (fill, ink)
    }
}

// MARK: - Pont UIKit

#if canImport(UIKit)
extension UIColor {
    /// Composantes RGB opaques, y compris pour les couleurs dynamiques et les
    /// gris (`getRed` échoue sur une couleur créée en blanc, d'où le repli).
    var contrastRGB: ColorContrast.RGB {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if getRed(&r, green: &g, blue: &b, alpha: &a) {
            return ColorContrast.RGB(r: Double(r), g: Double(g), b: Double(b))
        }
        var white: CGFloat = 0
        if getWhite(&white, alpha: &a) {
            return ColorContrast.RGB(r: Double(white), g: Double(white), b: Double(white))
        }
        return .black
    }
}

extension ColorContrast.RGB {
    var uiColor: UIColor {
        UIColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1)
    }
}

/// Surface de référence : la carte groupée, dans l'apparence demandée.
enum ContrastSurface {
    static func rgb(for style: UIUserInterfaceStyle) -> ColorContrast.RGB {
        UIColor.secondarySystemGroupedBackground
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            .contrastRGB
    }

    /// Surface d'un widget : le système y applique son propre fond.
    static func widgetRGB(for style: UIUserInterfaceStyle) -> ColorContrast.RGB {
        style == .dark
            ? ColorContrast.RGB(r: 0.11, g: 0.11, b: 0.12)
            : ColorContrast.RGB(r: 1, g: 1, b: 1)
    }
}
#endif
