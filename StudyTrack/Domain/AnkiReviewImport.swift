import Foundation

/// Une révision lue dans l'historique d'Anki (`revlog`).
struct AnkiReview: Equatable {
    /// Identifiant de la révision = son instant, en millisecondes depuis 1970.
    var id: Int64
    /// Temps passé sur la carte, en millisecondes (Anki le plafonne à 60 s).
    var durationMs: Int
    var deck: String

    var date: Date { Date(timeIntervalSince1970: TimeInterval(id) / 1000) }
}

/// Une session Anki reconstituée, prête à devenir une `StudySession`.
struct AnkiSessionDraft: Equatable {
    var deck: String
    var start: Date
    var seconds: Int
    var reviewCount: Int
    /// Stable d'un import à l'autre : la première révision de la session.
    var key: String
}

/// Le temps passé dans Anki, relevé **sans rien demander** à l'étudiant·e.
///
/// Anki ne connaît pas de « sessions » : il note chaque carte révisée, avec le
/// temps passé dessus. On les regroupe donc : deux révisions d'un même paquet
/// séparées de moins de `gap` appartiennent à la même session. Le temps retenu
/// est la **somme des temps de réponse**, pas l'écart entre la première et la
/// dernière carte — une pause café au milieu d'un paquet ne compte pas.
enum AnkiReviewImport {

    static let gap: TimeInterval = 5 * 60
    /// En dessous, ce n'est pas une session : une carte révisée en passant.
    static let minimumSeconds = 60

    /// La réponse brute de `cardReviews` : une liste de 9-uplets
    /// `[reviewTime, cardID, usn, ease, ivl, lastIvl, factor, time(ms), type]`.
    static func reviews(from outcome: AnkiOutcome, deck: String) -> [AnkiReview] {
        guard case .value(.array(let rows)) = outcome else { return [] }
        return rows.compactMap { row in
            guard case .array(let fields) = row, fields.count >= 8,
                  case .number(let id) = fields[0],
                  case .number(let time) = fields[7] else { return nil }
            return AnkiReview(id: Int64(id), durationMs: Int(time), deck: deck)
        }
    }

    /// Regroupe des révisions en sessions, paquet par paquet.
    ///
    /// Une révision présente dans deux paquets (un paquet parent et son sous-
    /// paquet renvoient la même carte) n'est comptée qu'une fois : on garde le
    /// paquet le plus précis, celui qui a le plus de niveaux `::`.
    static func sessions(from reviews: [AnkiReview]) -> [AnkiSessionDraft] {
        var byID: [Int64: AnkiReview] = [:]
        for review in reviews {
            if let existing = byID[review.id], depth(existing.deck) >= depth(review.deck) { continue }
            byID[review.id] = review
        }
        let grouped = Dictionary(grouping: byID.values, by: \.deck)
        var result: [AnkiSessionDraft] = []
        for (deck, items) in grouped {
            let sorted = items.sorted { $0.id < $1.id }
            var current: [AnkiReview] = []
            func flush() {
                guard let first = current.first else { return }
                let seconds = current.reduce(0) { $0 + $1.durationMs } / 1000
                if seconds >= minimumSeconds {
                    result.append(AnkiSessionDraft(deck: deck,
                                                   start: first.date,
                                                   seconds: seconds,
                                                   reviewCount: current.count,
                                                   key: "anki:\(deck):\(first.id)"))
                }
                current = []
            }
            for review in sorted {
                if let last = current.last, review.date.timeIntervalSince(last.date) > gap { flush() }
                current.append(review)
            }
            flush()
        }
        return result.sorted { $0.start < $1.start }
    }

    /// Le cours d'un paquet, d'après son nom : « EPFL::MATH-101 Analyse I »,
    /// « Ana I », « Algorithms ». Le code officiel, l'abréviation ou le nom
    /// suffisent ; en cas de doute, aucun cours — le temps reste compté, étiqueté
    /// Anki, sans être attribué au hasard.
    static func courseIndex(forDeck deck: String,
                            courses: [(code: String, shortName: String, name: String)]) -> Int? {
        let parts = deck.components(separatedBy: "::").map(normalize).reversed()
        for part in parts {
            var matches: [Int] = []
            for (index, course) in courses.enumerated() {
                let keys = [course.code, course.shortName, course.name].map(normalize).filter { $0.count >= 3 }
                if keys.contains(where: { part == $0 || part.contains($0) }) { matches.append(index) }
            }
            if matches.count == 1 { return matches[0] }
        }
        return nil
    }

    private static func depth(_ deck: String) -> Int { deck.components(separatedBy: "::").count }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
    }
}
