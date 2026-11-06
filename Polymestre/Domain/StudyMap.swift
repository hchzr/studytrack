import Foundation

/// Ce qui rend une fiche **compréhensible** et pas seulement un dictionnaire : les liens
/// entre les notions (ce qui est nécessaire pour comprendre quoi), où l'on en est sur chacune,
/// une phrase en clair, des schémas, une question pour se tester.
///
/// Séparé de `RevisionSheet` exprès : la fiche est *écrite* (polycopié, Claude) et peut être
/// refaite ; ce qui est à l'étudiant·e — ses liens, sa maîtrise, ses notes, ses nœuds, la
/// place qu'elle a donnée aux choses — doit survivre à une nouvelle fiche. On retrouve une
/// notion par sa **clé** (le titre, sans accents ni casse), pas par sa place.
///
/// Tout ce qui décide est ici, pur et testé (`validate.sh`) ; les écrans sont dans StudyKit.
struct StudyMap: Codable, Equatable {
    var version = 1

    // MARK: Liens

    /// Ce qui relie deux notions. `A relation B` se lit « A <relation> B ».
    enum Relation: String, Codable, CaseIterable, Identifiable {
        /// A a besoin de B pour être compris (B d'abord).
        case needs
        /// A implique B (A d'abord).
        case implies
        /// A se sert de B (une preuve, une méthode) — B d'abord.
        case uses
        /// A se distingue de B (à ne pas confondre) : sans ordre.
        case contrast
        /// A est un exemple de B — B d'abord.
        case example

        var id: String { rawValue }

        var label: String {
            switch self {
            case .needs: return String(localized: "a besoin de")
            case .implies: return String(localized: "implique")
            case .uses: return String(localized: "se sert de")
            case .contrast: return String(localized: "à ne pas confondre avec")
            case .example: return String(localized: "est un exemple de")
            }
        }

        /// Vu de B : ce que B est pour A.
        var inverseLabel: String {
            switch self {
            case .needs: return String(localized: "est nécessaire à")
            case .implies: return String(localized: "découle de")
            case .uses: return String(localized: "sert à")
            case .contrast: return String(localized: "à ne pas confondre avec")
            case .example: return String(localized: "a pour exemple")
            }
        }

        var icon: String {
            switch self {
            case .needs: return "arrow.turn.up.left"
            case .implies: return "arrow.right"
            case .uses: return "wrench.and.screwdriver"
            case .contrast: return "arrow.left.arrow.right"
            case .example: return "lightbulb"
            }
        }
    }

    struct Link: Codable, Equatable, Identifiable {
        var from: String
        var to: String
        var relation: Relation
        var note: String?
        /// Posé à la main (jamais écrasé par une nouvelle lecture du cours).
        var userMade = false

        var id: String { "\(from)>\(relation.rawValue)>\(to)" }

        /// La notion qui doit venir **avant** l'autre, si la relation fixe un ordre.
        var prerequisite: (before: String, after: String)? {
            switch relation {
            case .needs, .uses, .example: return (to, from)
            case .implies: return (from, to)
            case .contrast: return nil
            }
        }
    }

    var links: [Link] = []

    // MARK: Où j'en suis

    enum Mastery: Int, Codable, CaseIterable {
        case unknown = 0, shaky, solid

        var label: String {
            switch self {
            case .unknown: return String(localized: "Pas encore")
            case .shaky: return String(localized: "Fragile")
            case .solid: return String(localized: "Solide")
            }
        }
    }

    struct Progress: Codable, Equatable {
        var level: Mastery
        var at: Date
    }

    var progress: [String: Progress] = [:]
    var notes: [String: String] = [:]

    func mastery(_ key: String) -> Mastery { progress[key]?.level ?? .unknown }

    // MARK: En clair

    struct Check: Codable, Equatable {
        var question: String
        var answer: String
    }

    /// Ce qu'une notion a de plus que son énoncé : pour la **comprendre**.
    struct Enrichment: Codable, Equatable {
        /// L'idée en une phrase, sans formule.
        var gist: String?
        /// À quoi ça sert, pourquoi on en a besoin.
        var why: String?
        /// Un exemple concret, court.
        var example: String?
        /// Une question pour se tester, avec sa réponse.
        var check: Check?
    }

    var enrichment: [String: Enrichment] = [:]

    // MARK: Carte mentale

    /// Une idée ajoutée à la main, accrochée à une notion ou à un chapitre.
    struct CustomNode: Codable, Equatable, Identifiable {
        var id: String
        var title: String
        var note: String?
        /// La clé de la notion (ou l'identifiant du chapitre) à laquelle elle est accrochée ;
        /// `nil` : directement à la racine.
        var parent: String?
    }

    var customNodes: [CustomNode] = []

    struct Point: Codable, Equatable {
        var x: Double
        var y: Double
    }

    /// La place qu'on a donnée à un nœud en le déplaçant (sinon, la disposition automatique).
    var layout: [String: Point] = [:]
    /// Les chapitres repliés sur la carte.
    var collapsed: Set<String> = []

    // MARK: Schémas

    var diagrams: [Diagram] = []

    // MARK: NotebookLM

    struct Resource: Codable, Equatable, Identifiable {
        enum Kind: String, Codable, CaseIterable {
            case podcast, video, quiz, slides, other

            var label: String {
                switch self {
                case .podcast: return String(localized: "Podcast")
                case .video: return String(localized: "Vidéo")
                case .quiz: return String(localized: "Quiz")
                case .slides: return String(localized: "Diapositives")
                case .other: return String(localized: "Autre")
                }
            }

            var icon: String {
                switch self {
                case .podcast: return "waveform"
                case .video: return "play.rectangle"
                case .quiz: return "questionmark.circle"
                case .slides: return "rectangle.on.rectangle"
                case .other: return "doc"
                }
            }
        }

        var id: String
        var kind: Kind
        var title: String
        /// Une adresse (le carnet, une vidéo) ; ou…
        var url: String?
        /// …un fichier gardé dans l'app (un podcast importé).
        var fileName: String?
        var addedAt: Date
        /// Le chapitre dont il parle (`nil` : tout le cours).
        var chapter: String?
    }

    /// L'adresse du carnet NotebookLM de ce cours, collée une fois.
    var notebookURL: String?
    /// Un carnet NotebookLM par chapitre (clé : l'identifiant du chapitre).
    var chapterNotebooks: [String: String]?
    /// Les chapitres que Claude a relus, et quand (`enrichedAt` : le cours entier).
    var enrichedChapters: [String: Date]?
    var resources: [Resource] = []

    /// Quand les liens, les phrases en clair et les schémas ont été écrits (par Claude).
    var enrichedAt: Date?

    var isEmpty: Bool {
        links.isEmpty && progress.isEmpty && enrichment.isEmpty && diagrams.isEmpty && customNodes.isEmpty && resources.isEmpty && (enrichedChapters ?? [:]).isEmpty
    }

    // MARK: Garder

    static func decode(_ raw: String) -> StudyMap? {
        guard !raw.isEmpty else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(StudyMap.self, from: Data(raw.utf8))
    }

    func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

// MARK: - Les clés

extension RevisionSheet {
    /// Chaque notion de la fiche avec sa clé stable (le titre sans accents ni casse ; un
    /// doublon prend « #2 »), son chapitre et sa place.
    struct KeyedEntry: Equatable, Identifiable {
        var key: String
        var entry: Entry
        var chapterID: String
        var chapterTitle: String
        var index: Int
        var id: String { key }
    }

    var keyed: [KeyedEntry] {
        var seen: [String: Int] = [:]
        var result: [KeyedEntry] = []
        for chapter in chapters {
            for entry in chapter.entries {
                var key = RevisionText.fold(entry.title).trimmingCharacters(in: .whitespacesAndNewlines)
                if key.isEmpty { key = entry.kind.rawValue }
                let count = seen[key, default: 0] + 1
                seen[key] = count
                if count > 1 { key += "#\(count)" }
                result.append(KeyedEntry(key: key, entry: entry, chapterID: chapter.id, chapterTitle: chapter.title, index: result.count))
            }
        }
        return result
    }

    func entry(forKey key: String) -> KeyedEntry? { keyed.first { $0.key == key } }

    /// Les notions d'un chapitre (`nil` : toutes). Les clés restent celles de la fiche entière :
    /// la maîtrise, les liens et les notes d'une notion ne changent pas selon ce qu'on regarde.
    func keyed(in chapter: String?) -> [KeyedEntry] {
        guard let chapter else { return keyed }
        return keyed.filter { $0.chapterID == chapter }
    }

    func chapter(_ id: String?) -> Chapter? { id.flatMap { id in chapters.first { $0.id == id } } }
}
