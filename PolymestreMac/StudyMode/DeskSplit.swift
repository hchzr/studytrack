import AppKit
import SwiftData
import SwiftUI

// MARK: - À côté

/// Une vue calculée une seule fois tant que sa clé ne change pas : ce qu'elle
/// montre se met à jour par ses propres données (le modèle observé), pas à
/// chaque rendu du bureau autour d'elle.
struct Frozen<Content: View>: View, Equatable {
    let key: AnyHashable
    @ViewBuilder let content: () -> Content

    init(key: some Hashable, @ViewBuilder content: @escaping () -> Content) {
        self.key = AnyHashable(key)
        self.content = content
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }

    var body: some View { content() }
}

/// Le centre et le volet d'à côté. La largeur suit la souris pendant qu'on
/// tire la poignée (un état local : rien d'autre ne se recalcule), et n'est
/// gardée qu'au lâcher.
struct DeskSplit<Center: View, Side: View>: View {
    var desk: StudyDesk
    /// Le volet est une fenêtre à part : le centre prend toute la place.
    var sideHosted = false
    @ViewBuilder var center: Center
    @ViewBuilder var side: Side
    @State private var liveWidth: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let handle: CGFloat = desk.sideOpen && !sideHosted ? 9 : 0
            let maximum = max(StudyDesk.sideMinimum, geometry.size.width - StudyDesk.centerMinimum - 9)
            let width = min(max(StudyDesk.sideMinimum, liveWidth ?? desk.sideWidth), maximum)
            let centerWidth = max(0, geometry.size.width - handle - (desk.sideOpen && !sideHosted ? width : 0))
            // Des largeurs exactes : un outil qui ne veut pas rétrécir (la barre
            // de la série) ne pousse plus le volet hors de la fenêtre.
            HStack(spacing: 0) {
                // Un outil plus large que la place est coupé à droite, jamais
                // centré et coupé des deux côtés.
                center
                    .frame(width: centerWidth, height: geometry.size.height, alignment: .leading)
                    .clipped()
                    // La place des apps permises : leur fenêtre est posée ici.
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { StudyModeController.shared.publishHole($0) }
                if desk.sideOpen && !sideHosted {
                    SplitHandle(width: width, minimum: StudyDesk.sideMinimum, maximum: maximum,
                                change: { liveWidth = $0 },
                                end: { desk.sideWidth = $0; liveWidth = nil },
                                reset: { desk.sideWidth = 460 })
                        .frame(width: 9)
                        .overlay { Rectangle().fill(Carnet.rule).frame(width: 1).allowsHitTesting(false) }
                }
                // Toujours là, à sa largeur, simplement masqué quand le volet est
                // fermé : ses onglets restent tels quels (la page du PDF, le cahier).
                if !sideHosted {
                    side
                        .frame(width: width, height: geometry.size.height, alignment: .leading)
                        .frame(width: desk.sideOpen ? width : 0, alignment: .leading)
                        .clipped()
                        .opacity(desk.sideOpen ? 1 : 0)
                        .allowsHitTesting(desk.sideOpen)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
        }
    }
}

/// La poignée du volet, en AppKit : une vraie zone de 9 points, le curseur
/// de redimensionnement, le suivi natif de la souris. Double-clic : la largeur
/// d'origine.
struct SplitHandle: NSViewRepresentable {
    let width: CGFloat
    let minimum: CGFloat
    let maximum: CGFloat
    var change: (CGFloat) -> Void
    var end: (CGFloat) -> Void
    var reset: () -> Void

    func makeNSView(context: Context) -> HandleView { HandleView() }

    func updateNSView(_ view: HandleView, context: Context) {
        view.width = width
        view.minimum = minimum
        view.maximum = maximum
        view.change = change
        view.end = end
        view.reset = reset
    }

    final class HandleView: NSView {
        var width: CGFloat = 0
        var minimum: CGFloat = 0
        var maximum: CGFloat = 0
        var change: ((CGFloat) -> Void)?
        var end: ((CGFloat) -> Void)?
        var reset: (() -> Void)?
        private var startX: CGFloat?
        private var startWidth: CGFloat = 0
        private var last: CGFloat = 0

        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { reset?(); return }
            startX = event.locationInWindow.x
            startWidth = width
            last = width
        }

        override func mouseDragged(with event: NSEvent) {
            guard let startX else { return }
            NSCursor.resizeLeftRight.set()
            last = min(max(minimum, startWidth - (event.locationInWindow.x - startX)), maximum)
            change?(last)
        }

        override func mouseUp(with event: NSEvent) {
            guard startX != nil else { return }
            startX = nil
            end?(last)
        }
    }
}

/// La poignée du volet quand il est une fenêtre à part : la fenêtre bouge pendant qu'on
/// tire, alors la largeur se lit sur la **souris dans l'écran** (et non dans la fenêtre).
/// Double-clic : la largeur d'origine.
struct ScreenSplitHandle: NSViewRepresentable {
    var desk: StudyDesk

    func makeNSView(context: Context) -> HandleView { HandleView() }

    func updateNSView(_ view: HandleView, context: Context) { view.desk = desk }

    final class HandleView: NSView {
        weak var desk: StudyDesk?

        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { Task { @MainActor in self.desk?.sideWidth = 460 } }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let screen = window?.screen ?? NSScreen.screens.first else { return }
            let maximum = max(StudyDesk.sideMinimum, screen.frame.width - 76 - StudyDesk.centerMinimum)
            let width = min(max(StudyDesk.sideMinimum, screen.frame.maxX - NSEvent.mouseLocation.x), maximum)
            Task { @MainActor in self.desk?.sideWidth = width }
        }
    }
}
