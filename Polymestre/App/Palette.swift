import SwiftUI
import UIKit

/// Rôles **sémantiques** dérivés d'une teinte.
///
/// Le système n'a que deux familles littérales (Encre indigo, palette de cours) ;
/// tout le reste est une couleur sémantique d'iOS. Ces rôles sont ce qui permet
/// à une teinte littérale de rester lisible partout sans maintenir une seconde
/// palette à la main : chaque valeur est **résolue** contre la surface réelle,
/// dans l'apparence réelle.
extension Color {

    /// Couleur explicite pour chaque apparence.
    static func dynamic(light: String, dark: String) -> Color {
        guard let lightRGB = ColorContrast.rgb(fromHex: light),
              let darkRGB = ColorContrast.rgb(fromHex: dark) else {
            return Color(hex: light)
        }
        return Color(uiColor: UIColor { traits in
            (traits.userInterfaceStyle == .dark ? darkRGB : lightRGB).uiColor
        })
    }

    private func resolved(_ transform: @escaping (ColorContrast.RGB, ColorContrast.RGB) -> ColorContrast.RGB) -> Color {
        let base = self
        return Color(uiColor: UIColor { traits in
            let style = traits.userInterfaceStyle
            let traitsForStyle = UITraitCollection(userInterfaceStyle: style)
            let hue = UIColor(base).resolvedColor(with: traitsForStyle).contrastRGB
            return transform(hue, ContrastSurface.rgb(for: style)).uiColor
        })
    }

    // MARK: Rôles

    /// Encre pour du **texte** de cette teinte posé sur une carte (≥ 4.5:1).
    ///
    /// À utiliser partout où une couleur porte du sens dans du texte : code de
    /// cours, valeur de charge, rang, message d'erreur, libellé d'état.
    var accessibleInk: Color {
        resolved { hue, surface in
            ColorContrast.accessibleVariant(of: hue, against: surface, target: ColorContrast.textTarget)
        }
    }

    /// Variante pour une **icône ou une marque** de cette teinte sur une carte
    /// (≥ 3:1). Une icône n'a pas besoin du seuil du texte courant, mais ne doit
    /// pas tomber sous le seuil des composants non textuels.
    var accessibleMark: Color {
        resolved { hue, surface in
            ColorContrast.accessibleVariant(of: hue, against: surface, target: ColorContrast.markTarget)
        }
    }

    /// **Remplissage** d'une pastille de cette teinte : explicite, opaque, et
    /// identique quel que soit l'arrière-plan.
    var badgeFill: Color {
        resolved { hue, surface in
            ColorContrast.badgeStyle(hue: hue, surface: surface).fill
        }
    }

    /// **Encre** à poser sur `badgeFill` (≥ 4.5:1 contre ce remplissage).
    var badgeInk: Color {
        resolved { hue, surface in
            ColorContrast.badgeStyle(hue: hue, surface: surface).ink
        }
    }
}
