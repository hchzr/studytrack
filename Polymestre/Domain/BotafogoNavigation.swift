import Foundation

/// Se déplacer dans un cours Botafogo comme sur le site : le plan d'une page
/// (« Sur cette page »), la section précédente et suivante, le chemin
/// (« Polycopié › 5 Séries numériques › 5.1 Définitions »), ce qu'on a lu.
/// Pur, testé dans `validate.sh`.
enum BotafogoNavigation {

    // MARK: Le plan d'une page

    struct OutlineItem: Equatable {
        enum Kind: Equatable { case heading, statement, example, exercise, quiz, video }
        /// La place du bloc dans la page (son ancre : `block-<index>`).
        var index: Int
        var title: String
        var kind: Kind
    }

    /// Les repères d'une page : titres, énoncés encadrés (« Définition 5.1 »,
    /// « Théorème 5.4 »), exemples, exercices, quiz et vidéos — ce qu'on
    /// cherche en revenant sur une page.
    static func outline(_ blocks: [BotafogoBlock]) -> [OutlineItem] {
        blocks.enumerated().compactMap { index, block in
            switch block {
            case .heading(let text, _):
                return OutlineItem(index: index, title: text, kind: .heading)
            case .theorem(let kind, let title, _):
                guard !title.isEmpty else { return nil }
                let example = kind == .example || title.lowercased().hasPrefix("exemple")
                return OutlineItem(index: index, title: title, kind: example ? .example : .statement)
            case .aside(let title, _):
                return title.isEmpty ? nil : OutlineItem(index: index, title: title, kind: .statement)
            case .exercise(let label, _):
                return OutlineItem(index: index, title: label, kind: .exercise)
            case .quiz(let title, _, _, _):
                return OutlineItem(index: index, title: title.isEmpty ? "Quiz" : title, kind: .quiz)
            case .video(_, _, let title), .kaltura(_, let title):
                return OutlineItem(index: index, title: title, kind: .video)
            default:
                return nil
            }
        }
    }

    /// Le repère où l'on est : le dernier dont le haut est passé sous la
    /// ligne de lecture (`threshold` points sous le haut de la page).
    static func current(_ outline: [OutlineItem], tops: [Int: Double], threshold: Double = 90) -> Int? {
        var current: Int?
        for item in outline {
            guard let top = tops[item.index] else { continue }
            if top <= threshold { current = item.index } else { break }
        }
        return current ?? outline.first?.index
    }

    // MARK: L'ordre de lecture

    /// Le polycopié dans l'ordre, section après section.
    static func order(_ chapters: [BotafogoSite.Chapter]) -> [BotafogoSite.Chapter.Section] {
        chapters.flatMap(\.sections)
    }

    static func neighbours(of path: String, in chapters: [BotafogoSite.Chapter])
        -> (previous: BotafogoSite.Chapter.Section?, next: BotafogoSite.Chapter.Section?) {
        let all = order(chapters)
        guard let index = all.firstIndex(where: { $0.path == path }) else { return (nil, nil) }
        return (index > 0 ? all[index - 1] : nil, index + 1 < all.count ? all[index + 1] : nil)
    }

    /// La première section pas encore lue, à partir de `start` (ou du début).
    static func nextUnread(in sections: [BotafogoSite.Chapter.Section], read: Set<String>) -> BotafogoSite.Chapter.Section? {
        sections.first { !read.contains($0.path) }
    }

    /// « 3/9 » lues dans un chapitre.
    static func progress(_ chapter: BotafogoSite.Chapter, read: Set<String>) -> (read: Int, total: Int) {
        (chapter.sections.filter { read.contains($0.path) }.count, chapter.sections.count)
    }

    // MARK: Ce qu'on a lu

    /// La clé où ranger les sections lues d'un site (une par site, pas par
    /// cours : deux cours peuvent partager un polycopié).
    static func readKey(site: URL) -> String {
        "botafogo.read." + (site.host ?? "") + site.path
    }

    /// Le titre d'un chapitre ou d'une semaine sans son TeX (« 2 Nombres: $\mathbb{C}$ » → « 2 Nombres: ℂ »),
    /// pour un fil d'Ariane ou un surtitre.
    static func plainTitle(_ title: String) -> String {
        MathMarkup.plain(title)
    }
}
