import SwiftUI

/// « Avancé » : la dernière ligne d'une page de réglages. Repliée, elle dit en une ligne ce
/// qu'elle cache ; ouverte, les réglages rares apparaissent dessous (des `Section` ordinaires,
/// posées par la page après cette ligne : `if advanced.isOn { … }`). Rien n'est supprimé, rien
/// n'encombre — la même règle sur le Mac, l'iPhone et Windows. L'état est retenu par page.
struct AdvancedSettingsToggle: View {
    @Binding var isOn: Bool
    /// Ce qu'on trouve dedans (« Verrou système, écrans, gestes… »).
    let summary: LocalizedStringKey

    var body: some View {
        Section {
            Button {
                withAnimation(.snappy(duration: 0.25)) { isOn.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(Carnet.inkSecondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Avancé").foregroundStyle(Carnet.ink)
                        if !isOn {
                            Text(summary).font(.caption).foregroundStyle(Carnet.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Carnet.inkTertiary)
                        .rotationEffect(.degrees(isOn ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isOn ? Text("Affiché") : Text("Masqué"))
        }
    }
}
