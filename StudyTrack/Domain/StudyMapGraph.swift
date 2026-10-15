import Foundation

// MARK: - Schémas

/// Un schéma pour **comprendre** : un enchaînement (que faire, dans quel ordre), une
/// hiérarchie de résultats (qui découle de quoi), un arbre de décision (quelle méthode
/// choisir) ou une comparaison (deux notions côte à côte). Écrit par Claude d'après la
/// fiche, dessiné par l'app (jamais une image : on peut toucher un nœud et aller à la notion).
struct Diagram: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        /// Les étapes d'une méthode, de haut en bas.
        case flow
        /// Qui découle de quoi : théorèmes, lemmes, définitions.
        case dependencies
        /// Un arbre de décision : « est-ce que… ? oui → …, non → … ».
        case tree
        /// Un tableau : des notions en colonnes, des critères en lignes.
        case comparison

        var label: String {
            switch self {
            case .flow: return String(localized: "Enchaînement")
            case .dependencies: return String(localized: "Qui découle de quoi")
            case .tree: return String(localized: "Que choisir ?")
            case .comparison: return String(localized: "Comparaison")
            }
        }

        var icon: String {
            switch self {
            case .flow: return "arrow.down.to.line"
            case .dependencies: return "point.3.connected.trianglepath.dotted"
            case .tree: return "arrow.triangle.branch"
            case .comparison: return "tablecells"
            }
        }
    }

    struct Node: Codable, Equatable, Identifiable {
        var id: String
        var label: String
        var detail: String?
        /// La clé de la notion de la fiche (toucher le nœud y mène).
        var entry: String?
    }

    struct Edge: Codable, Equatable {
        var from: String
        var to: String
        var label: String?
    }

    var id: String
    var title: String
    var summary: String?
    var kind: Kind
    var nodes: [Node] = []
    var edges: [Edge] = []
    /// Pour une comparaison : les colonnes et les lignes (la première cellule d'une ligne est son critère).
    var columns: [String]?
    var rows: [[String]]?
}

/// La disposition d'un schéma en couches, de haut en bas.
enum DiagramLayout {
    struct Result: Equatable {
        /// Le centre de chaque nœud.
        var positions: [String: StudyMap.Point]
        var width: Double
        var height: Double
        /// Les couches, dans l'ordre (les identifiants de chaque couche, de gauche à droite).
        var layers: [[String]]
        /// Les flèches qui reviennent en arrière (un cycle) : tracées, mais sans compter pour les couches.
        var backEdges: [Diagram.Edge]
    }

    static func layered(_ schema: Diagram, nodeWidth: Double = 170, nodeHeight: Double = 54,
                        horizontalGap: Double = 28, verticalGap: Double = 46) -> Result {
        let ids = schema.nodes.map(\.id)
        let known = Set(ids)
        let edges = schema.edges.filter { known.contains($0.from) && known.contains($0.to) && $0.from != $0.to }

        // Cycles : une flèche qui revient sur un nœud encore ouvert ne compte pas pour les couches.
        var outgoing: [String: [Diagram.Edge]] = [:]
        for edge in edges { outgoing[edge.from, default: []].append(edge) }
        var state: [String: Int] = [:]   // 1 : en cours, 2 : fini
        var back: [Diagram.Edge] = []
        func visit(_ id: String) {
            state[id] = 1
            for edge in outgoing[id] ?? [] {
                switch state[edge.to] {
                case 1: back.append(edge)
                case nil: visit(edge.to)
                default: break
                }
            }
            state[id] = 2
        }
        for id in ids where state[id] == nil { visit(id) }
        let forward = edges.filter { edge in !back.contains(edge) }

        // Couche = plus long chemin depuis une source.
        var layerOf: [String: Int] = [:]
        var incoming: [String: [String]] = [:]
        for edge in forward { incoming[edge.to, default: []].append(edge.from) }
        func layer(_ id: String) -> Int {
            if let known = layerOf[id] { return known }
            layerOf[id] = 0
            let value = (incoming[id] ?? []).map { layer($0) + 1 }.max() ?? 0
            layerOf[id] = value
            return value
        }
        for id in ids { _ = layer(id) }
        let depth = (layerOf.values.max() ?? -1) + 1
        var layers: [[String]] = Array(repeating: [], count: max(depth, 0))
        for id in ids { layers[layerOf[id] ?? 0].append(id) }

        // Ordre dans chaque couche : deux passages au barycentre des voisins.
        var position: [String: Double] = [:]
        for layer in layers { for (index, id) in layer.enumerated() { position[id] = Double(index) } }
        var neighbours: [String: [String]] = [:]
        for edge in forward {
            neighbours[edge.from, default: []].append(edge.to)
            neighbours[edge.to, default: []].append(edge.from)
        }
        func sweep(_ order: [Int]) {
            for index in order {
                let sorted = layers[index].enumerated().sorted { a, b in
                    func centre(_ id: String) -> Double {
                        let near = (neighbours[id] ?? []).filter { layerOf[$0] != index }
                        guard !near.isEmpty else { return position[id] ?? 0 }
                        return near.compactMap { position[$0] }.reduce(0, +) / Double(near.count)
                    }
                    let ca = centre(a.element), cb = centre(b.element)
                    return ca != cb ? ca < cb : a.offset < b.offset
                }.map(\.element)
                layers[index] = sorted
                for (i, id) in sorted.enumerated() { position[id] = Double(i) }
            }
        }
        if depth > 1 {
            sweep(Array(1..<depth))
            sweep(Array((0..<depth - 1).reversed()))
        }

        let widest = layers.map(\.count).max() ?? 0
        let totalWidth = Double(widest) * nodeWidth + Double(max(0, widest - 1)) * horizontalGap
        var positions: [String: StudyMap.Point] = [:]
        for (row, layer) in layers.enumerated() {
            let rowWidth = Double(layer.count) * nodeWidth + Double(max(0, layer.count - 1)) * horizontalGap
            let start = (totalWidth - rowWidth) / 2
            for (column, id) in layer.enumerated() {
                positions[id] = StudyMap.Point(x: start + nodeWidth / 2 + Double(column) * (nodeWidth + horizontalGap),
                                               y: nodeHeight / 2 + Double(row) * (nodeHeight + verticalGap))
            }
        }
        let height = depth == 0 ? 0 : Double(depth) * nodeHeight + Double(depth - 1) * verticalGap
        return Result(positions: positions, width: totalWidth, height: height, layers: layers, backEdges: back)
    }
}

// MARK: - Carte mentale

/// Un nœud de la carte : la racine (le cours), un chapitre, une notion, une idée à soi.
struct MindNode: Equatable, Identifiable {
    enum Role: Equatable {
        case root
        case chapter
        case entry(RevisionSheet.Entry.Kind)
        case custom
    }

    var id: String
    var title: String
    var role: Role
    var parent: String?
    var depth: Int
}

enum MindGraph {
    static let rootID = "root"
    static func chapterNode(_ chapterID: String) -> String { "chap:" + chapterID }
    static func customNode(_ id: String) -> String { "custom:" + id }

    /// Tous les nœuds : la racine, ses chapitres, leurs notions, puis les idées ajoutées
    /// (accrochées à ce qu'on a choisi ; si le parent n'existe plus, à la racine).
    static func nodes(sheet: RevisionSheet, map: StudyMap, courseTitle: String) -> [MindNode] {
        var result = [MindNode(id: rootID, title: courseTitle, role: .root, parent: nil, depth: 0)]
        for chapter in sheet.chapters where !chapter.entries.isEmpty {
            result.append(MindNode(id: chapterNode(chapter.id), title: chapter.title, role: .chapter, parent: rootID, depth: 1))
        }
        for item in sheet.keyed {
            result.append(MindNode(id: item.key, title: item.entry.title, role: .entry(item.entry.kind),
                                   parent: chapterNode(item.chapterID), depth: 2))
        }
        for custom in map.customNodes {
            let id = customNode(custom.id)
            let parent = custom.parent.flatMap { wanted in result.contains { $0.id == wanted } ? wanted : nil } ?? rootID
            let depth = (result.first { $0.id == parent }?.depth ?? 0) + 1
            result.append(MindNode(id: id, title: custom.title, role: .custom, parent: parent, depth: depth))
        }
        return result
    }

    /// Ce qu'on voit : sans les descendants d'un nœud replié.
    static func visible(_ nodes: [MindNode], collapsed: Set<String>) -> [MindNode] {
        var children: [String: [String]] = [:]
        for node in nodes { if let parent = node.parent { children[parent, default: []].append(node.id) } }
        var hidden = Set<String>()
        func hide(_ id: String) {
            for child in children[id] ?? [] { hidden.insert(child); hide(child) }
        }
        for id in collapsed { hide(id) }
        return nodes.filter { !hidden.contains($0.id) }
    }
}

/// La disposition d'une carte mentale **des deux côtés** de la racine.
enum MindLayout {
    static let columnWidth = 240.0
    static let rowHeight = 44.0

    static func twoSided(_ nodes: [MindNode], columnWidth: Double = MindLayout.columnWidth, rowHeight: Double = MindLayout.rowHeight) -> [String: StudyMap.Point] {
        var children: [String: [MindNode]] = [:]
        for node in nodes { if let parent = node.parent { children[parent, default: []].append(node) } }
        guard let root = nodes.first(where: { $0.parent == nil }) else { return [:] }

        func leaves(_ id: String) -> Int {
            let list = children[id] ?? []
            return list.isEmpty ? 1 : list.reduce(0) { $0 + leaves($1.id) }
        }
        // Les chapitres des deux côtés, à peu près autant de lignes de chaque.
        var sides: [[MindNode]] = [[], []]
        var weights = [0, 0]
        for child in children[root.id] ?? [] {
            let side = weights[0] <= weights[1] ? 0 : 1
            sides[side].append(child)
            weights[side] += leaves(child.id)
        }

        var positions: [String: StudyMap.Point] = [root.id: StudyMap.Point(x: 0, y: 0)]
        for (side, roots) in sides.enumerated() {
            let direction = side == 0 ? 1.0 : -1.0
            var row = 0.0
            var local: [String: Double] = [:]
            func place(_ node: MindNode) -> Double {
                let list = children[node.id] ?? []
                if list.isEmpty {
                    defer { row += 1 }
                    local[node.id] = row
                    return row
                }
                let ys = list.map(place)
                let y = ((ys.first ?? row) + (ys.last ?? row)) / 2
                local[node.id] = y
                return y
            }
            for node in roots { _ = place(node) }
            let centre = row > 0 ? (row - 1) / 2 : 0
            func absolute(_ node: MindNode, depth: Int) {
                if let y = local[node.id] {
                    positions[node.id] = StudyMap.Point(x: direction * Double(depth) * columnWidth, y: (y - centre) * rowHeight)
                }
                for child in children[node.id] ?? [] { absolute(child, depth: depth + 1) }
            }
            for node in roots { absolute(node, depth: 1) }
        }
        return positions
    }

    /// Le rectangle qui contient tous les centres (pour centrer et ajuster la vue).
    static func bounds(_ positions: [String: StudyMap.Point]) -> (minX: Double, maxX: Double, minY: Double, maxY: Double)? {
        guard let first = positions.values.first else { return nil }
        var box = (minX: first.x, maxX: first.x, minY: first.y, maxY: first.y)
        for point in positions.values {
            box.minX = min(box.minX, point.x); box.maxX = max(box.maxX, point.x)
            box.minY = min(box.minY, point.y); box.maxY = max(box.maxY, point.y)
        }
        return box
    }
}

// MARK: - Liens

enum StudyLinks {

    /// Ce qui précède et ce qui suit une notion, vu depuis elle.
    struct Neighbourhood: Equatable {
        struct Item: Equatable, Identifiable {
            var key: String
            var relation: StudyMap.Relation
            var note: String?
            var id: String { key + ">" + relation.rawValue }
        }

        /// Ce qu'il faut avoir compris avant.
        var before: [Item] = []
        /// Ce qui en découle.
        var after: [Item] = []
        /// Ce qu'il ne faut pas confondre avec elle.
        var aside: [Item] = []

        var isEmpty: Bool { before.isEmpty && after.isEmpty && aside.isEmpty }
    }

    static func neighbourhood(of key: String, in map: StudyMap, among keys: Set<String>) -> Neighbourhood {
        var result = Neighbourhood()
        func add(_ list: inout [Neighbourhood.Item], _ item: Neighbourhood.Item) {
            if !list.contains(item) { list.append(item) }
        }
        for link in map.links where keys.contains(link.from) && keys.contains(link.to) {
            if link.relation == .contrast {
                if link.from == key { add(&result.aside, .init(key: link.to, relation: .contrast, note: link.note)) }
                else if link.to == key { add(&result.aside, .init(key: link.from, relation: .contrast, note: link.note)) }
                continue
            }
            guard let order = link.prerequisite else { continue }
            if order.after == key { add(&result.before, .init(key: order.before, relation: link.relation, note: link.note)) }
            if order.before == key { add(&result.after, .init(key: order.after, relation: link.relation, note: link.note)) }
        }
        return result
    }

    /// Les liens qu'on déduit **sans IA** : une notion qui en cite une autre (« par le
    /// théorème 3.4 », « d'après la proposition 2.1 ») s'en sert. Marche pour tout cours,
    /// puisque les polycopiés et les fiches numérotent leurs résultats.
    static func cited(in sheet: RevisionSheet, limitPerEntry: Int = 6) -> [StudyMap.Link] {
        let items = sheet.keyed
        var byNumber: [String: [RevisionSheet.KeyedEntry]] = [:]
        for item in items {
            if let number = RevisionText.number(in: item.entry.title) { byNumber[number, default: []].append(item) }
        }
        guard !byNumber.isEmpty else { return [] }

        func group(of word: String) -> Set<RevisionSheet.Entry.Kind>? {
            if word.hasPrefix("theo") || word.hasPrefix("th") { return [.theorem] }
            if word.hasPrefix("prop") { return [.proposition] }
            if word.hasPrefix("lem") { return [.lemma] }
            if word.hasPrefix("cor") { return [.corollary] }
            if word.hasPrefix("def") { return [.definition] }
            if word.hasPrefix("form") { return [.formula] }
            return nil
        }

        let pattern = #"(theoreme|theorem|proposition|prop\.?|lemme|lemma|corollaire|corollary|definition|def\.?|formule|formula|th\.?)\s*(\d+(?:\.\d+)+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var links: [StudyMap.Link] = []
        var seen = Set<String>()
        for item in items {
            let text = RevisionText.fold(item.entry.title + " " + item.entry.body)
            let range = NSRange(text.startIndex..., in: text)
            var count = 0
            for match in regex.matches(in: text, range: range) {
                guard count < limitPerEntry, let wordRange = Range(match.range(at: 1), in: text),
                      let numberRange = Range(match.range(at: 2), in: text) else { continue }
                let word = String(text[wordRange])
                let number = String(text[numberRange])
                guard let candidates = byNumber[number] else { continue }
                let wanted = group(of: word)
                let target = candidates.first { wanted?.contains($0.entry.kind) ?? true } ?? (candidates.count == 1 ? candidates[0] : nil)
                guard let target, target.key != item.key else { continue }
                let link = StudyMap.Link(from: item.key, to: target.key, relation: .uses)
                if seen.insert(link.id).inserted { links.append(link); count += 1 }
            }
        }
        return links
    }

    /// Les liens d'une nouvelle lecture : ceux qu'on a posés à la main restent, les autres sont
    /// remplacés ; tout lien vers une notion qui n'existe plus tombe.
    static func merged(existing: [StudyMap.Link], generated: [StudyMap.Link], keys: Set<String>) -> [StudyMap.Link] {
        var result: [StudyMap.Link] = []
        var seen = Set<String>()
        for link in existing where link.userMade && keys.contains(link.from) && keys.contains(link.to) {
            if seen.insert(link.id).inserted { result.append(link) }
        }
        for link in generated where keys.contains(link.from) && keys.contains(link.to) && link.from != link.to {
            if seen.insert(link.id).inserted { result.append(link) }
        }
        return result
    }
}

// MARK: - Le parcours

/// Dans quel ordre apprendre, et par où reprendre : ce qui vient avant passe avant.
enum LearningPath {

    /// Les notions dans l'ordre où les comprendre : celui de la fiche, sauf qu'une notion
    /// ne passe jamais avant ce dont elle a besoin. Un cycle est coupé à l'ordre de la fiche.
    static func order(sheet: RevisionSheet, map: StudyMap) -> [String] {
        let items = sheet.keyed
        let keys = items.map(\.key)
        let known = Set(keys)
        var before: [String: Set<String>] = [:]
        var after: [String: Set<String>] = [:]
        for link in map.links {
            guard let pair = link.prerequisite, known.contains(pair.before), known.contains(pair.after), pair.before != pair.after else { continue }
            before[pair.after, default: []].insert(pair.before)
            after[pair.before, default: []].insert(pair.after)
        }
        var done = Set<String>()
        var result: [String] = []
        var remaining = keys
        while !remaining.isEmpty {
            // Le premier, dans l'ordre de la fiche, dont tout ce qu'il faut est déjà passé.
            if let index = remaining.firstIndex(where: { (before[$0] ?? []).isSubset(of: done) }) {
                let key = remaining.remove(at: index)
                result.append(key); done.insert(key)
            } else {
                // Un cycle : on coupe à l'ordre de la fiche.
                let key = remaining.removeFirst()
                result.append(key); done.insert(key)
            }
        }
        return result
    }

    /// Par où continuer : la première notion de l'ordre qui n'est pas encore solide.
    static func next(sheet: RevisionSheet, map: StudyMap) -> String? {
        order(sheet: sheet, map: map).first { map.mastery($0) != .solid }
    }

    struct Counts: Equatable {
        var unknown = 0
        var shaky = 0
        var solid = 0
        var total: Int { unknown + shaky + solid }
        var fraction: Double { total == 0 ? 0 : Double(solid) / Double(total) }
    }

    static func counts(sheet: RevisionSheet, map: StudyMap) -> Counts {
        var result = Counts()
        for item in sheet.keyed {
            switch map.mastery(item.key) {
            case .unknown: result.unknown += 1
            case .shaky: result.shaky += 1
            case .solid: result.solid += 1
            }
        }
        return result
    }

    /// Ce qu'il vaut mieux reprendre d'abord : pas solide, et dont d'autres dépendent (une
    /// notion fragile qui en porte dix pèse plus qu'une feuille).
    static func weakSpots(sheet: RevisionSheet, map: StudyMap, limit: Int = 5) -> [String] {
        let known = Set(sheet.keyed.map(\.key))
        var dependents: [String: Int] = [:]
        for link in map.links {
            guard let pair = link.prerequisite, known.contains(pair.before), known.contains(pair.after) else { continue }
            dependents[pair.before, default: 0] += 1
        }
        let scored = sheet.keyed.compactMap { item -> (String, Double, Int)? in
            let level = map.mastery(item.key)
            guard level != .solid else { return nil }
            let weight = Double(1 + dependents[item.key, default: 0]) * (level == .unknown ? 1.5 : 1)
            return (item.key, weight, item.index)
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }.prefix(limit).map(\.0)
    }

    /// Les prérequis d'une notion qui ne sont pas encore solides (« reprends d'abord… »).
    static func shakyPrerequisites(of key: String, map: StudyMap, among keys: Set<String>) -> [String] {
        StudyLinks.neighbourhood(of: key, in: map, among: keys).before.map(\.key).filter { map.mastery($0) != .solid }
    }
}
