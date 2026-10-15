import Foundation

/// Les notifications du bureau d'étude : une file, pas des bulles qui se
/// marchent dessus. Le Centre de notifications de macOS étant fermé pendant un
/// blocage, ce qui compte (une app cachée, un envoi de l'iPhone, la réponse de
/// Claude) passe par ici.
///
/// Pur et testé : les règles de la file ; l'affichage est dans le Mac.
enum DeskNotice {

    enum Kind: String, Codable {
        case blockedApp, iPhone, claude, info
    }

    struct Item: Identifiable, Equatable {
        var id = UUID()
        var kind: Kind
        var text: String
        var icon: String
        var at: Date
    }

    /// Trois au plus à l'écran.
    static let maxVisible = 3
    /// Deux du même genre à moins de 4 s n'en font qu'une (dix apps cachées d'un
    /// coup ne font pas dix bulles).
    static let coalesce: TimeInterval = 4

    /// Combien de temps une notification reste.
    static func duration(_ kind: Kind) -> TimeInterval {
        switch kind {
        case .blockedApp: return 4
        case .iPhone: return 4
        case .claude: return 6
        case .info: return 5
        }
    }

    /// Ajoute `item` : le même genre à moins de `coalesce` secondes le remplace
    /// (même place, texte et heure frais) ; au-delà de `maxVisible`, la plus
    /// ancienne part.
    static func adding(_ item: Item, to items: [Item]) -> [Item] {
        var result = items
        if let index = result.lastIndex(where: { $0.kind == item.kind && item.at.timeIntervalSince($0.at) < coalesce }) {
            var merged = item
            merged.id = result[index].id
            result[index] = merged
        } else {
            result.append(item)
        }
        if result.count > maxVisible { result.removeFirst(result.count - maxVisible) }
        return result
    }

    /// Ce qui est encore à l'écran à `now`.
    static func visible(_ items: [Item], at now: Date) -> [Item] {
        items.filter { now.timeIntervalSince($0.at) < duration($0.kind) }
    }
}
