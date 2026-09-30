import Foundation

/// Lit la charge `__NUXT_DATA__` d'une page Nuxt — ce que servent cinq des six
/// polycopiés de Botafogo.
///
/// La table des matières n'est pas dans le HTML sous une forme lisible : elle est
/// dans un bloc JSON au format **devalue**, un tableau plat où chaque objet ne
/// contient que des **indices** vers d'autres cases (`{"title": 12, "path": 13}`)
/// et où les chaînes répétées ne figurent qu'une fois. Lire les chaînes dans
/// l'ordre ne suffit donc pas — la section affichée n'y apparaît qu'une fois, et
/// perdait sa place dans le sommaire. On suit les indices.
struct NuxtPayload {
    let values: [Any]

    /// Extrait et décode le bloc depuis le HTML ; `nil` si la page n'en a pas.
    init?(html: String) {
        guard let start = html.range(of: #"id="__NUXT_DATA__""#),
              let open = html.range(of: ">", range: start.upperBound..<html.endIndex),
              let close = html.range(of: "</script>", range: open.upperBound..<html.endIndex) else { return nil }
        let json = String(html[open.upperBound..<close.lowerBound])
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              !array.isEmpty else { return nil }
        values = array
    }

    init(values: [Any]) { self.values = values }

    /// Les enveloppes de devalue autour d'une valeur (`["ShallowReactive", 3]`).
    private static let wrappers: Set<String> = ["Reactive", "ShallowReactive", "Ref", "ShallowRef",
                                                "EmptyRef", "EmptyShallowRef", "NuxtError"]

    /// La valeur de la case `index`, débarrassée de ses enveloppes.
    func raw(_ index: Int) -> Any? {
        guard values.indices.contains(index) else { return nil }
        var value = values[index]
        var hops = 0
        while let array = value as? [Any], let tag = array.first as? String,
              Self.wrappers.contains(tag), array.count > 1, let next = array[1] as? Int,
              values.indices.contains(next), hops < 8 {
            value = values[next]
            hops += 1
        }
        return value
    }

    func string(_ index: Any?) -> String? {
        guard let index = index as? Int else { return nil }
        return raw(index) as? String
    }

    func object(_ index: Any?) -> [String: Any]? {
        guard let index = index as? Int else { return nil }
        return raw(index) as? [String: Any]
    }

    /// Les cases d'un tableau (des indices), ou `nil`.
    func list(_ index: Any?) -> [Int]? {
        guard let index = index as? Int, let array = raw(index) as? [Any] else { return nil }
        if let tag = array.first as? String, !tag.isEmpty { return nil }
        return array.compactMap { $0 as? Int }
    }

    /// Un nœud de navigation : `{title, path, children}`.
    struct NavNode: Equatable {
        var title: String
        var path: String
        var children: [NavNode]
    }

    /// Le sommaire du site et son titre.
    struct Navigation: Equatable {
        /// Le nom du polycopié (« Analyse B (MAN) »), quand un nœud racine le porte.
        var title: String?
        var chapters: [NavNode]
    }

    /// Le sommaire : la liste de nœuds `{title, path, children}` qui contient
    /// le plus de **sections** (enfants sans enfants).
    ///
    /// Compter les sections et non les nœuds : un site enveloppe parfois ses
    /// chapitres dans un nœud racine (algèbre linéaire), et un chapitre pas
    /// encore publié n'a pas de sections — il ne doit pas disqualifier la liste.
    func navigation() -> Navigation {
        var best: (index: Int, nodes: [NavNode], score: Int)?
        for (index, value) in values.enumerated() {
            guard let array = value as? [Any], !array.isEmpty, !(array.first is String) else { continue }
            let items = array.compactMap { $0 as? Int }
            guard items.count == array.count else { continue }
            let nodes = items.compactMap { node(at: $0, depth: 0) }
            guard nodes.count == items.count else { continue }
            let score = nodes.reduce(0) { total, node in
                total + node.children.filter { $0.children.isEmpty }.count
            }
            guard score > 0, score > (best?.score ?? 0) else { continue }
            best = (index, nodes, score)
        }
        guard let best else { return Navigation(title: nil, chapters: []) }
        // Le nœud qui porte cette liste, s'il existe, nomme le polycopié.
        let owner = values.lazy.compactMap { $0 as? [String: Any] }.first { object in
            (object["children"] as? Int).map { self.unwrapIndex($0) == best.index } ?? false
        }
        // Analyse I GM nomme sa racine comme son premier chapitre
        // (« I Préface ») : un titre de chapitre n'est pas un nom de polycopié.
        let title = owner.flatMap { string($0["title"]) }
            .flatMap { name in best.nodes.contains { $0.title == name } ? nil : name }
        return Navigation(title: title, chapters: best.nodes)
    }

    /// L'indice réel derrière une enveloppe (`["ShallowReactive", 5]` → 5).
    private func unwrapIndex(_ index: Int) -> Int {
        var current = index
        var hops = 0
        while values.indices.contains(current), let array = values[current] as? [Any],
              let tag = array.first as? String, Self.wrappers.contains(tag),
              array.count > 1, let next = array[1] as? Int, hops < 8 {
            current = next
            hops += 1
        }
        return current
    }

    private func node(at index: Int, depth: Int) -> NavNode? {
        guard depth < 3, let object = raw(index) as? [String: Any],
              let title = string(object["title"]),
              let path = string(object["path"]) else { return nil }
        let children = (list(object["children"]) ?? []).compactMap { node(at: $0, depth: depth + 1) }
        return NavNode(title: title, path: path, children: children)
    }

    /// Les chaînes, dans l'ordre du tableau (pour les listes de vidéos).
    var strings: [String] { values.compactMap { $0 as? String } }
}
