import SwiftUI
import SwiftMath
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Les formules mises en page pour de vrai : fractions, matrices, systèmes,
/// indices empilés. Le TeX des sites (`TeXNormalizer`) passe dans SwiftMath,
/// qui dessine une image ; elle prend la couleur du texte (`template`) et se
/// pose sur la ligne de base, au milieu d'une phrase comme seule sur sa ligne.
///
/// Une formule que le moteur ne sait pas lire garde l'affichage en ligne
/// (`MacMathText`) : jamais de TeX brut à l'écran.
@MainActor
enum MathTypeset {
    struct Rendered {
        let image: Image
        let size: CGSize
        /// Ce qui descend sous la ligne de base (les indices, le bas d'une matrice).
        let descent: CGFloat
    }

    private final class Box {
        let value: Rendered?
        init(_ value: Rendered?) { self.value = value }
    }

    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 600
        return cache
    }()

    /// La formule dessinée, ou `nil` si elle ne peut pas l'être.
    static func render(_ tex: String, size: CGFloat, display: Bool) -> Rendered? {
        let key = "\(display ? "D" : "T")\(Int(size * 10))|\(tex)" as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        let rendered = draw(tex, size: size, display: display)
        cache.setObject(Box(rendered), forKey: key)
        return rendered
    }

    private static func draw(_ tex: String, size: CGFloat, display: Bool) -> Rendered? {
        guard let latex = TeXNormalizer.normalize(tex) else { return nil }
        var math = MathImage(latex: latex, fontSize: size, textColor: .black,
                             labelMode: display ? .display : .text, textAlignment: .left)
        let (error, picture, layout) = math.asImage()
        guard error == nil, let picture, let layout, picture.size.width > 0, picture.size.height > 0 else { return nil }
        #if os(macOS)
        picture.isTemplate = true
        let image = Image(nsImage: picture)
        #else
        let image = Image(uiImage: picture.withRenderingMode(.alwaysTemplate))
        #endif
        return Rendered(image: image.renderingMode(.template), size: picture.size, descent: layout.descent)
    }

    /// Une formule dans une phrase : une `Text` qui se concatène aux autres.
    static func inline(_ tex: String, size: CGFloat) -> Text? {
        guard let rendered = render(tex, size: size * 1.08, display: false) else { return nil }
        return Text(rendered.image).baselineOffset(-rendered.descent)
    }
}

/// Une formule seule sur sa ligne, centrée ; si elle est plus large que la
/// colonne (une matrice 4 × 5), elle défile au lieu d'être coupée.
struct DisplayMathView: View {
    let tex: String
    var size: CGFloat = 15

    var body: some View {
        if let rendered = MathTypeset.render(tex, size: size * 1.15, display: true) {
            ViewThatFits(in: .horizontal) {
                rendered.image
                    .frame(width: rendered.size.width, height: rendered.size.height)
                    .frame(maxWidth: .infinity)
                ScrollView(.horizontal, showsIndicators: true) {
                    rendered.image
                        .frame(width: rendered.size.width, height: rendered.size.height)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.vertical, 6)
            .accessibilityLabel(MathMarkup.plain(tex))
        } else {
            MacMathText(tex, size: size * 1.2, design: .serif)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
    }
}
