import SwiftUI
import UIKit

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

// MARK: - Formules

