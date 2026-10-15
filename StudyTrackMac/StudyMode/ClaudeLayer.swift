import AppKit
import SwiftData
import SwiftUI

// MARK: - Claude flottant

/// Claude par-dessus le bureau : on le déplace par sa poignée, on le
/// redimensionne par ses coins bas ; il garde sa place d'une session à l'autre.
/// Pendant le geste, la place est un état local (rien d'autre ne se
/// recalcule) ; elle n'est gardée qu'au lâcher.
struct ClaudeLayer<Content: View>: View {
    var desk: StudyDesk
    @ViewBuilder var content: Content
    @State private var live: CGRect?
    @State private var gestureStart: CGRect?

    private static var minimum: CGSize { CGSize(width: 360, height: 380) }

    var body: some View {
        if desk.claudePlacement == .floating, desk.claudeOpened {
            GeometryReader { geometry in
                card(clamp(live ?? desk.claudeFrame, in: geometry.size))
            }
        }
    }

    /// Sa place, ramenée dans le bureau si la fenêtre a rétréci.
    private func clamp(_ stored: CGRect?, in bounds: CGSize) -> CGRect {
        let height = min(640, bounds.height - 40)
        var rect = stored ?? CGRect(x: bounds.width - 440 - 20, y: bounds.height - height - 20, width: 440, height: height)
        rect.size.width = min(max(rect.width, Self.minimum.width), max(Self.minimum.width, bounds.width - 16))
        rect.size.height = min(max(rect.height, Self.minimum.height), max(Self.minimum.height, bounds.height - 16))
        rect.origin.x = min(max(rect.minX, 8), max(8, bounds.width - rect.width - 8))
        rect.origin.y = min(max(rect.minY, 8), max(8, bounds.height - rect.height - 8))
        return rect
    }

    private func card(_ rect: CGRect) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return VStack(spacing: 0) {
            grabber(rect)
            content
        }
        .frame(width: rect.width, height: rect.height)
        .clipShape(shape)
        // Du papier sous la conversation, sans ombre : le trait fin suffit à la détacher.
        .background(shape.fill(Carnet.ground))
        .overlay(shape.strokeBorder(StudyPalette.rule).allowsHitTesting(false))
        .overlay(alignment: .bottomLeading) { corner(rect, leading: true) }
        .overlay(alignment: .bottomTrailing) { corner(rect, leading: false) }
        .scaleEffect(desk.claudeShown ? 1 : 0.96, anchor: .bottomTrailing)
        .opacity(desk.claudeShown ? 1 : 0)
        .animation(.easeOut(duration: 0.16), value: desk.claudeShown)
        .offset(x: rect.minX, y: rect.minY)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(desk.claudeShown)
        .accessibilityHidden(!desk.claudeShown)
    }

    private func commit() {
        if let live { desk.claudeFrame = live }
        live = nil
        gestureStart = nil
    }

    /// La poignée : glisser pour déplacer.
    private func grabber(_ rect: CGRect) -> some View {
        Capsule()
            .fill(StudyPalette.inkTertiary.opacity(0.7))
            .frame(width: 40, height: 4)
            .frame(maxWidth: .infinity)
            .frame(height: 16)
            .deskGlass(in: Rectangle())
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = gestureStart ?? rect
                    if gestureStart == nil { gestureStart = rect }
                    live = start.offsetBy(dx: value.translation.width, dy: value.translation.height)
                }
                .onEnded { _ in commit() })
            .help("Glisser pour déplacer Claude")
    }

    /// Un coin bas : glisser pour redimensionner.
    private func corner(_ rect: CGRect, leading: Bool) -> some View {
        Color.clear
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = gestureStart ?? rect
                    if gestureStart == nil { gestureStart = rect }
                    let dx = value.translation.width, dy = value.translation.height
                    var next = start
                    next.size.height = max(Self.minimum.height, start.height + dy)
                    if leading {
                        let width = max(Self.minimum.width, start.width - dx)
                        next.origin.x = start.maxX - width
                        next.size.width = width
                    } else {
                        next.size.width = max(Self.minimum.width, start.width + dx)
                    }
                    live = next
                }
                .onEnded { _ in commit() })
            .help("Glisser pour redimensionner")
    }
}
