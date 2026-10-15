import SwiftUI

/// Une ligne de la palette de commandes : la même pour ⌘K (la fenêtre principale) et
/// pour la recherche d'étude (⌘Espace pendant un blocage).
struct PaletteItem: Identifiable {
    var id: String
    var title: String
    var subtitle: String = ""
    var icon: String
    var tint: Color = Carnet.inkSecondary
    var section: String
    var shortcut: String?
    var run: () -> Void
    /// ⌘↩ : chronométrer cet élément.
    var time: (() -> Void)?
}

/// Comment la ligne choisie se détache : en encre pleine (⌘K, sur papier) ou en
/// voile clair (la recherche d'étude, sur verre).
enum PaletteStyle { case inverted, glass }

struct PaletteRow: View {
    let item: PaletteItem
    let selected: Bool
    var style: PaletteStyle = .inverted

    private var inverted: Bool { selected && style == .inverted }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .foregroundStyle(inverted ? Carnet.ground : item.tint)
                .frame(width: 22)
            Text(item.title).lineLimit(1)
            if !item.subtitle.isEmpty {
                Text(item.subtitle)
                    .foregroundStyle(inverted ? Carnet.ground.opacity(0.75) : Carnet.inkSecondary)
                    .lineLimit(1)
            }
            Spacer()
            if let shortcut = item.shortcut {
                Text(shortcut).font(.callout)
                    .foregroundStyle(inverted ? Carnet.ground.opacity(0.75) : Carnet.inkTertiary)
            }
        }
        .foregroundStyle(inverted ? Carnet.ground : Carnet.ink)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
    }

    private var background: Color {
        guard selected else { return .clear }
        return style == .inverted ? Carnet.ink : Carnet.ink.opacity(0.16)
    }
}

/// Les sections d'une liste de résultats : un titre quand la section change.
struct PaletteSectionTitle: View {
    let title: String
    var first: Bool

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Carnet.inkTertiary)
            .padding(.horizontal, 12)
            .padding(.top, first ? 6 : 10)
            .padding(.bottom, 3)
    }
}
