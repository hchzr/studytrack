import SwiftUI

/// La grille du bureau : des colonnes égales qui remplissent la place, chaque carte
/// sur une, deux ou trois colonnes, posée dans la colonne (ou les colonnes) la plus
/// basse — alignée, au lieu de flotter. Le nombre de colonnes vient de
/// `DeskWidgets.columnCount`.
struct DeskWidgetGrid: SwiftUI.Layout {
    struct SpanKey: LayoutValueKey {
        static let defaultValue = 1
    }

    private func frames(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        let gap = CGFloat(DeskWidgets.gap)
        let columns = DeskWidgets.columnCount(available: Double(width))
        let column = (width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        var heights = Array(repeating: CGFloat(0), count: columns)
        var result: [CGRect] = []
        for subview in subviews {
            let span = min(max(subview[SpanKey.self], 1), columns)
            let cardWidth = column * CGFloat(span) + gap * CGFloat(span - 1)
            let cardHeight = subview.sizeThatFits(ProposedViewSize(width: cardWidth, height: nil)).height
            // Les colonnes voisines les plus basses qui accueillent la carte.
            var best = 0
            var bestTop = CGFloat.greatestFiniteMagnitude
            for start in 0...(columns - span) {
                let top = heights[start..<(start + span)].max() ?? 0
                if top < bestTop { bestTop = top; best = start }
            }
            result.append(CGRect(x: CGFloat(best) * (column + gap), y: bestTop, width: cardWidth, height: cardHeight))
            for index in best..<(best + span) { heights[index] = bestTop + cardHeight + gap }
        }
        return (result, max(0, (heights.max() ?? gap) - gap))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 900
        return CGSize(width: width, height: frames(subviews, width: width).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let laid = frames(subviews, width: bounds.width)
        for (subview, frame) in zip(subviews, laid.frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}
