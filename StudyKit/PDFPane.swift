import PDFKit
import SwiftUI

/// Un PDF natif (PDFKit), ouvert à l'exercice cherché — le même sur l'iPhone
/// et le Mac.
struct PDFPane {
    let url: URL
    var search: [String] = []

    fileprivate func make(_ coordinator: Coordinator) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        #if os(macOS)
        view.backgroundColor = NSColor(Carnet.ground)
        #else
        view.backgroundColor = UIColor(Carnet.ground)
        #endif
        view.document = PDFDocument(url: url)
        coordinator.url = url
        jump(view, coordinator: coordinator)
        return view
    }

    fileprivate func update(_ view: PDFView, _ coordinator: Coordinator) {
        if coordinator.url != url {
            view.document = PDFDocument(url: url)
            coordinator.url = url
            coordinator.searched = []
        }
        jump(view, coordinator: coordinator)
    }

    private func jump(_ view: PDFView, coordinator: Coordinator) {
        guard search != coordinator.searched, let document = view.document else { return }
        coordinator.searched = search
        for term in search {
            if let found = document.findString(term, withOptions: [.caseInsensitive]).first {
                view.go(to: found)
                view.setCurrentSelection(found, animate: true)
                return
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var url: URL?
        var searched: [String] = []
    }
}

#if os(macOS)
extension PDFPane: NSViewRepresentable {
    func makeNSView(context: Context) -> PDFView { make(context.coordinator) }
    func updateNSView(_ view: PDFView, context: Context) { update(view, context.coordinator) }
}
#else
extension PDFPane: UIViewRepresentable {
    func makeUIView(context: Context) -> PDFView { make(context.coordinator) }
    func updateUIView(_ view: PDFView, context: Context) { update(view, context.coordinator) }
}
#endif
