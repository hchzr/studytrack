import SwiftUI
import UIKit

/// « Carnet de verre » : le langage visuel de l'app.
///
/// Du **papier** et de l'**encre** pour ce qu'on lit — fond crème, titres en
/// serif (New York), traits fins, couleurs de cours adoucies — et du **verre**
/// (Liquid Glass d'iOS 26) pour ce qui flotte : la barre d'onglets, le chrono,
/// les commandes d'un exercice, la carte « En cours ». Le papier se lit, le
/// verre se touche. Voir `DESIGN.md`.
enum Carnet {

    // MARK: Papier et encre

    /// Le fond des écrans : papier crème, papier sombre la nuit.
    static let ground = Color.dynamic(light: "#F4F0E6", dark: "#15130F")
    /// Une feuille posée sur le fond : listes groupées, cartes.
    static let sheet = Color.dynamic(light: "#FFFDF8", dark: "#211E18")
    /// Une feuille en retrait : puces, pastilles, champs.
    static let sheetRaised = Color.dynamic(light: "#EFE9DC", dark: "#2B271F")
    /// L'encre : texte, glyphes, boutons pleins.
    static let ink = Color.dynamic(light: "#1D1B16", dark: "#EDE6D6")
    static let inkSecondary = Color.dynamic(light: "#6B655A", dark: "#A89F8D")
    static let inkTertiary = Color.dynamic(light: "#8F8876", dark: "#7D7566")
    /// Les traits : séparateurs, contours.
    static let rule = Color.dynamic(light: "#E6DFD0", dark: "#353027")
    /// Le surligneur : la sous-question en cours dans un énoncé.
    static let marker = Color.dynamic(light: "#FBF1C9", dark: "#4A4020")

    // MARK: Verdicts de correction

    static let correct = Color.dynamic(light: "#3F7A3F", dark: "#8FC58A")
    static let review = Color.dynamic(light: "#A86F0C", dark: "#E0B04E")
    static let wrong = Color.dynamic(light: "#A33A2A", dark: "#E7836F")

    static func color(for correctness: Correctness) -> Color {
        switch correctness {
        case .correct: return correct
        case .partial: return review
        case .wrong: return wrong
        }
    }

    // MARK: Couleurs de cours

    /// La couleur d'un cours, **adoucie** pour le papier : la palette d'origine
    /// (indigo, cyan, émeraude…) criait sur le crème. Même teinte, saturation
    /// et luminosité ramenées vers l'encre ; plus claire la nuit.
    static func tint(_ hex: String) -> Color {
        let base = UIColor(Color(hex: hex))
        return Color(uiColor: UIColor { traits in
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            if traits.userInterfaceStyle == .dark {
                return UIColor(hue: h, saturation: min(s, 0.45), brightness: max(b, 0.82), alpha: 1)
            }
            return UIColor(hue: h, saturation: min(s * 0.62, 0.62), brightness: min(b * 0.74, 0.62), alpha: 1)
        })
    }

    /// Le fond léger d'une tuile d'icône de cette couleur.
    static func wash(_ hex: String) -> Color {
        tint(hex).opacity(0.16)
    }

    // MARK: Mesures

    static let sheetCorner: CGFloat = 20
    static let tileCorner: CGFloat = 9
    static let screenPadding: CGFloat = 16
    static let rowInset: CGFloat = 14

    // MARK: Typographie

    /// Titres de section et nombres mis en avant : serif (New York).
    static func serif(_ style: Font.TextStyle, weight: Font.Weight = .medium) -> Font {
        .system(style, design: .serif).weight(weight)
    }

    /// Les chiffres qui s'alignent : chrono, numéros d'exercice.
    static func mono(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .monospaced).weight(weight)
    }

    /// Applique les titres en serif à toute l'app (grands titres de navigation).
    @MainActor
    static func installAppearance() {
        let large = UIFont.preferredFont(forTextStyle: .largeTitle)
        let inline = UIFont.preferredFont(forTextStyle: .headline)
        func serif(_ font: UIFont, weight: UIFont.Weight) -> UIFont {
            let base = UIFont.systemFont(ofSize: font.pointSize, weight: weight)
            guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
            return UIFont(descriptor: descriptor, size: font.pointSize)
        }
        let appearance = UINavigationBar.appearance()
        appearance.largeTitleTextAttributes = [.font: serif(large, weight: .medium)]
        appearance.titleTextAttributes = [.font: serif(inline, weight: .semibold)]
    }
}

// MARK: - Verre

extension View {
    /// Un panneau de verre (Liquid Glass sur iOS 26, matière translucide avant).
    @ViewBuilder
    func carnetGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.5), lineWidth: 0.5))
        }
    }

    /// Le fond papier d'un écran, sous les listes et formulaires aussi.
    func carnetBackground() -> some View {
        self.scrollContentBackground(.hidden)
            .background(Carnet.ground.ignoresSafeArea())
    }

    /// Le sous-titre d'un écran, sous son grand titre (iOS 26), sinon rien :
    /// l'écran le montre alors dans son contenu.
    @ViewBuilder
    func carnetSubtitle(_ text: String) -> some View {
        if #available(iOS 26.0, *) {
            self.navigationSubtitle(text)
        } else {
            self
        }
    }
}

// MARK: - Formulaires

extension View {
    /// Un formulaire sur papier : fond crème, encre pour les contrôles, icônes
    /// d'encre en retrait. Les lignes prennent `Carnet.sheet` via
    /// `.listRowBackground` posé sur leurs sections.
    func carnetForm() -> some View {
        self.scrollContentBackground(.hidden)
            .background(Carnet.ground.ignoresSafeArea())
            .tint(Carnet.ink)
            .labelStyle(CarnetFormLabelStyle())
    }
}

/// L'icône d'une ligne de réglage : à l'encre secondaire, sur une largeur fixe
/// pour que les titres s'alignent — pas de pastille bleue.
struct CarnetFormLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 14) {
            configuration.icon
                .font(.body)
                .foregroundStyle(Carnet.inkSecondary)
                .frame(width: 24)
            configuration.title
        }
    }
}

/// L'en-tête d'une section de formulaire : serif, à l'encre, sans capitales.
struct CarnetFormHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(Carnet.serif(.title3))
            .foregroundStyle(Carnet.ink)
            .textCase(nil)
            .padding(.leading, -8)
            .padding(.bottom, 2)
    }
}

// MARK: - Boutons

/// Le bouton plein : encre sur papier, papier sur encre la nuit.
struct CarnetPrimaryButtonStyle: ButtonStyle {
    var fullWidth = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Carnet.ground)
            .padding(.horizontal, 20)
            .frame(minHeight: 48)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(Carnet.ink, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

/// Le bouton secondaire : un contour d'encre, ou une feuille en retrait.
struct CarnetSecondaryButtonStyle: ButtonStyle {
    var fullWidth = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(Carnet.ink)
            .padding(.horizontal, 18)
            .frame(minHeight: 48)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(Carnet.sheetRaised, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.35)
    }
}

extension ButtonStyle where Self == CarnetPrimaryButtonStyle {
    static var carnetPrimary: CarnetPrimaryButtonStyle { CarnetPrimaryButtonStyle() }
    static var carnetPrimaryWide: CarnetPrimaryButtonStyle { CarnetPrimaryButtonStyle(fullWidth: true) }
}

extension ButtonStyle where Self == CarnetSecondaryButtonStyle {
    static var carnetSecondary: CarnetSecondaryButtonStyle { CarnetSecondaryButtonStyle() }
    static var carnetSecondaryWide: CarnetSecondaryButtonStyle { CarnetSecondaryButtonStyle(fullWidth: true) }
}

// MARK: - Composants

/// Un écran de papier : défilement, marges, fond.
struct CarnetScroll<Content: View>: View {
    var spacing: CGFloat = 22
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) {
                content
            }
            .padding(.horizontal, Carnet.screenPadding)
            .padding(.top, 4)
            .padding(.bottom, 32)
            .frame(maxWidth: Layout.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Carnet.ground.ignoresSafeArea())
    }
}

/// Le titre d'une partie d'écran : serif, et une action ou une précision à droite.
struct CarnetSectionTitle<Trailing: View>: View {
    let title: String
    var trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(Carnet.serif(.title3))
                .foregroundStyle(Carnet.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing
                .font(.subheadline)
                .foregroundStyle(Carnet.inkSecondary)
        }
        .padding(.horizontal, 6)
    }
}

extension CarnetSectionTitle where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}

/// Un sur-titre : petites capitales espacées, au-dessus d'un contenu.
struct CarnetKicker: View {
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

/// Une feuille : des lignes séparées par des traits fins, coins arrondis.
struct CarnetSheet<Content: View>: View {
    var padding: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
    }
}

/// Le trait entre deux lignes d'une feuille, aligné sur le texte.
struct CarnetRule: View {
    var inset: CGFloat = 56

    var body: some View {
        Rectangle()
            .fill(Carnet.rule)
            .frame(height: 1)
            .padding(.leading, inset)
    }
}

/// Une tuile d'icône teintée (la couleur du cours, en lavis).
struct CarnetIconTile: View {
    let systemName: String
    let tint: Color
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: Carnet.tileCorner, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Une ligne de feuille : tuile, titre, précision, et ce qu'on veut à droite.
struct CarnetRow<Trailing: View>: View {
    var icon: String?
    var tint: Color = Carnet.inkSecondary
    let title: String
    var subtitle: String?
    var subtitleColor: Color = Carnet.inkSecondary
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                CarnetIconTile(systemName: icon, tint: tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(Carnet.ink)
                    .lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(subtitleColor)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, Carnet.rowInset)
        .padding(.vertical, 11)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

extension CarnetRow where Trailing == EmptyView {
    init(icon: String? = nil, tint: Color = Carnet.inkSecondary, title: String,
         subtitle: String? = nil, subtitleColor: Color = Carnet.inkSecondary) {
        self.icon = icon
        self.tint = tint
        self.title = title
        self.subtitle = subtitle
        self.subtitleColor = subtitleColor
        self.trailing = EmptyView()
    }
}

/// Un anneau d'avancement, avec son libellé au centre (« 3/7 »).
struct CarnetRing: View {
    let value: Double
    var tint: Color = Carnet.ink
    var label: String?
    var size: CGFloat = 52
    var lineWidth: CGFloat = 5

    var body: some View {
        ZStack {
            Circle().stroke(Carnet.rule, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(value, 1)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Motion.progress, value: value)
            if let label {
                Text(label)
                    .font(Carnet.mono(.caption, weight: .medium))
                    .foregroundStyle(Carnet.ink)
                    .minimumScaleFactor(0.6)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(label ?? "\(Int(value * 100)) %")
    }
}

/// Une barre fine d'avancement, sur trait de papier.
struct CarnetBar: View {
    let value: Double
    var tint: Color = Carnet.ink
    var height: CGFloat = 3

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Carnet.rule)
                Capsule().fill(tint)
                    .frame(width: proxy.size.width * max(0, min(value, 1)))
                    .animation(Motion.progress, value: value)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// Une puce (« S4 · Types avancés »), choisie ou non.
struct CarnetChip: View {
    let text: String
    var isSelected = false

    var body: some View {
        Text(text)
            .font(.subheadline.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Carnet.ground : Carnet.inkSecondary)
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(isSelected ? Carnet.ink : Carnet.sheet, in: Capsule())
    }
}

/// Un chiffre mis en avant, avec son libellé : tuile de bilan.
struct CarnetStat: View {
    let label: String
    let value: String
    var detail: String?
    var detailColor: Color = Carnet.inkSecondary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(Carnet.inkSecondary)
            Text(value)
                .font(Carnet.serif(.title2))
                .foregroundStyle(Carnet.ink)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(detailColor).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Un état vide : une phrase, et l'action qui le remplit.
struct CarnetEmpty: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Carnet.inkSecondary)
            Text(title).font(Carnet.serif(.title3)).foregroundStyle(Carnet.ink)
            Text(message).font(.subheadline).foregroundStyle(Carnet.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.carnetPrimary)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
    }
}
