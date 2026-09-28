import Foundation

// MARK: - Sources

/// Les sites d'où l'on importe le contenu d'un cours.
///
/// L'EPFL ne donne **aucun** accès API aux étudiant·e·s. Le contenu arrive donc
/// par la page elle-même : Moodle et Courseware s'ouvrent dans un navigateur
/// intégré où l'on se connecte avec son compte EPFL, puis l'app lit la page du
/// cours. Botafogo (le polycopié en ligne d'Analyse de S. Friedli) est public :
/// il se lit directement, sans connexion.
enum ContentSource: String, Codable, CaseIterable, Identifiable {
    case moodle, courseware, botafogo

    var id: String { rawValue }

    var label: String {
        switch self {
        case .moodle: return "Moodle"
        case .courseware: return "Courseware"
        case .botafogo: return "Botafogo"
        }
    }

    /// Ce que la source apporte, en une ligne.
    var detail: String {
        switch self {
        case .moodle: return "Semaines, vidéos, supports et séries du cours"
        case .courseware: return "Chapitres et leçons d'un MOOC EPFL"
        case .botafogo: return "Polycopié d'Analyse en ligne (S. Friedli), avec ses vidéos"
        }
    }

    var icon: String {
        switch self {
        case .moodle: return "graduationcap"
        case .courseware: return "play.rectangle.on.rectangle"
        case .botafogo: return "function"
        }
    }

    /// La page d'arrivée du navigateur intégré.
    var homeURL: URL {
        switch self {
        case .moodle: return URL(string: "https://moodle.epfl.ch/my/courses.php")!
        case .courseware: return URL(string: "https://courseware.epfl.ch/dashboard")!
        case .botafogo: return URL(string: "https://botafogo.epfl.ch/")!
        }
    }

    var requiresLogin: Bool { self != .botafogo }

    /// La source d'une adresse, d'après son hôte.
    static func detect(host: String?) -> ContentSource? {
        guard let host = host?.lowercased() else { return nil }
        if host.contains("moodle") { return .moodle }
        if host.contains("courseware") || host.contains("openedx") { return .courseware }
        if host.contains("botafogo") { return .botafogo }
        return nil
    }
}

// MARK: - Ce que la page a donné

/// Un élément tel que lu sur la page, avant toute interprétation.
///
/// Le script injecté dans la page ne décide de rien : il rapporte des titres, des
/// liens et un type technique (`resource`, `url`, `sequential`…). Tout ce qui
/// ressemble à une règle — « Série 3 » est une série, « Corrigé » s'ignore — vit
/// ici, en Swift pur et testé, pour que la même logique serve aux trois sources.
struct ScrapedItem: Codable, Equatable {
    var title: String
    var url: String = ""
    /// Type technique : module Moodle (`resource`, `url`, `page`, `kalvidres`…),
    /// bloc Open edX (`sequential`), `section` pour Botafogo.
    var type: String = ""
    /// Vidéos contenues, quand la source sait les compter.
    var videoCount: Int? = nil
}

struct ScrapedSection: Codable, Equatable {
    var title: String
    var items: [ScrapedItem]
}

struct ScrapedCourse: Codable, Equatable {
    var source: String
    var title: String
    var url: String
    var sections: [ScrapedSection]
}

// MARK: - Brouillon à relire

enum ContentItemKind: String, CaseIterable, Identifiable {
    case theory, series, ignore
    var id: String { rawValue }
    var label: String {
        switch self {
        case .theory: return "Théorie"
        case .series: return "Série"
        case .ignore: return "Ignorer"
        }
    }
}

struct ContentDraftItem: Identifiable, Equatable {
    var id = UUID()
    var kind: ContentItemKind
    /// « 3.2 » pour la théorie ; le numéro de série est `seriesNumber`.
    var number: String
    var title: String
    var url: String
    var videoCount: Int
    var seriesNumber: Int?
    var theoryKind: TheoryKind
}

struct ContentDraftSection: Identifiable, Equatable {
    var id = UUID()
    var title: String
    /// Semaine du semestre ; `0` = non planifié.
    var week: Int
    /// La semaine vient-elle de la page (« Semaine 3 », une plage de dates) ou
    /// d'une supposition ? La relecture le dit, pour qu'on sache quoi vérifier.
    var weekIsInferred: Bool
    var isIncluded: Bool
    var items: [ContentDraftItem]

    var theoryCount: Int { items.filter { $0.kind == .theory }.count }
    var seriesCount: Int { items.filter { $0.kind == .series }.count }
    var videoCount: Int { items.filter { $0.kind == .theory }.reduce(0) { $0 + $1.videoCount } }
}

struct ContentDraft: Equatable {
    var source: ContentSource
    var courseTitle: String
    var url: String
    var sections: [ContentDraftSection]

    var includedSections: [ContentDraftSection] { sections.filter(\.isIncluded) }
    var theoryCount: Int { includedSections.reduce(0) { $0 + $1.theoryCount } }
    var seriesCount: Int { includedSections.reduce(0) { $0 + $1.seriesCount } }
    var videoCount: Int { includedSections.reduce(0) { $0 + $1.videoCount } }
    var isEmpty: Bool { theoryCount == 0 && seriesCount == 0 }
}

// MARK: - Interprétation

enum ContentDraftBuilder {

    /// Transforme une page lue en brouillon : types, numéros, semaines.
    ///
    /// - Parameters:
    ///   - termStart: début du semestre, pour lire les sections Moodle datées
    ///     (« 16 septembre - 22 septembre »).
    ///   - totalWeeks: durée du semestre ; aucune semaine devinée ne la dépasse.
    static func draft(from page: ScrapedCourse,
                      source: ContentSource,
                      termStart: Date?,
                      totalWeeks: Int = 14,
                      calendar: Calendar = .current) -> ContentDraft {
        var sections: [ContentDraftSection] = []
        var seriesSeen: Set<Int> = []
        var nextSeries = 1
        var chapterIndex = 0

        for scraped in page.sections {
            let sectionTitle = cleanTitle(scraped.title)
            let explicitWeek = week(fromTitle: sectionTitle, termStart: termStart, calendar: calendar)
            // Une section datée (« 7 septembre - 13 septembre ») n'a pas de
            // numéro de chapitre : son « 7 » est un jour.
            let chapter = explicitWeek == nil ? leadingNumber(in: sectionTitle).flatMap { Int($0.number) } : nil
            var items: [ContentDraftItem] = []
            var theoryIndex = 0
            let isContentChapter = chapter != nil || explicitWeek != nil

            if isContentChapter || !scraped.items.isEmpty { chapterIndex += 1 }
            let chapterLabel = chapter ?? explicitWeek ?? chapterIndex

            for raw in scraped.items {
                let title = cleanTitle(raw.title)
                guard !title.isEmpty else { continue }
                let kind = classify(raw, title: title, source: source)
                switch kind {
                case .series:
                    var number = seriesNumber(in: title) ?? nextSeries
                    // Un même numéro vu deux fois (« Série 3 », « Série 3 (PDF) ») :
                    // c'est la même série, gardée une fois.
                    if seriesSeen.contains(number) {
                        if seriesNumber(in: title) != nil { continue }
                        while seriesSeen.contains(number) { number += 1 }
                    }
                    seriesSeen.insert(number)
                    nextSeries = max(nextSeries, number + 1)
                    items.append(ContentDraftItem(kind: .series,
                                                  number: String(number),
                                                  title: title,
                                                  url: raw.url,
                                                  videoCount: 0,
                                                  seriesNumber: number,
                                                  theoryKind: .reading))
                case .theory, .ignore:
                    theoryIndex += 1
                    let lead = leadingNumber(in: title)
                    let number = lead?.number ?? "\(chapterLabel).\(theoryIndex)"
                    let videos = raw.videoCount ?? (isVideo(raw) ? 1 : 0)
                    items.append(ContentDraftItem(kind: kind,
                                                  number: number,
                                                  title: lead.map { $0.rest.isEmpty ? title : $0.rest } ?? title,
                                                  url: raw.url,
                                                  videoCount: videos,
                                                  seriesNumber: nil,
                                                  theoryKind: theoryKind(for: raw, title: title, videos: videos)))
                }
            }

            guard !items.isEmpty else { continue }
            let useful = items.contains { $0.kind != .ignore }
            sections.append(ContentDraftSection(title: sectionTitle,
                                                week: explicitWeek ?? 0,
                                                weekIsInferred: explicitWeek == nil,
                                                isIncluded: useful && !isFrontMatter(sectionTitle),
                                                items: items))
        }

        // Aucune semaine lue sur la page : on propose une section par semaine,
        // dans l'ordre. C'est une **proposition** — la relecture la montre comme
        // telle et chaque semaine se corrige d'un geste.
        if !sections.contains(where: { !$0.weekIsInferred }) {
            var week = 0
            for index in sections.indices where sections[index].isIncluded {
                week += 1
                sections[index].week = min(week, max(totalWeeks, 1))
            }
        }

        return ContentDraft(source: source,
                            courseTitle: cleanTitle(page.title),
                            url: page.url,
                            sections: sections)
    }

    // MARK: Règles

    private static let ignoredTypes: Set<String> = [
        "forum", "label", "choice", "feedback", "questionnaire", "attendance",
        "zoom", "chat", "wiki", "glossary", "survey", "data", "lti", "bigbluebuttonbn",
        "quiz", "workshop", "subsection"
    ]

    /// Théorie, série, ou rien.
    static func classify(_ item: ScrapedItem, title: String, source: ContentSource) -> ContentItemKind {
        let lower = fold(title)
        let type = item.type.lowercased()
        if ignoredTypes.contains(type) { return .ignore }
        if matches(lower, #"\b(annonces?|announcements?|news|forum|discussion|sondage|feedback|informations? generales?)\b"#) {
            return .ignore
        }
        // Un corrigé accompagne une série ; ce n'est pas une série de plus.
        if matches(lower, #"\b(corrige|corriges|correction|corrections|solutions?|loesung|answers?)\b"#) {
            return .ignore
        }
        if matches(lower, #"\b(series?|exercices?|exercises?|problem ?sets?|td|homeworks?|devoirs?|assignments?|feuilles? d'exercices)\b"#)
            && !matches(lower, #"\b(series (numeriques|entieres|de fourier|de taylor|telescopiques|geometriques?))\b"#)
            && source != .botafogo {
            return .series
        }
        if type == "assign" { return .series }
        return .theory
    }

    static func isVideo(_ item: ScrapedItem) -> Bool {
        let type = item.type.lowercased()
        if ["kalvidres", "mediaspace", "video", "kalturavideo", "hvp"].contains(type) { return true }
        let haystack = fold(item.title + " " + item.url)
        return matches(haystack, #"(youtube|youtu\.be|vimeo|mediaspace|tube\.switch|kaltura|\bvideos?\b)"#)
    }

    static func theoryKind(for item: ScrapedItem, title: String, videos: Int) -> TheoryKind {
        let lower = fold(title)
        if matches(lower, #"\b(slides?|diapos?|diapositives?|transparents?)\b"#) { return .slides }
        if videos > 0 || isVideo(item) { return .video }
        if matches(lower, #"\b(chapitre|chapter)\b"#) { return .chapter }
        return .reading
    }

    /// Préface, avant-propos, outils : pas de la matière à planifier.
    static func isFrontMatter(_ title: String) -> Bool {
        let lower = fold(title)
        if matches(lower, #"^(i|ii|iii|iv)\."#) { return true }
        return matches(lower, #"\b(preface|avant-propos|foreword|generalites du cours|informations generales|general|outils graphiques)\b"#)
    }

    // MARK: Numéros

    /// Le numéro de série d'un titre : « Série 3 », « Serie_03 », « Exercise set 4 ».
    static func seriesNumber(in title: String) -> Int? {
        let lower = fold(title)
        let pattern = #"(?:series?|(?:exercices?|exercises?)(?:\s+sets?)?|problem ?sets?|td|homeworks?|devoirs?|assignments?|feuilles?)[\s_#.:-]*(?:n[o°]?\s*)?0*(\d{1,2})\b"#
        guard let match = firstMatch(lower, pattern) else { return nil }
        return Int(match)
    }

    /// Le numéro en tête d'un titre : « 3.2 Limite » → (3.2, Limite),
    /// « II.4 Trigonométrie » → (II.4, …), « Chapitre 3 : Suites » → (3, Suites).
    static func leadingNumber(in title: String) -> (number: String, rest: String)? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        let patterns = [
            #"^(?:chapitre|chapter|ch\.|section|lecon|leçon|lesson|module|partie|part|cours|lecture|vid[ée]o|video|th[ée]orie)\s*(\d+(?:\.\d+)*)\s*[:.\-–—]?\s*(.*)$"#,
            #"^(\d+(?:\.\d+)+|\d+)[.)]?\s+(.*)$"#,
            #"^([IVX]+\.\d+)\s+(.*)$"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            guard let match = regex.firstMatch(in: trimmed, range: range),
                  let numberRange = Range(match.range(at: 1), in: trimmed) else { continue }
            let rest = Range(match.range(at: 2), in: trimmed).map { String(trimmed[$0]) } ?? ""
            let number = String(trimmed[numberRange]).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            // « 2025 Examen » n'est pas un chapitre 2025.
            if let value = Int(number), value > 60 { return nil }
            return (number, rest.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    // MARK: Semaines

    private static let months: [String: Int] = [
        "janvier": 1, "janv": 1, "january": 1, "jan": 1,
        "fevrier": 2, "fevr": 2, "february": 2, "feb": 2,
        "mars": 3, "march": 3, "mar": 3,
        "avril": 4, "april": 4, "apr": 4, "avr": 4,
        "mai": 5, "may": 5,
        "juin": 6, "june": 6, "jun": 6,
        "juillet": 7, "july": 7, "jul": 7, "juil": 7,
        "aout": 8, "august": 8, "aug": 8,
        "septembre": 9, "september": 9, "sept": 9, "sep": 9,
        "octobre": 10, "october": 10, "oct": 10,
        "novembre": 11, "november": 11, "nov": 11,
        "decembre": 12, "december": 12, "dec": 12
    ]

    /// La semaine qu'un titre de section annonce.
    ///
    /// Deux formes : explicite (« Semaine 3 », « Week 3 », « S3 ») et datée — le
    /// format hebdomadaire de Moodle titre chaque section par sa plage
    /// (« 16 septembre - 22 septembre »), qu'on rapporte au début du semestre.
    static func week(fromTitle title: String, termStart: Date?, calendar: Calendar = .current) -> Int? {
        let lower = fold(title)
        if let value = firstMatch(lower, #"\b(?:semaine|week|sem\.?|wk)\s*0*(\d{1,2})\b"#), let week = Int(value), week > 0 {
            return week
        }
        if let value = firstMatch(lower, #"^s0*(\d{1,2})\b"#), let week = Int(value), week > 0 {
            return week
        }
        guard let termStart,
              let regex = try? NSRegularExpression(pattern: #"\b(\d{1,2})\.?\s+([a-z]+)\.?"#) else { return nil }
        let range = NSRange(lower.startIndex..., in: lower)
        for match in regex.matches(in: lower, range: range) {
            guard let dayRange = Range(match.range(at: 1), in: lower),
                  let monthRange = Range(match.range(at: 2), in: lower),
                  let day = Int(lower[dayRange]),
                  let month = months[String(lower[monthRange])] else { continue }
            let startYear = calendar.component(.year, from: termStart)
            let startMonth = calendar.component(.month, from: termStart)
            // Un semestre d'automne déborde sur janvier de l'année suivante.
            let year = month < startMonth - 2 ? startYear + 1 : startYear
            guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { continue }
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: termStart),
                                               to: calendar.startOfDay(for: date)).day ?? 0
            guard days > -7 else { return nil }
            return max(1, days / 7 + 1)
        }
        return nil
    }

    // MARK: Texte

    /// Espaces normalisés, délimiteurs LaTeX retirés (`\(\mathbb{R}\)` → `\mathbb{R}`,
    /// que `MathText` sait afficher), suffixes techniques de Moodle ôtés.
    static func cleanTitle(_ raw: String) -> String {
        var text = raw
        for token in [#"\("#, #"\)"#, #"\["#, #"\]"#] { text = text.replacingOccurrences(of: token, with: "") }
        for suffix in [" Fichier", " File", " URL", " Page", " Dossier", " Folder", " Devoir", " Assignment"] where text.hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count))
        }
        return text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Minuscules sans accents : « Série » et « serie » sont le même mot.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_CH"))
            .lowercased()
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func firstMatch(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured])
    }
}

// MARK: - Botafogo

/// Le polycopié en ligne de S. Friedli : une table des matières statique, puis
/// une page par section, qui contient les vidéos du cours.
enum BotafogoParser {

    /// Les cours listés sur la page d'accueil : (titre, adresse de la version en ligne).
    static func catalog(html: String, baseURL: URL) -> [(title: String, url: URL)] {
        let pattern = #"<span class="link-description">([^<]+)</span>\s*<a href="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            guard let titleRange = Range(match.range(at: 1), in: html),
                  let hrefRange = Range(match.range(at: 2), in: html),
                  let url = URL(string: String(html[hrefRange]), relativeTo: baseURL)?.absoluteURL else { return nil }
            let title = ContentDraftBuilder.cleanTitle(decode(String(html[titleRange])))
                .trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            return (title, url)
        }
    }

    /// La table des matières : un chapitre par `had-nav-toplevel`, une section
    /// par `had-nav-link-secondlevel`. Le PDF du chapitre n'est pas un élément.
    static func parseTOC(html: String, baseURL: URL) -> ScrapedCourse {
        let title = firstCapture(html, #"<title>\s*([^<|]+)"#).map { ContentDraftBuilder.cleanTitle(decode($0)) } ?? "Botafogo"
        var sections: [ScrapedSection] = []
        let chapters = html.components(separatedBy: #"<li class="had-nav-toplevel">"#).dropFirst()
        for chunk in chapters {
            guard let chapterTitle = firstCapture(chunk, ##"<a href="#[^"]*"[^>]*>([^<]+)</a>"##) else { continue }
            var items: [ScrapedItem] = []
            let pattern = #"<li class="had-nav-link-secondlevel"[^>]*><a href="([^"]+)">(.*?)</a></li>"#
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(chunk.startIndex..., in: chunk)
                for match in regex.matches(in: chunk, range: range) {
                    guard let hrefRange = Range(match.range(at: 1), in: chunk),
                          let textRange = Range(match.range(at: 2), in: chunk) else { continue }
                    let href = String(chunk[hrefRange])
                    let url = URL(string: href, relativeTo: baseURL)?.absoluteString ?? href
                    items.append(ScrapedItem(title: decode(stripTags(String(chunk[textRange]))),
                                             url: url,
                                             type: "section"))
                }
            }
            sections.append(ScrapedSection(title: decode(chapterTitle), items: items))
        }
        return ScrapedCourse(source: ContentSource.botafogo.rawValue,
                             title: title,
                             url: baseURL.absoluteString,
                             sections: sections)
    }

    /// Les vidéos de cours d'une page de section (pas les petites animations,
    /// qui sont des `anim-video-plyr`).
    static func videoTitles(inSection html: String) -> [String] {
        let parts = html.components(separatedBy: #"<div class="video">"#).dropFirst()
        return parts.compactMap { part in
            guard part.contains("video-plyr") else { return nil }
            return firstCapture(part, #"class="video-button"[^>]*>([^<]+)</a>"#).map { decode($0) } ?? "Vidéo"
        }
    }

    // MARK: Outils

    private static func firstCapture(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    static func decode(_ text: String) -> String {
        var result = text
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'",
                        "&#x27;": "'", "&apos;": "'", "&nbsp;": " ", "&#x2F;": "/", "&rsquo;": "'"]
        for (entity, value) in entities { result = result.replacingOccurrences(of: entity, with: value) }
        return result
    }
}
