import SwiftUI

/// Les schémas du cours : un enchaînement, qui découle de quoi, un arbre de décision, une
/// comparaison. Dessinés par l'app d'après ce que Claude a écrit — toucher un nœud qui est une
/// notion de la fiche ouvre sa page.
struct DiagramsView: View {
    @Bindable var course: Course
    @Binding var concept: String?

    /// Le chapitre regardé (`nil` : tout le cours — ses schémas, puis ceux de chaque chapitre).
    var chapter: String?
    @State private var chosen: String?
    private var store: StudyMapStore { .shared }
    private var tint: Color { Carnet.tint(course.colorHex) }

    var body: some View {
        let map = store.map(course)
        // Les schémas du cours d'abord, puis ceux des chapitres, dans l'ordre de la fiche.
        let order = course.revisionSheet?.chapters.map(\.id) ?? []
        let shown = map.diagrams
            .filter { chapter == nil || $0.chapter == chapter }
            .sorted { (order.firstIndex(of: $0.chapter ?? "") ?? -1) < (order.firstIndex(of: $1.chapter ?? "") ?? -1) }
        if shown.isEmpty {
            empty
        } else {
            let current = shown.first { $0.id == chosen } ?? shown[0]
            VStack(spacing: 0) {
                picker(shown, current: current)
                Rectangle().fill(Carnet.rule).frame(height: 1)
                ScrollView([.vertical]) {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Kicker(chapter == nil ? [current.kind.label, course.revisionSheet?.chapter(current.chapter)?.title].compactMap { $0 }.joined(separator: " · ") : current.kind.label, color: tint)
                            Text(current.title).font(Carnet.serif(24)).foregroundStyle(Carnet.ink).fixedSize(horizontal: false, vertical: true)
                            if let summary = current.summary {
                                Text(summary).font(.callout).foregroundStyle(Carnet.inkSecondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        DiagramCanvas(diagram: current, course: course, map: map) { concept = $0 }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Carnet.ground)
            }
        }
    }

    private func picker(_ list: [Diagram], current: Diagram) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(list) { diagram in
                    Button { chosen = diagram.id } label: {
                        Label(diagram.title, systemImage: diagram.kind.icon)
                            .font(.callout.weight(diagram.id == current.id ? .semibold : .regular))
                            .lineLimit(1)
                            .padding(.horizontal, 12).frame(height: 32)
                            .foregroundStyle(diagram.id == current.id ? Carnet.ground : Carnet.ink)
                            .background(diagram.id == current.id ? Carnet.ink : Carnet.sheetRaised, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(Carnet.ground)
    }

    private var empty: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.largeTitle).foregroundStyle(Carnet.inkTertiary)
                Text(chapter == nil ? "Des schémas pour comprendre" : "Pas encore de schéma pour ce chapitre").font(Carnet.serif(24)).foregroundStyle(Carnet.ink)
                Text("Claude lit la fiche et dessine ce qui s'enchaîne, ce qui découle de quoi, quelle méthode choisir, ce qu'il ne faut pas confondre — pour tout le cours ou un chapitre à la fois.")
                    .font(.callout).foregroundStyle(Carnet.inkSecondary)
                ComprehendButton(course: course, chapter: chapter)
            }
            .padding(28)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Carnet.ground)
    }
}

/// Un schéma dessiné : nœuds et flèches (ou un tableau pour une comparaison).
struct DiagramCanvas: View {
    let diagram: Diagram
    let course: Course
    let map: StudyMap
    var open: (String) -> Void

    private let nodeSize = CGSize(width: 176, height: 56)
    private var tint: Color { Carnet.tint(course.colorHex) }

    var body: some View {
        if diagram.kind == .comparison {
            table
        } else {
            let layout = DiagramLayout.layered(diagram, nodeWidth: nodeSize.width, nodeHeight: nodeSize.height)
            ScrollView(.horizontal, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in draw(&context, layout) }
                        .frame(width: layout.width, height: layout.height)
                    ForEach(diagram.nodes) { node in
                        if let p = layout.positions[node.id] {
                            nodeView(node).position(x: p.x, y: p.y)
                        }
                    }
                }
                .frame(width: layout.width, height: layout.height)
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: Flèches

    private func draw(_ context: inout GraphicsContext, _ layout: DiagramLayout.Result) {
        for edge in diagram.edges {
            guard let a = layout.positions[edge.from], let b = layout.positions[edge.to] else { continue }
            let back = layout.backEdges.contains(edge)
            let start = CGPoint(x: a.x, y: a.y + nodeSize.height / 2)
            let end = CGPoint(x: b.x, y: b.y - nodeSize.height / 2)
            var path = Path()
            path.move(to: start)
            if back {
                // Retour : un détour sur le côté.
                let side = max(a.x, b.x) + nodeSize.width / 2 + 24
                path.addCurve(to: CGPoint(x: b.x + nodeSize.width / 2, y: b.y),
                              control1: CGPoint(x: side, y: start.y + 30), control2: CGPoint(x: side, y: b.y))
            } else {
                let dy = (end.y - start.y) / 2
                path.addCurve(to: end, control1: CGPoint(x: start.x, y: start.y + dy), control2: CGPoint(x: end.x, y: end.y - dy))
            }
            context.stroke(path, with: .color(Carnet.inkSecondary.opacity(0.8)), style: StrokeStyle(lineWidth: 1.6, dash: back ? [5, 4] : []))
            if !back {
                var head = Path()
                head.move(to: end)
                head.addLine(to: CGPoint(x: end.x - 5, y: end.y - 9))
                head.move(to: end)
                head.addLine(to: CGPoint(x: end.x + 5, y: end.y - 9))
                context.stroke(head, with: .color(Carnet.inkSecondary), lineWidth: 1.6)
            }
            if let label = edge.label {
                let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                context.draw(Text(label).font(.caption2.weight(.semibold)).foregroundColor(Carnet.inkSecondary), at: CGPoint(x: mid.x + 14, y: mid.y))
            }
        }
    }

    // MARK: Nœuds

    private func nodeView(_ node: Diagram.Node) -> some View {
        let level = node.entry.map { map.mastery($0) }
        return Button {
            if let entry = node.entry { open(entry) }
        } label: {
            VStack(spacing: 2) {
                HStack(spacing: 5) {
                    if let level { MasteryDot(level: level, size: 10) }
                    MacMathText(node.label, size: 12).foregroundStyle(Carnet.ink).lineLimit(2).multilineTextAlignment(.center)
                }
                if let detail = node.detail {
                    Text(detail).font(.caption2).foregroundStyle(Carnet.inkSecondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .frame(width: nodeSize.width, height: nodeSize.height)
            .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(node.entry == nil ? Carnet.rule : tint.opacity(0.7), lineWidth: node.entry == nil ? 1 : 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .help(node.entry == nil ? "" : "Ouvrir la notion")
    }

    // MARK: Comparaison

    private var table: some View {
        let columns = diagram.columns ?? []
        let rows = diagram.rows ?? []
        return ScrollView(.horizontal, showsIndicators: false) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    cell("", header: true)
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, name in cell(name, header: true) }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, value in cell(value, header: column == 0, shaded: index % 2 == 1) }
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Carnet.rule))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func cell(_ text: String, header: Bool, shaded: Bool = false) -> some View {
        MacMathText(text, size: 13)
            .fontWeight(header ? .semibold : .regular)
            .foregroundStyle(Carnet.ink)
            .multilineTextAlignment(.leading)
            .padding(10)
            .frame(width: 190, alignment: .leading)
            .frame(minHeight: 40, alignment: .topLeading)
            .background(header ? Carnet.sheetRaised : (shaded ? Carnet.sheet.opacity(0.6) : Carnet.sheet))
            .overlay(Rectangle().strokeBorder(Carnet.rule.opacity(0.6), lineWidth: 0.5))
    }
}

// MARK: - Faire écrire par Claude

/// « Comprendre avec Claude » : les liens, les phrases en clair, les schémas, les questions.
struct ComprehendButton: View {
    let course: Course
    var chapter: String?
    private var store: StudyMapStore { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if course.revisionSheet == nil {
                Label("Fais d'abord la fiche du cours.", systemImage: "doc.text").font(.callout).foregroundStyle(Carnet.inkSecondary)
            } else if store.canEnrich {
                Button { Task { await store.enrich(course, chapter: chapter) } } label: {
                    Label(StudyMapStore.enrichLabel(store.map(course), chapter: chapter), systemImage: "sparkles")
                }
                .buttonStyle(.ink)
                .disabled(isWorking)
            } else {
                Label("Claude relie les notions sur le Mac ; ça arrive ici par iCloud.", systemImage: "desktopcomputer")
                    .font(.callout).foregroundStyle(Carnet.inkSecondary)
            }
            if let state = store.state(course, chapter: chapter) {
                switch state {
                case .working(let message):
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(message).font(.callout).foregroundStyle(Carnet.inkSecondary) }
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(Carnet.wrong).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var isWorking: Bool {
        if case .working? = store.state(course, chapter: chapter) { return true }
        return false
    }
}
