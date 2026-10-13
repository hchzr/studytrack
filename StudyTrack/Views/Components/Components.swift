import SwiftUI
import UIKit

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
        UIAccessibility.isReduceMotionEnabled ? .easeInOut(duration: 0.2) : nil
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

// MARK: - Retour haptique

/// Les générateurs sont **réutilisés** et réarmés après chaque coup.
///
/// En créer un à chaque appel obligeait le moteur à se réveiller à froid : la
/// vibration arrivait une cinquantaine de millisecondes après le toucher, ce qui
/// se sent sur des coches en rafale. `prepare()` le garde chaud pour le suivant.
@MainActor
enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let softImpact = UIImpactFeedbackGenerator(style: .soft)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let notification = UINotificationFeedbackGenerator()

    static func tap() { light.impactOccurred(); light.prepare() }
    static func soft() { softImpact.impactOccurred(); softImpact.prepare() }
    /// Une suppression **déjà confirmée** : un clac net, pas une alerte.
    /// `warning()` reste réservé à ce qui n'a pas marché.
    static func removed() { rigid.impactOccurred(); rigid.prepare() }
    static func success() { notification.notificationOccurred(.success); notification.prepare() }
    static func warning() { notification.notificationOccurred(.warning); notification.prepare() }
    static func error() { notification.notificationOccurred(.error); notification.prepare() }
}

// MARK: - Progression

/// Anneau de progression avec pourcentage au centre.
struct ProgressRing: View {
    var progress: Double
    var color: Color = Theme.accent
    var size: CGFloat = 56
    var lineWidth: CGFloat = 6
    var showsLabel: Bool = true

    /// L'anneau et son libellé suivent la taille de texte du lecteur.
    @ScaledMetric(relativeTo: .caption) private var scale: CGFloat = 1

    private var clamped: Double { min(1, max(0, progress)) }

    var body: some View {
        ZStack {
            Circle().stroke(color.badgeFill, lineWidth: lineWidth * scale)
            Circle()
                .trim(from: 0, to: max(0.001, clamped))
                .stroke(color.accessibleMark,
                        style: StrokeStyle(lineWidth: lineWidth * scale, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if showsLabel {
                Text("\(Int((clamped * 100).rounded()))%")
                    .font(.system(size: size * scale * 0.27, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: clamped))
            }
        }
        .animation(Motion.progress, value: clamped)
        .frame(width: size * scale, height: size * scale)
        .accessibilityElement()
        .accessibilityLabel("Progression")
        .accessibilityValue("\(Int((clamped * 100).rounded())) pour cent")
    }
}

/// Barre de progression linéaire.
struct ProgressBar: View {
    var progress: Double
    var color: Color = Theme.accent
    var height: CGFloat = 8

    private var clamped: Double { min(1, max(0, progress)) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(color.badgeFill)
                Capsule().fill(color.accessibleMark).frame(width: max(0, clamped * geo.size.width))
            }
        }
        .frame(height: height)
        .animation(Motion.progress, value: clamped)
    }
}

/// Ligne « libellé · valeur · barre » — un seul axe par ligne, lisible.
struct LabeledProgress: View {
    var title: String
    var progress: Double
    var color: Color = Theme.accent
    var countLabel: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.tight) {
            HStack(spacing: 8) {
                // Une ligne, toujours : un titre qui passait à la ligne à côté
                // d'un compte long décalait la barre et tout ce qui suit.
                Text(ui: title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: Layout.inline)
                if let countLabel {
                    Text(countLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Text("\(Int((min(1, max(0, progress)) * 100).rounded()))%")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: progress))
            }
            .animation(Motion.progress, value: progress)
            ProgressBar(progress: progress, color: color)
        }
    }
}

/// Les trois axes d'un cours, empilés verticalement (jamais serrés sur une ligne).
struct ProgressStack: View {
    var progress: CourseProgress
    var showsCounts: Bool = true

    var body: some View {
        VStack(spacing: 12) {
            LabeledProgress(title: "Théorie",
                            progress: progress.theoryPercent,
                            color: TaskType.video.tint,
                            countLabel: showsCounts ? "\(progress.watchedCount)/\(progress.videoCount) vidéos" : nil)
            LabeledProgress(title: "Exercices",
                            progress: progress.exercisePercent,
                            color: TaskType.exercise.tint,
                            countLabel: showsCounts ? "\(progress.doneCount)/\(progress.exerciseCount) faits" : nil)
            LabeledProgress(title: "Corrections",
                            progress: progress.correctionPercent,
                            color: TaskType.correction.tint,
                            countLabel: showsCounts ? "\(progress.correctedCount)/\(progress.doneCount) corrigés" : nil)
        }
    }
}

// MARK: - Contrôles

/// Coche tactile de 44 pt.
struct CheckCircleButton: View {
    var isOn: Bool
    var tint: Color = .green
    var label: String
    var action: () -> Void

    /// La cible reste à 44 pt ; seul le glyphe suit la taille de texte.
    @ScaledMetric(relativeTo: .title3) private var glyphSize: CGFloat = 25

    var body: some View {
        Button {
            // La coche est **seule** à vibrer : les gestionnaires n'ajoutent rien.
            // Un tic net pour cocher, plus doux pour décocher.
            if isOn { Haptics.soft() } else { Haptics.tap() }
            action()
        } label: {
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .font(.system(size: glyphSize))
                .foregroundStyle(isOn ? tint.accessibleMark : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: Layout.minTouch, height: Layout.minTouch)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "fait" : "à faire")
    }
}

/// Sélecteur de sureté **visible** (vert / orange / rouge).
///
/// Le code couleur est l'information centrale du suivi d'exercices : il ne doit
/// pas être caché derrière un menu. La teinte **ne porte jamais le sens seule** —
/// la pastille sélectionnée porte aussi un glyphe (✓ / = / ?), parce que
/// vert-orange-rouge est exactement la triade que le daltonisme rouge-vert
/// confond. Les remplissages sont résolus pour rester lisibles sur la carte.
struct ConfidenceControl: View {
    var value: ConfidenceLevel?
    var isEnabled: Bool = true
    var onChange: (ConfidenceLevel?) -> Void

    var body: some View {
        HStack(spacing: Layout.tight) {
            ForEach(ConfidenceLevel.allCases) { level in
                let isOn = value == level
                Button {
                    Haptics.soft()
                    onChange(isOn ? nil : level)
                } label: {
                    ZStack {
                        Circle()
                            .fill(isOn ? level.color.verdictFill : level.color.badgeFill)
                        if isOn {
                            Image(systemName: level.glyph)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Theme.knockedOutInk)
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                        } else {
                            Circle()
                                .stroke(level.color.accessibleMark, lineWidth: 1.5)
                        }
                    }
                    .frame(width: 26, height: 26)
                    .frame(width: Layout.minTouch, height: Layout.minTouch)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .accessibilityLabel("Sureté \(level.label)")
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
            }
        }
        .animation(.snappy(duration: 0.2), value: value)
        .opacity(isEnabled ? 1 : 0.35)
    }
}

// MARK: - Cartes & lignes

/// Conteneur de section avec titre optionnel.
struct Card<Content: View>: View {
    let title: String?
    let icon: String?
    let trailing: String?
    let content: Content

    init(title: String? = nil,
         icon: String? = nil,
         trailing: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                HStack(spacing: 8) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.subheadline)
                            .foregroundStyle(Theme.accentInk)
                    }
                    Text(ui: title).font(.headline)
                    Spacer()
                    if let trailing {
                        Text(trailing)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.softBackground, in: RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
    }
}

/// Carte d'action principale : une seule chose à faire, un seul bouton.
struct ActionCard: View {
    var icon: String
    var title: String
    var subtitle: String
    var actionTitle: String
    var tint: Color = Theme.accent
    /// Un sur-titre (« Maintenant ») : il dit **pourquoi** cette carte est là.
    var eyebrow: String? = nil
    var actionIcon: String = "play.fill"
    var action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let eyebrow {
                Text(eyebrow.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    // Neutre : c'est l'icône qui porte le verdict. Un sur-titre
                    // rouge criait « alerte » au-dessus d'un simple exercice.
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(tint.badgeFill).frame(width: 46, height: 46)
                    Image(systemName: icon).font(.title3).foregroundStyle(tint.badgeInk)
                }
                VStack(alignment: .leading, spacing: Layout.tight) {
                    Text(title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Button {
                Haptics.tap()
                action()
            } label: {
                Label(actionTitle, systemImage: actionIcon)
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.carnetPrimary)
            .buttonBorderShape(.roundedRectangle(radius: 12))
            // Le bouton est une **action** : toujours l'encre de l'app. La teinte
            // de l'icône porte le verdict (à refaire, à jour) ; un grand bouton
            // rouge criait « danger » là où il fallait lire « démarrer ».
            .tint(Theme.accent)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.softBackground, in: RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
    }
}

/// État vide avec une seule action évidente.
struct EmptyCard: View {
    var icon: String
    var title: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle) {
                    Haptics.tap()
                    action()
                }
                .buttonStyle(.carnetPrimary)
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Theme.softBackground, in: RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
    }
}

/// Tuile de statistique lisible.
struct StatCard: View {
    var icon: String
    var value: String
    var title: String
    var tint: Color = Theme.accent
    /// Posée **dans** une carte : un fond de la couleur de la carte y
    /// disparaîtrait, la tuile prend donc un fond de remplissage.
    var onCard: Bool = false

    var body: some View {
        // Icône dans une case de hauteur fixe : des glyphes de hauteurs
        // différentes décalaient les valeurs d'une tuile à l'autre.
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint.accessibleMark)
                .frame(height: 20, alignment: .leading)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(12)
        .background(onCard ? Color(.tertiarySystemFill) : Theme.softBackground,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Ligne « icône · libellé · valeur » pour les feuilles de détail.
struct DetailRow: View {
    var icon: String
    var label: String
    var value: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(tint.accessibleMark)
                .frame(width: 22)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.trailing)
        }
    }
}

/// Petite étiquette colorée.
///
/// Le fond est **explicite** (la teinte composée sur la surface de carte, sans
/// chaîne d'alpha dont le contraste dépendrait du contexte) et l'encre est
/// **résolue** pour atteindre 4.5:1 sur ce fond précis, dans les deux
/// apparences. La teinte signale ; le texte nomme.
struct Pill: View {
    var text: String
    var color: Color = .secondary
    var icon: String? = nil

    var body: some View {
        HStack(spacing: Layout.tight) {
            if let icon {
                Image(systemName: icon).font(.caption2.weight(.bold))
            }
            Text(text).font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.badgeFill, in: Capsule())
        .foregroundStyle(color.badgeInk)
    }
}

/// Pastille de confiance.
struct ConfidenceDot: View {
    var level: ConfidenceLevel?

    var body: some View {
        Circle()
            .fill(level?.color.accessibleMark ?? Color.secondary.opacity(0.22))
            .frame(width: 10, height: 10)
    }
}

/// Ligne « icône + texte » compacte.
struct IconLabel: View {
    var icon: String
    var text: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: Layout.tight) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(.caption)
        }
        .foregroundStyle(tint.accessibleInk)
    }
}

/// En-tête de section de liste.
struct SectionHeader: View {
    var title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(ui: title)
                .font(.headline)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 2)
    }
}

/// Choix unique sous forme de grandes cartes (onboarding, réglages).
struct ChoiceCard: View {
    /// Facultative : une liste de 28 sections avec 28 fois la même toque
    /// n'apprend rien, le titre suffit.
    var icon: String?
    var title: String
    var subtitle: String
    var isSelected: Bool
    var tint: Color = Theme.accent
    var action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 14) {
                if let icon {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(isSelected ? tint.badgeInk : tint.accessibleMark)
                        .frame(width: 42, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? tint.badgeInk : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? tint.badgeFill : Theme.softBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? tint.accessibleMark.opacity(0.55) : Color.clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.98))
    }
}


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

// MARK: - Formules

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
