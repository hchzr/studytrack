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
        guard let normalized = TeXNormalizer.normalize(tex), var latex = MathSpacingGuard.safe(normalized) else { return nil }
        var attempt = 0
        while true {
            var math = MathImage(latex: latex, fontSize: size, textColor: .black,
                                 labelMode: display ? .display : .text, textAlignment: .left)
            let (error, picture, layout) = math.asImage()
            if error == nil, let picture, let layout, picture.size.width > 0, picture.size.height > 0 {
                return finished(picture, layout)
            }
            // Une commande que le moteur ne connaît pas (`\argsinh`, une macro
            // du cours) : son nom, en romain, plutôt que toute la formule perdue.
            attempt += 1
            guard attempt <= 4, let error, let unknown = Self.unknownCommand(error.localizedDescription),
                  let retry = MathSpacingGuard.safe(latex.replacingOccurrences(
                      of: "\\\\\(unknown)(?![a-zA-Z])", with: "\\\\mathrm{\(unknown)}", options: .regularExpression)),
                  retry != latex else { return nil }
            latex = retry
        }
    }

    /// « Invalid command \argsinh » → « argsinh ».
    private static func unknownCommand(_ message: String) -> String? {
        guard let range = message.range(of: #"Invalid command \\([a-zA-Z]+)"#, options: .regularExpression) else { return nil }
        return String(message[range].split(separator: "\\").last ?? "")
    }

    private static func finished(_ picture: MTImage, _ layout: MathImage.LayoutInfo) -> Rendered {
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

/// Ce qui faisait planter SwiftMath (en Debug) : `getInterElementSpace` affirme
/// qu'un opérateur binaire n'est jamais suivi d'une relation, d'une
/// ponctuation ou d'une fermeture. `MTMathList.finalized` répare ces cas… en
/// comptant les espaces (`\,`, `\quad`) et les styles comme voisins, alors que
/// le typographe les saute : `a + \, = b` passe le premier et tue le second.
///
/// On rejoue donc, avant de dessiner, le voisinage tel que le typographe le
/// verra. Une formule qui buterait est retentée sans ses espaces ; si elle
/// bute encore, elle n'est pas dessinée (l'affichage en ligne prend le relais).
enum MathSpacingGuard {
    /// Le LaTeX à dessiner, ou `nil` s'il ferait planter le moteur.
    static func safe(_ latex: String) -> String? {
        guard let list = MTMathListBuilder.build(fromString: latex) else { return latex }
        guard wouldTrap(list.finalized) else { return latex }
        let stripped = withoutSpacing(latex)
        guard stripped != latex, let retry = MTMathListBuilder.build(fromString: stripped) else { return nil }
        return wouldTrap(retry.finalized) ? nil : stripped
    }

    /// Les commandes d'espacement, que le typographe saute.
    static func withoutSpacing(_ latex: String) -> String {
        latex.replacingOccurrences(of: #"\\(?:qquad|quad|[,;:!> ])|~"#, with: " ", options: .regularExpression)
    }

    // ord 0, op 1, bin 2, rel 3, open 4, close 5, punct 6, inner 7, radical 8 (à gauche seulement)
    private static let invalid: Set<[Int]> = [[1, 2], [2, 2], [2, 3], [2, 5], [2, 6], [3, 2], [4, 2], [6, 2]]

    private static func index(_ type: MTMathAtomType, left: Bool) -> Int {
        switch type {
        case .largeOperator: return 1
        case .binaryOperator: return 2
        case .relation: return 3
        case .open: return 4
        case .close: return 5
        case .punctuation: return 6
        case .fraction, .inner, .table: return 7
        case .radical: return left ? 8 : 0
        default: return 0
        }
    }

    /// Le typographe buterait-il sur cette liste (ou une liste qu'elle contient) ?
    static func wouldTrap(_ list: MTMathList?) -> Bool {
        guard let list else { return false }
        var previous: MTMathAtomType?
        for atom in list.atoms {
            if children(of: atom).contains(where: wouldTrap) { return true }
            // Un trait au-dessus dont l'indice ou l'exposant porte lui-même un
            // indice (`\overline{S}_{a^{b}}`) : l'index de l'atome tombe à −1
            // et le typographe s'arrête net, en Release aussi.
            if atom.type == .overline, [atom.subScript, atom.superScript].contains(where: hasScripts) { return true }
            // Le typographe ne retient pas les espaces ni les styles comme voisins.
            if atom.type == .space || atom.type == .style { continue }
            if let previous, invalid.contains([index(previous, left: true), index(atom.type, left: false)]) { return true }
            previous = atom.type
        }
        // Une liste espacée (\left…\right) se ferme par une « fermeture ».
        return previous == .binaryOperator
    }

    private static func hasScripts(_ list: MTMathList?) -> Bool {
        guard let list else { return false }
        return list.atoms.contains { atom in
            atom.subScript != nil || atom.superScript != nil || children(of: atom).contains(where: hasScripts)
        }
    }

    private static func children(of atom: MTMathAtom) -> [MTMathList?] {
        var lists: [MTMathList?] = [atom.subScript, atom.superScript]
        switch atom {
        case let fraction as MTFraction: lists += [fraction.numerator, fraction.denominator]
        case let radical as MTRadical: lists += [radical.radicand, radical.degree]
        case let inner as MTInner: lists.append(inner.innerList)
        case let accent as MTAccent: lists.append(accent.innerList)
        case let line as MTOverLine: lists.append(line.innerList)
        case let line as MTUnderLine: lists.append(line.innerList)
        case let color as MTMathColor: lists.append(color.innerList)
        case let color as MTMathTextColor: lists.append(color.innerList)
        case let box as MTMathColorbox: lists.append(box.innerList)
        // Les cases d'un tableau ne sont finalisées qu'au moment de les
        // dessiner : `&=-1` y devient un moins unaire, pas une relation suivie
        // d'un opérateur. Sans ça, une centaine de formules alignées du
        // polycopié étaient refusées pour rien.
        case let table as MTMathTable: lists += table.cells.flatMap { $0 }.map { $0.finalized }
        default: break
        }
        return lists
    }
}
