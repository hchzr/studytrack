import SwiftUI

private struct DeskPanelHostKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// La vue est dans une fenêtre flottante à part (barre du haut, colonne d'outils).
    var deskPanelHost: Bool {
        get { self[DeskPanelHostKey.self] }
        set { self[DeskPanelHostKey.self] = newValue }
    }
}

/// Le fond d'une barre : du verre dans la fenêtre du bureau ; **plein** dans une fenêtre
/// flottante, où le verre prendrait la couleur de ce qui est derrière elle (le bureau
/// de l'utilisateur·rice, souvent clair) — une barre grise délavée sur un bureau sombre.
private struct DeskChrome: ViewModifier {
    @Environment(\.deskPanelHost) private var panel
    var edge: Edge

    func body(content: Content) -> some View {
        if panel {
            content
                .background(StudyPalette.ground)
                .overlay(alignment: edge == .bottom ? .bottom : .trailing) {
                    Rectangle().fill(Carnet.rule)
                        .frame(width: edge == .bottom ? nil : 1, height: edge == .bottom ? 1 : nil)
                }
        } else {
            content.deskGlass(in: Rectangle())
        }
    }
}

extension View {
    /// Le fond d'une barre du bureau ; `edge` : le bord où elle touche le contenu.
    func deskChrome(edge: Edge) -> some View { modifier(DeskChrome(edge: edge)) }

    /// Du verre pour ce qui flotte (barres, sélecteur, recherche, notifications) :
    /// le jumeau Mac de `carnetGlass` de l'iPhone. Liquid Glass sur macOS 26 et
    /// après ; avant, un matériau et un trait fin. Le papier reste pour ce qu'on lit.
    ///
    /// **Teinté du papier de nuit** : un verre clair posé sur un fond sombre faisait
    /// deux matières qui ne se parlent pas (le brun du fond d'écran contre le noir du
    /// contenu). Teinté, il garde son reflet et ses bords, et se fond dans le reste.
    @ViewBuilder
    func deskGlass<S: Shape>(in shape: S, interactive: Bool = false, tint: Color = StudyPalette.ground.opacity(0.62)) -> some View {
        if #available(macOS 26.0, *) {
            let glass: Glass = interactive ? .regular.tint(tint).interactive() : .regular.tint(tint)
            self.glassEffect(glass, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
                .background(tint, in: shape)
                .overlay(shape.stroke(Carnet.rule.opacity(0.7), lineWidth: 0.5))
        }
    }
}
