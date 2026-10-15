import SwiftUI

extension View {
    /// Du verre pour ce qui flotte (barres, sélecteur, recherche, notifications) :
    /// le jumeau Mac de `carnetGlass` de l'iPhone. Liquid Glass sur macOS 26 et
    /// après ; avant, un matériau et un trait fin. Le papier reste pour ce qu'on lit.
    @ViewBuilder
    func deskGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Carnet.rule.opacity(0.7), lineWidth: 0.5))
        }
    }
}
