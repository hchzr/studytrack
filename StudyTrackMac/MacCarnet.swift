import SwiftUI
import AppKit

/// « Carnet » sur le Mac : le même papier et la même encre que l'iPhone.
///
/// L'app Mac parlait sa propre langue — dégradés, ombres, cartes grises du
/// système, couleurs de cours criardes — et ne ressemblait pas à l'iPhone. Ici,
/// les mêmes valeurs que `StudyTrack/App/Carnet.swift` (qui ne compile pas sur
/// macOS : il s'appuie sur UIKit) : fond crème, feuilles, encre, traits fins,
/// titres en serif, couleurs de cours adoucies. Plat par construction : la
/// profondeur vient du papier et des traits, jamais d'une ombre.
enum Carnet {

    // MARK: Papier et encre

    static let ground = Color.paper(light: "#F4F0E6", dark: "#15130F")
    static let sheet = Color.paper(light: "#FFFDF8", dark: "#211E18")
    static let sheetRaised = Color.paper(light: "#EFE9DC", dark: "#2B271F")
    static let ink = Color.paper(light: "#1D1B16", dark: "#EDE6D6")
    static let inkSecondary = Color.paper(light: "#6B655A", dark: "#A89F8D")
    static let inkTertiary = Color.paper(light: "#8F8876", dark: "#7D7566")
    static let rule = Color.paper(light: "#E6DFD0", dark: "#353027")
    static let marker = Color.paper(light: "#FBF1C9", dark: "#4A4020")

    // MARK: Verdicts

    static let correct = Color.paper(light: "#3F7A3F", dark: "#8FC58A")
    static let review = Color.paper(light: "#A86F0C", dark: "#E0B04E")
    static let wrong = Color.paper(light: "#A33A2A", dark: "#E7836F")

    static func color(for correctness: Correctness) -> Color {
        switch correctness {
        case .correct: return correct
        case .partial: return review
        case .wrong: return wrong
        }
    }

    // MARK: Couleurs de cours

    /// La couleur d'un cours adoucie pour le papier (même règle que l'iPhone).
    static func tint(_ hex: String) -> Color {
        let base = NSColor(Color(hex: hex)).usingColorSpace(.sRGB) ?? .gray
        return Color(nsColor: NSColor(name: nil) { appearance in
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            if appearance.isDark {
                return NSColor(hue: h, saturation: min(s, 0.45), brightness: max(b, 0.82), alpha: 1)
            }
            return NSColor(hue: h, saturation: min(s * 0.62, 0.62), brightness: min(b * 0.74, 0.62), alpha: 1)
        })
    }

    static func tint(_ course: Course?) -> Color {
        course.map { tint($0.colorHex) } ?? inkSecondary
    }

    // MARK: Typographie

    /// Les titres et les nombres mis en avant : New York.
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    static func serif(_ style: Font.TextStyle, weight: Font.Weight = .medium) -> Font {
        .system(style, design: .serif).weight(weight)
    }

    /// Les chiffres du chrono : serif, à chasse fixe, comme le cadran de l'iPhone.
    static func clock(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif).monospacedDigit()
    }

    // MARK: Mesures

    static let sheetCorner: CGFloat = 14
    static let tileCorner: CGFloat = 8
    static let pagePadding: CGFloat = 32
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

extension Color {
    /// Une couleur explicite par apparence.
    static func paper(light: String, dark: String) -> Color {
        let light = NSColor(Color(hex: light)), dark = NSColor(Color(hex: dark))
        return Color(nsColor: NSColor(name: nil) { $0.isDark ? dark : light })
    }
}

// MARK: - Feuilles et traits

/// Une feuille posée sur le papier : fond, coins arrondis, un trait fin.
struct PaperSheet: ViewModifier {
    var padding: CGFloat = 16
    var highlighted: Color?

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous)
                .strokeBorder(highlighted ?? Carnet.rule, lineWidth: highlighted == nil ? 1 : 1.5))
    }
}

/// Le trait entre deux lignes d'une feuille.
struct PaperRule: View {
    var inset: CGFloat = 0

    var body: some View {
        Rectangle().fill(Carnet.rule).frame(height: 1).padding(.leading, inset)
    }
}

/// Un sur-titre : petites capitales espacées.
struct Kicker: View {
    let text: String
    var color: Color = Carnet.inkSecondary

    init(_ text: String, color: Color = Carnet.inkSecondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(1.1)
            .foregroundStyle(color)
    }
}

/// Le fond de chaque page de la fenêtre : le papier.
struct PaperPage: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(Carnet.ground)
    }
}

extension View {
    func paperSheet(padding: CGFloat = 16, highlighted: Color? = nil) -> some View {
        modifier(PaperSheet(padding: padding, highlighted: highlighted))
    }
    func paperPage() -> some View { modifier(PaperPage()) }
}

// MARK: - Boutons

/// Le bouton plein : encre sur papier (papier sur encre la nuit), ou la couleur
/// du cours quand on la donne.
struct InkButtonStyle: ButtonStyle {
    var tint: Color?
    var large = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(large ? .body.weight(.semibold) : .callout.weight(.semibold))
            .foregroundStyle(tint == nil ? Carnet.ground : .white)
            .padding(.horizontal, large ? 20 : 14)
            .frame(minHeight: large ? 40 : 30)
            .background(tint ?? Carnet.ink, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .contentShape(Capsule())
    }
}

/// Le bouton secondaire : une feuille en retrait.
struct PaperButtonStyle: ButtonStyle {
    var large = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        PaperButtonBody(configuration: configuration, large: large, isEnabled: isEnabled)
    }

    private struct PaperButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let large: Bool
        let isEnabled: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(large ? .body.weight(.medium) : .callout.weight(.medium))
                .foregroundStyle(Carnet.ink)
                .padding(.horizontal, large ? 18 : 12)
                .frame(minHeight: large ? 40 : 28)
                .background(hovering ? Carnet.rule : Carnet.sheetRaised, in: Capsule())
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.35)
                .contentShape(Capsule())
                .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == InkButtonStyle {
    static var ink: InkButtonStyle { InkButtonStyle() }
    static var inkLarge: InkButtonStyle { InkButtonStyle(large: true) }
}

extension ButtonStyle where Self == PaperButtonStyle {
    static var paper: PaperButtonStyle { PaperButtonStyle() }
    static var paperLarge: PaperButtonStyle { PaperButtonStyle(large: true) }
}

// MARK: - Pastilles

/// Une pastille de cours : point de couleur, code.
struct CourseTag: View {
    let code: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(code).font(.caption.weight(.semibold)).foregroundStyle(tint)
        }
    }
}

/// Le verdict d'une correction : un mot, sa couleur, un glyphe (jamais la
/// couleur seule).
struct VerdictTag: View {
    let correctness: Correctness

    var body: some View {
        let color = Carnet.color(for: correctness)
        HStack(spacing: 4) {
            Image(systemName: glyph).font(.system(size: 8, weight: .heavy))
            Text(correctness.shortLabel)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(color.opacity(0.12), in: Capsule())
    }

    private var glyph: String {
        switch correctness {
        case .correct: return "checkmark"
        case .partial: return "equal"
        case .wrong: return "xmark"
        }
    }
}
