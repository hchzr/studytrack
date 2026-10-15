import SwiftUI

extension View {
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
