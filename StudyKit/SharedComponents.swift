import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// Les briques d'interface communes à l'iPhone et au Mac : mise en page,
// mouvement, formules, et les modificateurs propres à une plateforme (titre en
// ligne, claviers) qui ne font rien sur l'autre. Elles permettent aux mêmes
// formulaires (cours, évaluation, série, import d'un PDF) de servir des deux
// côtés.

// MARK: - Constantes de mise en page

/// Échelle d'espacement et constantes de mise en page.
///
/// Une seule échelle pour toute l'app : base 2 avec des pas utiles de 4. Un écart
/// doit exprimer une relation — deux lignes d'un même libellé, deux blocs d'une
/// carte, deux sections — jamais un ajustement au cas par cas.
enum Layout {
    /// Dans un badge ; entre une valeur et son libellé.
    static let micro: CGFloat = 2
    /// Entre un libellé et son sous-libellé.
    static let tight: CGFloat = 4
    /// Entre un glyphe et son texte dans une pastille.
    static let snug: CGFloat = 6
    /// Entre les éléments d'une même ligne.
    static let inline: CGFloat = 8
    /// Entre deux contrôles voisins.
    static let control: CGFloat = 10
    /// Entre les blocs d'une carte.
    static let block: CGFloat = 12
    /// Entre les blocs principaux d'une carte.
    static let cardGap: CGFloat = 14
    /// Marge d'écran, et marge intérieure d'une carte.
    static let gutter: CGFloat = 16
    /// Entre deux sections de premier niveau.
    static let sectionGap: CGFloat = 24

    /// Cible tactile minimale (HIG).
    static let minTouch: CGFloat = 44

    // MARK: Adaptation à la largeur

    /// Largeur maximale d'une colonne de contenu.
    ///
    /// Un iPad 13″ offre ~1030 pt de large. Sans borne, la colonne d'un iPhone
    /// s'étire sur toute cette largeur : lignes de texte de 150 caractères, un
    /// bouton d'action de 1000 pt, et le bouton radio d'une ligne à 900 pt de son
    /// libellé. 700 pt garde une mesure lisible (~90 caractères) et laisse des
    /// marges qui font lire la page comme composée plutôt qu'étirée.
    static let readableWidth: CGFloat = 700

    /// Largeur maximale d'un contenu qui occupe deux colonnes (tableau de bord).
    static let wideWidth: CGFloat = 1100

    /// Largeur minimale d'une carte dans une grille adaptative (sections, cours).
    static let gridCardMin: CGFloat = 300

    // Alias historiques — mêmes valeurs, noms déjà utilisés par les écrans.
    static let screenPadding = gutter
    static let cardSpacing = cardGap
    static let sectionSpacing = sectionGap
}

extension View {
    /// Borne la colonne de contenu en classe de taille « regular » et la centre.
    ///
    /// En compact (iPhone portrait) la largeur proposée est déjà inférieure à la
    /// borne : la modification est sans effet. En regular (iPad, iPhone Max en
    /// paysage) le contenu cesse de s'étirer et se cale au centre.
    func adaptiveColumn(maxWidth: CGFloat = Layout.readableWidth) -> some View {
        frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Comme `adaptiveColumn`, mais pour un `List`.
    ///
    /// Un `List` porte son propre fond : le rétrécir seul laisserait, de chaque
    /// côté, des bandes de la couleur de la fenêtre au lieu du fond groupé. On
    /// repeint donc les marges avec le même fond.
    func adaptiveListColumn(maxWidth: CGFloat = Layout.readableWidth) -> some View {
        frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
            .background(Carnet.ground.ignoresSafeArea())
    }
}

// MARK: - Mouvement

/// Les courbes de l'app, nommées une fois.
///
/// Deux écrans voisins qui s'ouvrent à deux rythmes différents se lisent comme
/// deux apps. Tout ce qui se déplie, se coche ou progresse passe donc par ici.
///
/// Avec « Réduire les animations », les courbes qui déplacent deviennent un
/// fondu court. Le réglage est lu à chaque appel : il suit le lecteur sans
/// qu'aucun écran ait à le relayer.
enum Motion {
    /// Déplier, replier, changer de jour : la courbe par défaut.
    static var snappy: Animation { reduced ?? .snappy(duration: 0.28) }
    /// Une barre ou un anneau qui avance, et le pourcentage qui l'accompagne :
    /// une seule courbe pour les deux, sinon le chiffre et la barre divergent.
    static let progress = Animation.smooth(duration: 0.35)
    /// Passer d'une étape à l'autre d'un parcours.
    static var step: Animation { reduced ?? .smooth(duration: 0.4) }

    private static var reduced: Animation? {
        #if os(iOS)
        UIAccessibility.isReduceMotionEnabled ? .easeInOut(duration: 0.2) : nil
        #else
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .easeInOut(duration: 0.2) : nil
        #endif
    }
}

/// Le bouton s'enfonce sous le doigt dès le contact.
///
/// Plat, conformément au système : une échelle, jamais une ombre.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(duration: 0.16, bounce: 0), value: configuration.isPressed)
    }
}

/// Un texte avec des formules : indices et exposants à leur place, symboles
/// mathématiques au lieu des commandes (`a_n` → aₙ, `\le` → ≤, `\frac{1}{2}` → ½).
///
/// Le découpage vit dans `MathMarkup` (pur, testé) ; cette vue ne fait que
/// l'afficher. Les indices et exposants prennent une taille de texte plus petite
/// **du même système** : ils suivent la taille de texte du lecteur.
struct MathText: View {
    let source: String
    var font: Font = .body

    @ScaledMetric(relativeTo: .body) private var superOffset: CGFloat = 5
    @ScaledMetric(relativeTo: .body) private var subOffset: CGFloat = -3

    init(_ source: String, font: Font = .body) {
        self.source = source
        self.font = font
    }

    var body: some View {
        rendered
            .font(font)
            .accessibilityLabel(MathMarkup.plain(source))
    }

    private var rendered: Text {
        guard MathMarkup.hasMarkup(source) else { return Text(source) }
        return MathMarkup.runs(source).reduce(Text("")) { text, run in
            switch run.style {
            case .normal:
                return text + Text(run.text)
            case .superscripted:
                return text + Text(run.text).font(Self.smaller(font)).baselineOffset(superOffset)
            case .subscripted:
                return text + Text(run.text).font(Self.smaller(font)).baselineOffset(subOffset)
            }
        }
    }

    /// Le style de texte d'un cran plus petit, pour les indices et exposants.
    static func smaller(_ font: Font) -> Font {
        switch font {
        case .largeTitle, .title: return .title3
        case .title2, .title3: return .body
        case .headline, .body: return .footnote
        case .callout, .subheadline: return .caption
        default: return .caption2
        }
    }
}


// MARK: - Tenir pour agir

/// Un bouton qu'il faut **tenir** : le temps d'y penser (terminer une session,
/// la sortie d'urgence d'un mode verrouillé).
///
/// Pourquoi pas `onLongPressGesture` : sa reconnaissance dépend du défilement
/// au-dessus. Dans l'écran du mode étude — une liste, une fenêtre qui glisse — un
/// appui franc était souvent pris pour le début d'un glissement, ou le geste
/// rendu à la fin du défilement : la barre avançait et la session ne finissait
/// jamais. Ici, le contact est suivi à la milliseconde par `DragGesture`, le
/// temps s'arrête si le doigt glisse de plus de 44 points (on peut donc encore
/// faire défiler la page en partant de ce bouton), et un appui bref dit ce qu'il
/// faut faire au lieu de ne rien faire.
///
/// Lisible et utilisable sans le doigt : c'est un bouton (VoiceOver, Switch
/// Control, Full Keyboard Access), et son action passe **tout de suite** — tenir
/// n'est qu'un ralentisseur pour la main, jamais une barrière d'accessibilité.
struct HoldToActButton<Label: View>: View {
    /// Ce que le doigt doit tenir, en secondes. `0` : un appui suffit.
    var duration: Double
    /// Ce que fait le geste une fois tenu.
    var action: () -> Void
    @ViewBuilder var label: (Bool) -> Label

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: Double = 0
    @State private var pressed = false
    /// Ce qu'il reste à tenir, recalculé par la minuterie.
    @State private var remaining: Double = 0
    @State private var ticker: Task<Void, Never>?
    /// L'appui bref n'est pas une erreur : on dit quoi faire une fois.
    @State private var hint = false

    var body: some View {
        label(pressed)
            .background {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Carnet.sheetRaised)
                        Capsule()
                            .fill(Carnet.correct.opacity(pressed ? 0.72 : 0.5))
                            .frame(width: max(0, proxy.size.width * progress))
                    }
                }
            }
            .clipShape(Capsule())
            .contentShape(Capsule())
            .overlay(alignment: .bottom) {
                if hint {
                    Text(String(localized: "Maintiens le doigt jusqu'au bout."))
                        .font(.caption2)
                        .foregroundStyle(Carnet.inkSecondary)
                        .offset(y: 18)
                        .transition(.opacity)
                }
            }
            .gesture(drag)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(String(localized: "\(Int((progress * 100).rounded())) % tenu"))
            .accessibilityAction { if duration > 0 { action() } }
            .onDisappear { cancel() }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !pressed {
                    pressed = true
                    hint = false
                    if HoldProgress(duration: duration).duration <= 0 {
                        // Un appui suffit : on agit au contact, comme un bouton.
                        action()
                        return
                    }
                    startTicker()
                }
                // Trop loin du doigt d'origine : l'appui se relâche (et le
                // défilement peut prendre le relais).
                if !HoldProgress.isOnButton(translation: value.translation) {
                    cancel()
                    return
                }
            }
            .onEnded { _ in
                let wasPressing = pressed
                let held = progress * duration
                cancel()
                if wasPressing, HoldProgress(duration: duration).shouldExplainRelease(after: held) {
                    withAnimation(Motion.snappy) { hint = true }
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        withAnimation(Motion.snappy) { hint = false }
                    }
                }
            }
    }

    private func startTicker() {
        let started = Date()
        progress = 0
        remaining = duration
        ticker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { return }
                let elapsed = Date().timeIntervalSince(started)
                let hold = HoldProgress(duration: duration)
                withAnimation(.linear(duration: 0.016)) { progress = hold.fraction(after: elapsed) }
                remaining = hold.remaining(after: elapsed)
                if hold.isComplete(after: elapsed) {
                    ticker = nil
                    pressed = false
                    Haptics.success()
                    action()
                    return
                }
            }
        }
    }

    private func cancel() {
        ticker?.cancel()
        ticker = nil
        guard pressed || progress > 0 else { return }
        pressed = false
        withAnimation(reduceMotion ? Motion.step : .easeOut(duration: 0.22)) { progress = 0 }
    }
}

// MARK: - Plateformes

#if os(macOS)
/// Pas de retour haptique sur le Mac : les mêmes appels ne font rien.
@MainActor
enum Haptics {
    static func tap() {}
    static func soft() {}
    static func removed() {}
    static func success() {}
    static func warning() {}
    static func error() {}
}
#endif
// `PlatformImage` et `Image(platformImage:)` : voir `SiteReaders.swift`.

extension View {
    /// Titre en ligne dans la barre (iPhone) ; sans effet sur le Mac.
    @ViewBuilder
    func inlineTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Clavier numérique (iPhone) ; sans effet sur le Mac.
    @ViewBuilder
    func numericField(decimal: Bool = false) -> some View {
        #if os(iOS)
        self.keyboardType(decimal ? .decimalPad : .numberPad)
        #else
        self
        #endif
    }

    /// Clavier d'adresse, sans majuscule ni correction (iPhone).
    @ViewBuilder
    func urlField() -> some View {
        #if os(iOS)
        self.keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }

    /// Sans majuscule automatique (iPhone).
    @ViewBuilder
    func noAutocapitalization() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never)
        #else
        self
        #endif
    }
}

#if os(macOS)
extension View {
    /// Le fond papier d'un écran (même nom que sur l'iPhone).
    func carnetBackground() -> some View {
        self.scrollContentBackground(.hidden)
            .background(Carnet.ground)
    }
}
#endif

extension View {
    /// La liste groupée de chaque plateforme (encarts sur l'iPhone).
    @ViewBuilder
    func groupedList() -> some View {
        #if os(iOS)
        self.listStyle(.insetGrouped)
        #else
        self.listStyle(.inset)
        #endif
    }
}

#if os(macOS)
extension Color {
    /// Sur le Mac, les teintes de cours passent déjà par `Carnet.tint`, réglée
    /// pour le papier : les rôles d'accessibilité de l'iPhone (`Palette`) la
    /// gardent telle quelle.
    var accessibleInk: Color { self }
    var accessibleMark: Color { self }
}
#endif

// MARK: - Disposition en lignes

/// Range ses enfants de gauche à droite et passe à la ligne quand la largeur
/// manque — pour des pastilles dont le nombre varie.
struct FlowLayout: SwiftUI.Layout {
    var spacing: CGFloat = Layout.inline

    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: width == .infinity ? maxX : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
