import SwiftUI

/// La carte mentale du cours : la racine au milieu, les chapitres autour, les notions au bout ;
/// par-dessus, les liens qui disent ce qui dépend de quoi. Dessinée d'après la fiche (rien à
/// construire à la main), et à soi : on déplace, on replie, on ajoute ses idées, on relie deux
/// notions. Le point de chaque notion dit où l'on en est.
struct MindMapView: View {
    @Bindable var course: Course
    /// La notion dont on ouvre la page (le conteneur la montre).
    @Binding var concept: String?

    @State private var zoom: CGFloat = 0.85
    @State private var selected: String?
    @State private var dragging: (id: String, delta: CGSize)?
    @State private var linkFrom: String?
    @State private var pending: (from: String, to: String)?
    @State private var ideaParent: String?
    @State private var ideaTitle = ""
    @State private var renaming: String?
    @State private var viewport: CGSize = .zero
    @State private var fitted = false
    /// On a réglé le zoom soi-même : la vue ne le refait plus quand la place change.
    @State private var userZoomed = false

    private var store: StudyMapStore { .shared }
    private var tint: Color { Carnet.tint(course.colorHex) }

    // MARK: La carte, calculée

    private struct Model {
        var nodes: [MindNode]
        var positions: [String: StudyMap.Point]
        var children: [String: [String]]
        var minX: Double, minY: Double, width: Double, height: Double
    }

    private let margin = 50.0

    private func size(of node: MindNode) -> CGSize {
        switch node.role {
        case .root: return CGSize(width: 170, height: 48)
        case .chapter: return CGSize(width: 206, height: 40)
        case .entry: return CGSize(width: 200, height: 38)
        case .custom: return CGSize(width: 170, height: 34)
        }
    }

    private func model(sheet: RevisionSheet, map: StudyMap) -> Model {
        let all = MindGraph.nodes(sheet: sheet, map: map, courseTitle: course.name)
        let nodes = MindGraph.visible(all, collapsed: map.collapsed)
        var positions = MindLayout.twoSided(nodes)
        for (id, point) in map.layout where positions[id] != nil { positions[id] = point }
        var children: [String: [String]] = [:]
        for node in nodes { if let parent = node.parent { children[parent, default: []].append(node.id) } }
        let bounds = MindLayout.bounds(positions) ?? (0, 0, 0, 0)
        return Model(nodes: nodes, positions: positions, children: children,
                     minX: bounds.minX - margin - 100, minY: bounds.minY - margin,
                     width: bounds.maxX - bounds.minX + 2 * margin + 200, height: bounds.maxY - bounds.minY + 2 * margin)
    }

    private func descendants(of id: String, _ children: [String: [String]]) -> [String] {
        (children[id] ?? []).flatMap { [$0] + descendants(of: $0, children) }
    }

    /// Le point d'un nœud sur la toile (avec ce qu'on est en train de déplacer).
    private func point(_ id: String, _ model: Model) -> CGPoint {
        var p = model.positions[id] ?? StudyMap.Point(x: 0, y: 0)
        if let dragging, dragging.id == id || descendants(of: dragging.id, model.children).contains(id) {
            p.x += Double(dragging.delta.width / zoom)
            p.y += Double(dragging.delta.height / zoom)
        }
        return CGPoint(x: p.x - model.minX, y: p.y - model.minY)
    }

    // MARK: Corps

    var body: some View {
        if let sheet = course.revisionSheet, !sheet.isEmpty {
            let map = store.map(course)
            let model = model(sheet: sheet, map: map)
            GeometryReader { proxy in
                ScrollViewReader { scroller in
                    ScrollView([.horizontal, .vertical]) {
                        canvas(model, sheet: sheet, map: map)
                            .frame(width: model.width, height: model.height)
                            .scaleEffect(zoom, anchor: .topLeading)
                            .frame(width: model.width * zoom, height: model.height * zoom, alignment: .topLeading)
                            // Une carte plus petite que la place se centre au lieu de se coller en haut à gauche.
                            .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
                    }
                    .scrollIndicators(.hidden)
                    .background(Carnet.ground)
                    .gesture(MagnifyGesture().onChanged {
                        userZoomed = true
                        zoom = min(2, max(0.25, zoom * $0.magnification / lastMagnification)); lastMagnification = $0.magnification
                    }.onEnded { _ in lastMagnification = 1 })
                    .onAppear {
                        viewport = proxy.size
                        if !fitted { fit(model, size: proxy.size); fitted = true }
                        centre(scroller, model: model, size: proxy.size, zoom: userZoomed ? zoom : fitZoom(model, proxy.size))
                    }
                    // La place change (la page d'une notion s'ouvre à côté) : on réajuste, sauf zoom choisi.
                    .onChange(of: proxy.size) { _, new in
                        viewport = new
                        if !userZoomed { fit(model, size: new) }
                        centre(scroller, model: model, size: new, zoom: userZoomed ? zoom : fitZoom(model, new))
                    }
                }
                .overlay(alignment: .top) { toolbar(model, map: map) }
                .overlay(alignment: .bottomLeading) { legend.padding(12) }
            }
            .alert("Nouvelle idée", isPresented: Binding(get: { ideaParent != nil }, set: { if !$0 { ideaParent = nil } })) {
                TextField("Une idée, une question, un exemple…", text: $ideaTitle)
                Button("Ajouter") { addIdea(map: map) }
                Button("Annuler", role: .cancel) { ideaTitle = "" }
            }
            .alert("Renommer", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Titre", text: $ideaTitle)
                Button("Renommer") { rename() }
                Button("Annuler", role: .cancel) { ideaTitle = "" }
            }
            .confirmationDialog(linkQuestion(sheet), isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
                ForEach(StudyMap.Relation.allCases) { relation in
                    Button(relation.label) { confirmLink(relation) }
                }
            }
        } else {
            ContentUnavailableView("Pas encore de fiche", systemImage: "point.3.connected.trianglepath.dotted",
                                   description: Text("La carte se dessine d'après la fiche du cours."))
        }
    }

    @State private var lastMagnification: CGFloat = 1

    private func linkQuestion(_ sheet: RevisionSheet) -> String {
        guard let pending else { return "" }
        return "\(sheet.entry(forKey: pending.from)?.entry.title ?? "") …"
    }

    // MARK: La toile

    private func canvas(_ model: Model, sheet: RevisionSheet, map: StudyMap) -> some View {
        ZStack(alignment: .topLeading) {
            // Le centre de la carte (la racine), où la vue se place.
            Color.clear.frame(width: 1, height: 1).position(point(MindGraph.rootID, model)).id("mind-root")
            Canvas { context, _ in
                drawTree(&context, model)
                drawLinks(&context, model, map: map)
            }
            .frame(width: model.width, height: model.height)
            .contentShape(Rectangle())
            .onTapGesture { selected = nil; linkFrom = nil }
            ForEach(model.nodes) { node in
                nodeView(node, model: model, sheet: sheet, map: map)
                    .position(point(node.id, model))
            }
        }
    }

    private func anchors(parent: MindNode, child: MindNode, _ model: Model) -> (CGPoint, CGPoint) {
        let a = point(parent.id, model), b = point(child.id, model)
        let wa = size(of: parent).width / 2, wb = size(of: child).width / 2
        return b.x >= a.x ? (CGPoint(x: a.x + wa, y: a.y), CGPoint(x: b.x - wb, y: b.y))
                          : (CGPoint(x: a.x - wa, y: a.y), CGPoint(x: b.x + wb, y: b.y))
    }

    private func drawTree(_ context: inout GraphicsContext, _ model: Model) {
        let byID = Dictionary(model.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for node in model.nodes {
            guard let parentID = node.parent, let parent = byID[parentID] else { continue }
            let (start, end) = anchors(parent: parent, child: node, model)
            var path = Path()
            path.move(to: start)
            let dx = (end.x - start.x) / 2
            path.addCurve(to: end, control1: CGPoint(x: start.x + dx, y: start.y), control2: CGPoint(x: end.x - dx, y: end.y))
            let strong = parent.role == .root
            context.stroke(path, with: .color(Carnet.inkTertiary.opacity(strong ? 0.8 : 0.45)), lineWidth: strong ? 2 : 1.2)
        }
    }

    private func color(_ relation: StudyMap.Relation) -> Color {
        switch relation {
        case .needs, .uses: return Carnet.inkSecondary
        case .implies: return tint
        case .contrast: return Carnet.wrong
        case .example: return Carnet.review
        }
    }

    private func drawLinks(_ context: inout GraphicsContext, _ model: Model, map: StudyMap) {
        let visible = Set(model.nodes.map(\.id))
        // Beaucoup de liens font un fouillis : au repos, on ne dessine que ceux de la notion choisie.
        let shown = map.links.filter { visible.contains($0.from) && visible.contains($0.to) }
        let focus = selected
        let all = shown.count <= 40
        for link in shown {
            let touches = focus == link.from || focus == link.to
            guard touches || (focus == nil && all) else { continue }
            let a = point(link.from, model), b = point(link.to, model)
            var path = Path()
            let mid = CGPoint(x: (a.x + b.x) / 2 + (b.y - a.y) * 0.18, y: (a.y + b.y) / 2 - (b.x - a.x) * 0.18)
            path.move(to: a)
            path.addQuadCurve(to: b, control: mid)
            let tone = color(link.relation).opacity(touches ? 0.95 : 0.5)
            context.stroke(path, with: .color(tone), style: StrokeStyle(lineWidth: touches ? 2 : 1.2, dash: link.relation == .contrast ? [3, 3] : [6, 4]))
            if let order = link.prerequisite {
                // La flèche va vers ce qui vient après.
                let target = order.after == link.from ? a : b
                let source = order.after == link.from ? mid : mid
                arrow(&context, at: target, from: source, color: tone)
            }
        }
    }

    private func arrow(_ context: inout GraphicsContext, at tip: CGPoint, from: CGPoint, color: Color) {
        let angle = atan2(tip.y - from.y, tip.x - from.x)
        // Un peu avant le nœud, pour qu'elle ne se cache pas dessous.
        let base = CGPoint(x: tip.x - cos(angle) * 70, y: tip.y - sin(angle) * 22)
        var head = Path()
        head.move(to: base)
        head.addLine(to: CGPoint(x: base.x - cos(angle - 0.5) * 9, y: base.y - sin(angle - 0.5) * 9))
        head.move(to: base)
        head.addLine(to: CGPoint(x: base.x - cos(angle + 0.5) * 9, y: base.y - sin(angle + 0.5) * 9))
        context.stroke(head, with: .color(color), lineWidth: 1.5)
    }

    // MARK: Un nœud

    private func related(_ id: String, map: StudyMap) -> Bool {
        guard let selected, selected != id else { return false }
        return map.links.contains { ($0.from == selected && $0.to == id) || ($0.to == selected && $0.from == id) }
    }

    private func nodeView(_ node: MindNode, model: Model, sheet: RevisionSheet, map: StudyMap) -> some View {
        let box = size(of: node)
        let isSelected = selected == node.id
        let linked = related(node.id, map: map)
        let isLinkSource = linkFrom == node.id
        return nodeBody(node, map: map)
            .frame(width: box.width, height: box.height)
            .background(background(node, selected: isSelected || isLinkSource), in: RoundedRectangle(cornerRadius: node.role == .root ? 14 : 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: node.role == .root ? 14 : 10, style: .continuous)
                .strokeBorder(border(node, selected: isSelected, linked: linked), style: StrokeStyle(lineWidth: isSelected || linked ? 2 : 1, dash: node.role == .custom ? [4, 3] : [])))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onTapGesture { tapped(node, sheet: sheet) }
            .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .global)
                .onChanged { dragging = (node.id, $0.translation) }
                .onEnded { value in moved(node, by: value.translation, model: model) })
            .contextMenu { menu(node, map: map) }
    }

    @ViewBuilder
    private func nodeBody(_ node: MindNode, map: StudyMap) -> some View {
        switch node.role {
        case .root:
            MacMathText(node.title, size: 14, design: .serif).foregroundStyle(Carnet.ground).lineLimit(2)
                .multilineTextAlignment(.center).padding(.horizontal, 10)
        case .chapter:
            HStack(spacing: 6) {
                MacMathText(node.title, size: 13).foregroundStyle(Carnet.ink).lineLimit(2)
                Spacer(minLength: 2)
                Image(systemName: map.collapsed.contains(node.id) ? "chevron.right" : "chevron.down")
                    .font(.caption2.weight(.bold)).foregroundStyle(Carnet.inkTertiary)
            }
            .padding(.horizontal, 10)
        case .entry(let kind):
            HStack(spacing: 6) {
                MasteryDot(level: map.mastery(node.id), size: 11)
                MacMathText(node.title, size: 12).foregroundStyle(Carnet.ink).lineLimit(2)
                Spacer(minLength: 0)
                Image(systemName: kind.icon).font(.caption2).foregroundStyle(Carnet.inkTertiary)
            }
            .padding(.horizontal, 8)
        case .custom:
            HStack(spacing: 5) {
                Image(systemName: "lightbulb").font(.caption2).foregroundStyle(Carnet.review)
                Text(node.title).font(.caption.italic()).foregroundStyle(Carnet.ink).lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
        }
    }

    private func background(_ node: MindNode, selected: Bool) -> Color {
        switch node.role {
        case .root: return tint
        case .chapter: return selected ? Carnet.sheetRaised : Carnet.sheet
        case .entry: return selected ? Carnet.sheetRaised : Carnet.sheet
        case .custom: return Carnet.sheet.opacity(0.7)
        }
    }

    private func border(_ node: MindNode, selected: Bool, linked: Bool) -> Color {
        if selected { return Carnet.ink }
        if linked { return tint }
        if node.role == .root { return tint }
        return Carnet.rule
    }

    // MARK: Gestes

    private func tapped(_ node: MindNode, sheet: RevisionSheet) {
        if let from = linkFrom {
            if case .entry = node.role, node.id != from { pending = (from, node.id) }
            linkFrom = nil
            return
        }
        selected = node.id
        switch node.role {
        case .entry: concept = node.id
        case .chapter: toggle(node.id)
        default: break
        }
    }

    private func toggle(_ id: String) {
        withAnimation(.snappy) {
            store.update(course) { map in
                if map.collapsed.contains(id) { map.collapsed.remove(id) } else { map.collapsed.insert(id) }
            }
        }
    }

    /// Déplacer un nœud emmène ses descendants : la place est gardée (elle survit à tout).
    private func moved(_ node: MindNode, by translation: CGSize, model: Model) {
        defer { dragging = nil }
        guard abs(translation.width) + abs(translation.height) > 6 else { return }
        let dx = Double(translation.width / zoom), dy = Double(translation.height / zoom)
        let moved = [node.id] + descendants(of: node.id, model.children)
        store.update(course) { map in
            for id in moved {
                guard let base = model.positions[id] else { continue }
                map.layout[id] = StudyMap.Point(x: base.x + dx, y: base.y + dy)
            }
        }
    }

    // MARK: Menu d'un nœud

    @ViewBuilder
    private func menu(_ node: MindNode, map: StudyMap) -> some View {
        switch node.role {
        case .entry:
            Button { concept = node.id } label: { Label("Comprendre", systemImage: "lightbulb") }
            Button { selected = node.id; linkFrom = node.id } label: { Label("Relier à une autre notion…", systemImage: "link.badge.plus") }
            Button { ideaParent = node.id } label: { Label("Ajouter une idée ici", systemImage: "plus.bubble") }
        case .chapter:
            Button { toggle(node.id) } label: { Label(map.collapsed.contains(node.id) ? "Déplier" : "Replier", systemImage: "chevron.up.chevron.down") }
            Button { ideaParent = node.id } label: { Label("Ajouter une idée ici", systemImage: "plus.bubble") }
        case .custom:
            Button { ideaTitle = node.title; renaming = node.id } label: { Label("Renommer", systemImage: "pencil") }
            Button { ideaParent = node.id } label: { Label("Ajouter une idée ici", systemImage: "plus.bubble") }
            Button(role: .destructive) { deleteIdea(node.id) } label: { Label("Supprimer", systemImage: "trash") }
        case .root:
            Button { ideaParent = MindGraph.rootID } label: { Label("Ajouter une idée", systemImage: "plus.bubble") }
        }
    }

    // MARK: Idées, liens

    private func addIdea(map: StudyMap) {
        let title = ideaTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { ideaTitle = ""; ideaParent = nil }
        guard !title.isEmpty, let parent = ideaParent else { return }
        let id = UUID().uuidString.prefix(8).lowercased()
        let parentKey = parent == MindGraph.rootID ? nil : parent
        store.update(course) { $0.customNodes.append(.init(id: String(id), title: title, note: nil, parent: parentKey)) }
    }

    private func rename() {
        let title = ideaTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { ideaTitle = ""; renaming = nil }
        guard !title.isEmpty, let node = renaming, node.hasPrefix("custom:") else { return }
        let id = String(node.dropFirst("custom:".count))
        store.update(course) { map in
            if let index = map.customNodes.firstIndex(where: { $0.id == id }) { map.customNodes[index].title = title }
        }
    }

    private func deleteIdea(_ node: String) {
        let id = String(node.dropFirst("custom:".count))
        store.update(course) { map in
            map.customNodes.removeAll { $0.id == id }
            map.layout["custom:" + id] = nil
        }
    }

    private func confirmLink(_ relation: StudyMap.Relation) {
        guard let pending else { return }
        store.update(course) { map in
            let link = StudyMap.Link(from: pending.from, to: pending.to, relation: relation, note: nil, userMade: true)
            if !map.links.contains(where: { $0.id == link.id }) { map.links.append(link) }
        }
        selected = pending.from
        self.pending = nil
    }

    // MARK: Barre d'outils

    private func fitZoom(_ model: Model, _ area: CGSize) -> CGFloat {
        guard area.width > 0, area.height > 0, model.width > 0, model.height > 0 else { return zoom }
        return min(1, max(0.3, min(area.width / model.width, area.height / model.height)))
    }

    private func fit(_ model: Model, size: CGSize? = nil) {
        zoom = fitZoom(model, size ?? viewport)
    }

    /// La racine au milieu de la vue (un instant après : la toile a changé de taille).
    private func centre(_ scroller: ScrollViewProxy, model: Model, size: CGSize, zoom: CGFloat) {
        // Une carte qui tient dans la place n'a rien à défiler ; sinon, la racine au milieu.
        guard model.width * zoom > size.width + 1 || model.height * zoom > size.height + 1 else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            scroller.scrollTo("mind-root", anchor: .center)
        }
    }

    private func toolbar(_ model: Model, map: StudyMap) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Button { userZoomed = true; zoom = max(0.25, zoom - 0.15) } label: { Image(systemName: "minus.magnifyingglass") }.help("Rétrécir")
                Button { userZoomed = true; zoom = min(2, zoom + 0.15) } label: { Image(systemName: "plus.magnifyingglass") }.help("Agrandir")
                Button { userZoomed = false; fit(model) } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }.help("Tout voir")
                Divider().frame(height: 16)
                let chapterIDs = model.nodes.filter { $0.role == .chapter }.map(\.id)
                Button {
                    withAnimation(.snappy) {
                        store.update(course) { m in
                            if m.collapsed.isEmpty { m.collapsed = Set(chapterIDs) } else { m.collapsed = [] }
                        }
                    }
                } label: { Image(systemName: map.collapsed.isEmpty ? "rectangle.compress.vertical" : "rectangle.expand.vertical") }
                    .help(map.collapsed.isEmpty ? "Replier les chapitres" : "Déplier les chapitres")
                Divider().frame(height: 16)
                Button { ideaParent = selected ?? MindGraph.rootID } label: { Image(systemName: "plus.bubble") }.help("Ajouter une idée")
                Button { linkFrom = selected } label: { Image(systemName: "link.badge.plus") }
                    .disabled(!canLink(model))
                    .help("Relier la notion choisie à une autre")
                if !map.layout.isEmpty {
                    Button { store.update(course) { $0.layout = [:] } } label: { Image(systemName: "arrow.uturn.backward") }.help("Remettre la disposition automatique")
                }
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(Carnet.ink)
            .padding(.horizontal, 12).frame(height: 34)
            .background(Carnet.sheet.opacity(0.95), in: Capsule())
            .overlay(Capsule().strokeBorder(Carnet.rule))
            if let source = linkFrom {
                Text("Touche la notion à relier à « \(course.revisionSheet?.entry(forKey: source)?.entry.title ?? "") »")
                    .font(.caption).foregroundStyle(Carnet.ink)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(tint.opacity(0.18), in: Capsule())
            }
        }
        .padding(.top, 10)
    }

    /// Une notion est choisie : on peut la relier à une autre.
    private func canLink(_ model: Model) -> Bool {
        guard let selected, let node = model.nodes.first(where: { $0.id == selected }) else { return false }
        if case .entry = node.role { return true }
        return false
    }

    private var legend: some View {
        HStack(spacing: 10) {
            ForEach(StudyMap.Mastery.allCases, id: \.rawValue) { level in
                HStack(spacing: 4) { MasteryDot(level: level, size: 10); Text(level.label).font(.caption2).foregroundStyle(Carnet.inkSecondary) }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Carnet.sheet.opacity(0.9), in: Capsule())
    }
}
