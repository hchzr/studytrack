import PDFKit
import SwiftUI

/// Un PDF natif (PDFKit), ouvert à l'exercice cherché — le même sur l'iPhone
/// et le Mac.
struct PDFPane {
    let url: URL
    var search: [String] = []
    /// L'adresse du document : on y garde la page, et la dernière page atteinte
    /// le coche (`markStudied`). `nil` : rien de gardé (un extrait, une copie).
    var memory: String? = nil
    var markStudied: ((String) -> Void)? = nil
    /// Un exercice à montrer : ouvert à sa place, sa zone surlignée.
    var highlight: PDFExerciseCrop.Region? = nil

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
        coordinator.memory = memory
        coordinator.markStudied = markStudied
        coordinator.observe(view)
        if search.isEmpty, highlight == nil, let memory, let saved = ReadingMemory.page(memory), let page = view.document?.page(at: saved.page) {
            view.go(to: page)
        }
        jump(view, coordinator: coordinator)
        mark(view, coordinator: coordinator)
        return view
    }

    /// La zone de l'exercice, teintée, et la vue qui s'y rend.
    private func mark(_ view: PDFView, coordinator: Coordinator) {
        guard let document = view.document else { return }
        let key = highlight.map { $0.parts.map { "\($0.page):\(Int($0.rect.minY))" }.joined(separator: ",") } ?? ""
        guard key != coordinator.marked else { return }
        coordinator.marked = key
        for (page, annotation) in coordinator.annotations { page.removeAnnotation(annotation) }
        coordinator.annotations = []
        guard let highlight else { return }
        #if os(macOS)
        let fill = NSColor(Carnet.review).withAlphaComponent(0.10)
        let edge = NSColor(Carnet.review).withAlphaComponent(0.55)
        #else
        let fill = UIColor(Carnet.review).withAlphaComponent(0.10)
        let edge = UIColor(Carnet.review).withAlphaComponent(0.55)
        #endif
        for part in highlight.parts {
            guard let page = document.page(at: part.page) else { continue }
            let rect = part.rect.insetBy(dx: 18, dy: -2)
            let box = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
            box.color = edge
            box.interiorColor = fill
            let border = PDFBorder()
            border.lineWidth = 1.5
            box.border = border
            page.addAnnotation(box)
            coordinator.annotations.append((page, box))
        }
        if let first = highlight.parts.first, let page = document.page(at: first.page) {
            // Le haut de l'exercice en haut de l'écran.
            let top = CGRect(x: first.rect.minX, y: first.rect.maxY - 1, width: first.rect.width, height: 1)
            DispatchQueue.main.async { view.go(to: top, on: page) }
        }
    }

    fileprivate func update(_ view: PDFView, _ coordinator: Coordinator) {
        if coordinator.url != url {
            view.document = PDFDocument(url: url)
            coordinator.url = url
            coordinator.searched = []
            coordinator.marked = ""
            coordinator.annotations = []
        }
        jump(view, coordinator: coordinator)
        mark(view, coordinator: coordinator)
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

    final class Coordinator: NSObject {
        var url: URL?
        var searched: [String] = []
        var memory: String?
        var markStudied: ((String) -> Void)?
        var marked = ""
        var annotations: [(PDFPage, PDFAnnotation)] = []
        private var counted = false

        func observe(_ view: PDFView) {
            NotificationCenter.default.addObserver(self, selector: #selector(pageChanged(_:)), name: .PDFViewPageChanged, object: view)
        }

        @objc private func pageChanged(_ note: Notification) {
            guard let view = note.object as? PDFView, let document = view.document, let page = view.currentPage,
                  let memory else { return }
            let index = document.index(for: page)
            ReadingMemory.setPage(memory, page: index, count: document.pageCount)
            // La dernière page à l'écran : le document est parcouru.
            if index >= document.pageCount - 1, document.pageCount > 1, !counted {
                counted = true
                let action = markStudied
                Task { @MainActor in action?(memory) }
            }
        }

        deinit { NotificationCenter.default.removeObserver(self) }
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
