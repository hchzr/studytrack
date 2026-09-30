import Foundation

// MARK: - Ce que Moodle donne d'un cours

/// Une activité d'un cours Moodle, telle que l'app l'a lue.
struct MoodleActivity: Equatable {
    var id: String
    var name: String
    /// `resource`, `url`, `assign`, `page`, `folder`, `forum`, `label`…
    var module: String
    /// La page de l'activité sur Moodle (`mod/resource/view.php?id=…`).
    var url: String
    /// Où mène vraiment une activité « lien » (MediaSpace, un PDF, une page).
    var target: String? = nil
    /// L'échéance d'un devoir, lue sur sa page.
    var dueDate: Date? = nil
    var isVisible = true

    /// L'adresse à ouvrir : la cible réelle quand on la connaît.
    var link: String { (target?.isEmpty == false ? target : nil) ?? url }
}

struct MoodleSection: Equatable {
    var number: Int
    var title: String
    var activities: [MoodleActivity]
}

struct MoodleCourseSnapshot: Equatable {
    var title: String
    var url: String
    var sections: [MoodleSection]

    var activityCount: Int { sections.reduce(0) { $0 + $1.activities.count } }
}

/// Un lien d'un élément : la vidéo d'un cours, ses transparents, un corrigé.
struct ContentLink: Codable, Equatable, Hashable {
    enum Kind: String, Codable {
        case video, slides, notes, pdf, page, solution

        var icon: String {
            switch self {
            case .video: return "play.rectangle"
            case .slides: return "rectangle.on.rectangle"
            case .notes: return "pencil.and.scribble"
            case .pdf: return "doc.richtext"
            case .page: return "safari"
            case .solution: return "checkmark.seal"
            }
        }
    }
    var title: String
    var url: String
    var kind: Kind

    var icon: String { kind.icon }

    static func decodeList(_ raw: String) -> [ContentLink] {
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ContentLink].self, from: data)) ?? []
    }

    static func encodeList(_ links: [ContentLink]) -> String {
        guard !links.isEmpty, let data = try? JSONEncoder().encode(links) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - L'analyse

/// Comprend un cours Moodle comme un·e étudiant·e le lit.
///
/// Une page Moodle est une liste d'activités posées par l'enseignant·e, dans
/// ses mots : « Lecture notes 1a (blank) », « Lecture 1a recording »,
/// « Transparents (4 pages sur 1) », « serie04 sol », « Rendu 04 (en groupe) »,
/// « Apprendre à étudier - 03 ». En faire une liste de choses à cocher donnait
/// trente lignes par semaine, dont la moitié n'étaient pas du travail à suivre.
///
/// L'analyse, relevée sur de vrais cours (CS-101, CS-107, MATH-111, PHYS-101) :
///   • **regroupe** ce qui va ensemble — un cours, c'est son enregistrement,
///     ses transparents et ses notes ; une série, c'est son énoncé et son
///     corrigé, quel que soit leur nom ;
///   • **distingue** ce qu'on suit (théorie, séries) de ce qui a une date
///     (rendus notés, projet, examen), des anciens examens, et des documents
///     du cours (formulaire, aide-mémoire, organisation), gardés comme liens ;
///   • **range** chaque élément à sa semaine.
enum MoodleCourseAnalyzer {

    static func draft(from snapshot: MoodleCourseSnapshot,
                      termStart: Date?,
                      totalWeeks: Int = 14,
                      calendar: Calendar = .current) -> ContentDraft {
        var sections: [ContentDraftSection] = []
        var documents: [ContentDraftItem] = []
        var pastExams: [ContentDraftItem] = []
        var deadlines: [ContentDraftItem] = []

        for section in snapshot.sections {
            let title = ContentDraftBuilder.cleanTitle(section.title)
            let role = role(of: title, number: section.number)
            let week = ContentDraftBuilder.week(fromTitle: title, termStart: termStart, calendar: calendar)
                .map { min($0, max(totalWeeks, 1)) }
            let visible = section.activities.filter(\.isVisible)

            switch role {
            case .exam:
                if let date = examDate(in: title, termStart: termStart, calendar: calendar) {
                    deadlines.append(deadline(title: examTitle(title), date: date, kind: .exam, url: snapshot.url))
                }
                documents.append(contentsOf: visible.map { document($0, section: title) })
                continue
            case .pastExams:
                pastExams.append(contentsOf: pastExamItems(visible))
                continue
            case .general:
                for activity in visible {
                    let kind = classify(activity, inWeek: false)
                    switch kind {
                    case .deadline: deadlines.append(deadline(for: activity, calendar: calendar))
                    case .ignore: continue
                    default: documents.append(document(activity, section: title))
                    }
                }
                continue
            case .project:
                for activity in visible {
                    if let item = projectDeadline(activity, section: title, termStart: termStart, calendar: calendar) {
                        deadlines.append(item)
                    } else if classify(activity, inWeek: false) != .ignore {
                        documents.append(document(activity, section: title))
                    }
                }
                continue
            case .content:
                break
            }

            var items: [ContentDraftItem] = []
            var lectureGroups: [(key: String, activities: [MoodleActivity])] = []
            var seriesGroups: [(number: Int, statement: [MoodleActivity], solution: [MoodleActivity])] = []

            func addToSeries(_ number: Int, statement: MoodleActivity? = nil, solution: MoodleActivity? = nil) {
                if let index = seriesGroups.firstIndex(where: { $0.number == number }) {
                    if let statement { seriesGroups[index].statement.append(statement) }
                    if let solution { seriesGroups[index].solution.append(solution) }
                } else {
                    seriesGroups.append((number, statement.map { [$0] } ?? [], solution.map { [$0] } ?? []))
                }
            }

            // Les corrigés d'abord mis de côté : ils se rattachent à leur série.
            var pendingSolutions: [MoodleActivity] = []
            for activity in visible {
                switch classify(activity, inWeek: true) {
                case .series:
                    let number = seriesNumber(activity.name) ?? week ?? section.number
                    // « Enoncé/Corrigé de la série 4 » : l'énoncé et le corrigé à la même adresse.
                    let both = fold(activity.name).contains("corrig") && fold(activity.name).contains("enonc")
                    addToSeries(number, statement: activity, solution: both ? activity : nil)
                case .solution:
                    pendingSolutions.append(activity)
                case .lecture:
                    let key = lectureKey(activity.name)
                    if let index = lectureGroups.firstIndex(where: { $0.key == key }) {
                        lectureGroups[index].activities.append(activity)
                    } else {
                        lectureGroups.append((key, [activity]))
                    }
                case .deadline:
                    deadlines.append(deadline(for: activity, calendar: calendar))
                case .document:
                    documents.append(document(activity, section: title))
                case .ignore:
                    continue
                }
            }
            for solution in pendingSolutions {
                let explicit = seriesNumber(solution.name)
                if isDeliverableSolution(solution.name) {
                    // « rendu02 sol » : le corrigé d'un rendu noté, un document.
                    documents.append(document(solution, section: title))
                } else if let number = explicit, seriesGroups.contains(where: { $0.number == number }) {
                    addToSeries(number, solution: solution)
                } else if explicit == nil, seriesGroups.count == 1 {
                    addToSeries(seriesGroups[0].number, solution: solution)
                } else if let number = explicit ?? week {
                    addToSeries(number, solution: solution)
                }
            }

            for (index, group) in lectureGroups.enumerated() {
                items.append(lectureItem(group.activities, key: group.key, index: index + 1,
                                         sectionTitle: title, week: week ?? 0, groups: lectureGroups.count))
            }
            for group in seriesGroups.sorted(by: { $0.number < $1.number }) {
                items.append(seriesItem(group.number, statement: group.statement, solution: group.solution))
            }
            guard !items.isEmpty else { continue }
            sections.append(ContentDraftSection(title: title,
                                                week: week ?? 0,
                                                weekIsInferred: week == nil,
                                                isIncluded: true,
                                                items: items))
        }

        // Des sections sans semaine lisible (un plan par thème) : une par
        // semaine, dans l'ordre — une proposition, montrée comme telle.
        if sections.contains(where: \.weekIsInferred), !sections.contains(where: { !$0.weekIsInferred }) {
            for (offset, index) in sections.indices.enumerated() {
                sections[index].week = min(offset + 1, max(totalWeeks, 1))
            }
        }
        // Semaines d'un cours rangées à l'envers (« Semaine 4 » en premier) :
        // on les remet dans l'ordre du semestre.
        sections.sort { lhs, rhs in
            if lhs.week == 0 || rhs.week == 0 { return lhs.week != 0 && rhs.week == 0 }
            return lhs.week < rhs.week
        }

        if !deadlines.isEmpty {
            sections.append(ContentDraftSection(title: "Échéances : rendus, projet, examen",
                                                week: 0, weekIsInferred: false, isIncluded: true,
                                                items: deadlines.sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }))
        }
        if !pastExams.isEmpty {
            sections.append(ContentDraftSection(title: "Anciens examens", week: 0, weekIsInferred: false,
                                                isIncluded: true, items: pastExams))
        }
        if !documents.isEmpty {
            sections.append(ContentDraftSection(title: "Documents du cours (non suivis)", week: 0, weekIsInferred: false,
                                                isIncluded: true, items: documents))
        }

        return ContentDraft(source: .moodle, courseTitle: snapshot.title, url: snapshot.url, sections: sections)
    }

    // MARK: Rôle d'une section

    enum SectionRole { case content, general, exam, pastExams, project }

    static func role(of title: String, number: Int) -> SectionRole {
        let lower = fold(title)
        if matches(lower, #"\b(anciens? examens?|examens? des annees|previous (final )?exams?|past exams?|annales)\b"#) { return .pastExams }
        if matches(lower, #"^(examen|exam|final exam|examen final|midterm)\b"#) { return .exam }
        if matches(lower, #"\b(mini-?projets?|projets?|projects?)\b"#), !matches(lower, #"\b(semaine|week)\s*\d"#) { return .project }
        if ContentDraftBuilder.week(fromTitle: title, termStart: nil) != nil { return .content }
        if number == 0 { return .general }
        if matches(lower, #"^(informations?|general|generalites|course information|horaires?|salles|calendrier|calendar|ressources|resources|references|evaluation|grading|fora|forums?|communication|room assignment|weekly quizzes|questionnaires?|cheat ?sheet|description|organisation|organization|contact|faq|liens|links|annonces)\b"#) {
            return .general
        }
        return .content
    }

    // MARK: Une activité

    enum ActivityKind: Equatable { case lecture, series, solution, deadline, document, ignore }

    private static let ignoredModules: Set<String> = [
        "forum", "lti", "label", "choice", "choicegroup", "questionnaire", "feedback", "attendance",
        "chat", "wiki", "glossary", "survey", "data", "workshop", "bigbluebuttonbn", "zoom", "subsection"
    ]

    static func classify(_ activity: MoodleActivity, inWeek: Bool) -> ActivityKind {
        let name = fold(activity.name)
        let module = activity.module.lowercased()
        if module == "assign" { return .deadline }
        if ignoredModules.contains(module) { return .ignore }
        // Ce qui accompagne les études sans en être : méthode, organisation,
        // équipe, instructions d'examen, aides-mémoire, bases d'exercices.
        if matches(name, #"(apprendre a etudier|learning companion|compagnon|contrat|equipe et comportements|comportements?|instructions?|qcm amc|initiative|mieux comprendre|cheat ?sheet|aide-memoire|formula sheet|formulaire|math review|exoset|plan du cours|syllabus|organisation du cours|pedagogie|room|salles|horaires|students-|^cm-\d|test enonce|test reponses|examen blanc|impression|ressources utiles|categorisation|explique|mooc apprendre)"#) {
            return .document
        }
        if module == "quiz" { return .document }
        if matches(name, #"\b(rendus?|devoirs? note|graded|homework submission)\b"#) && !isSolution(name) {
            return .deadline
        }
        if isSolution(name) && !(name.contains("enonc") && name.contains("corrig")) { return .solution }
        if isSeries(name) { return .series }
        if inWeek, matches(name, #"^(exercises?|exercices?|exos?)$"#) { return .series }
        if isLecture(name) { return inWeek ? .lecture : .document }
        if module == "folder" { return .document }
        return inWeek ? .lecture : .document
    }

    static func isSolution(_ folded: String) -> Bool {
        matches(folded, #"(\bcorrig|\bsolutions?\b|\bsols?\b|\bcorrections?\b|\bloesung|\banswers?\b|\breponses\b)"#)
    }

    static func isSeries(_ folded: String) -> Bool {
        matches(folded, #"(\bseries?\s*[-_#.:]?\s*0*\d|\bserie\d|\bproblem ?sets?\b|\bexercise sets?\b|\bexercises?\b|\bexercices?\b|\bfeuilles? d.exercices|\btd\s*\d|\bhomework\s*\d|enonce/corrige|\bla serie\b)"#)
            && !matches(folded, #"\bseries (numeriques|entieres|de fourier|de taylor|geometriques?)\b"#)
    }

    static func isLecture(_ folded: String) -> Bool {
        matches(folded, #"(\blectures?\b|\bcours\b|transparents?|slides?|diapos?|\bnotes?\b|enregistrement|recording|\bvideos?\b|chapitres?|chapters?|polycopie|^\d{1,2}[-_ ][a-z])"#)
    }

    static func isDeliverableSolution(_ name: String) -> Bool {
        matches(fold(name), #"\brendus?\s*\d*"#)
    }

    /// « Série 3 », « serie04 », « Série02 », « Problem Set 1 », « série 4 ».
    static func seriesNumber(_ name: String) -> Int? {
        let lower = fold(name)
        let pattern = #"(?:series?|problem ?sets?|exercise sets?|feuilles?|td|homework|week)\s*[-_#.:]?\s*(?:n[o°]\s*)?0*(\d{1,2})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
              let range = Range(match.range(at: 1), in: lower) else { return nil }
        return Int(lower[range])
    }

    // MARK: Cours (théorie)

    /// Ce qui relie les activités d'un même cours : son numéro (« 1a »), son
    /// jour (« Tuesday »), son chapitre (« 01- »), un sujet entre parenthèses —
    /// jamais la mise en page (« 4 pages sur 1 ») ni l'état (« annotated »).
    static func lectureKey(_ name: String) -> String {
        let lower = fold(name)
        if let value = firstMatch(lower, #"(?:lecture|cours|chapitre|chapter|lesson|lecon)\s*(?:notes?\s*)?0*(\d+[a-z]?)\b"#) {
            return "n" + value
        }
        if let value = firstMatch(lower, #"^0*(\d{1,2})[-_ ]"#) { return "n" + value }
        let days = ["monday": "lundi", "tuesday": "mardi", "wednesday": "mercredi", "thursday": "jeudi", "friday": "vendredi",
                    "lundi": "lundi", "mardi": "mardi", "mercredi": "mercredi", "jeudi": "jeudi", "vendredi": "vendredi"]
        for (day, canonical) in days where lower.contains(day) { return "d" + canonical }
        let layout = #"^(\d+ pages? sur \d+|\d+ pages? per \d+|blank|annotated|annotees?|annotes?|vierges?|complet|full|print|imprimable|\d+ par page)$"#
        let parentheticals = matchesAll(lower, #"\(([^)]+)\)"#).map { $0.trimmingCharacters(in: .whitespaces) }
        if let topic = parentheticals.first(where: { !matches($0, layout) }) { return "t" + topic }
        return "section"
    }

    private static func lectureItem(_ activities: [MoodleActivity], key: String, index: Int,
                                    sectionTitle: String, week: Int, groups: Int) -> ContentDraftItem {
        let links = activities.map(link(for:))
        let hasVideo = links.contains { $0.kind == .video }
        let title: String
        if key.hasPrefix("n") {
            let number = String(key.dropFirst())
            let named = activities.lazy.compactMap { activity -> String? in
                let parts = activity.name.split(separator: ":", maxSplits: 1)
                return parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces) : nil
            }.first
            if let chapter = activities.first(where: { firstMatch(fold($0.name), #"^0*(\d{1,2})[-_ ]"#) != nil }) {
                title = prettifyFileName(chapter.name)
            } else {
                title = "Cours \(number)" + (named.map { " · \($0)" } ?? "")
            }
        } else if key.hasPrefix("d") {
            title = "Cours du \(key.dropFirst())"
        } else if key.hasPrefix("t") {
            title = String(key.dropFirst()).capitalizedFirst
        } else {
            // Un seul cours dans la semaine : son sujet est celui de la section
            // (« Semaine 4 : Types avancés »).
            let topic = sectionTitle.split(separator: ":", maxSplits: 1).dropFirst().first
                .map { $0.trimmingCharacters(in: .whitespaces) }
            title = topic.flatMap { $0.isEmpty ? nil : $0 } ?? (activities.count == 1 ? activities[0].name : "Cours")
        }
        var number: String
        if key.hasPrefix("n") {
            let raw = String(key.dropFirst())
            number = week > 0 && !raw.allSatisfy(\.isNumber) ? raw : (week > 0 && groups > 1 ? "\(week).\(index)" : raw)
        } else {
            number = week > 0 ? (groups > 1 ? "\(week).\(index)" : "\(week)") : "\(index)"
        }
        if number.isEmpty { number = "\(index)" }
        let primary = links.first { $0.kind == .notes } ?? links.first { $0.kind == .slides }
            ?? links.first { $0.kind == .pdf } ?? links.first
        var item = ContentDraftItem(kind: .theory,
                                    number: number,
                                    title: ContentDraftBuilder.cleanTitle(title),
                                    url: primary?.url ?? "",
                                    videoCount: links.filter { $0.kind == .video }.count,
                                    seriesNumber: nil,
                                    theoryKind: hasVideo ? .video : (links.contains { $0.kind == .slides } ? .slides : .reading))
        item.links = links
        return item
    }

    /// « 01-Systemes-lineaires » → « Systemes lineaires ».
    static func prettifyFileName(_ name: String) -> String {
        var text = name.replacingOccurrences(of: #"^0*\d{1,2}[-_ ]+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\.pdf$"#, with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return text.capitalizedFirst
    }

    static func link(for activity: MoodleActivity) -> ContentLink {
        let name = fold(activity.name)
        let target = fold(activity.link)
        let kind: ContentLink.Kind
        if matches(target, #"(mediaspace|youtube|youtu\.be|vimeo|tube\.switch|kaltura|video)"#)
            || matches(name, #"(recording|enregistrement|video|vodcast)"#) {
            kind = .video
        } else if isSolution(name) {
            kind = .solution
        } else if matches(name, #"(transparents?|slides?|diapos?)"#) || matches(target, #"slides?"#) {
            kind = .slides
        } else if matches(name, #"(notes?|annot|polycop)"#) {
            kind = .notes
        } else if activity.module == "resource" || target.hasSuffix(".pdf") {
            kind = .pdf
        } else {
            kind = .page
        }
        return ContentLink(title: ContentDraftBuilder.cleanTitle(activity.name), url: activity.link, kind: kind)
    }

    // MARK: Séries

    private static func seriesItem(_ number: Int, statement: [MoodleActivity], solution: [MoodleActivity]) -> ContentDraftItem {
        let main = statement.first
        let titleSource = main?.name ?? "Série \(number)"
        // « Problem Set 1: Motion in 1D » → le thème, « Motion in 1D ».
        let topic = titleSource.split(separator: ":", maxSplits: 1).dropFirst().first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        var item = ContentDraftItem(kind: .series,
                                    number: String(number),
                                    title: topic.isEmpty ? "Série \(number)" : ContentDraftBuilder.cleanTitle(topic),
                                    url: main?.link ?? "",
                                    videoCount: 0,
                                    seriesNumber: number,
                                    theoryKind: .reading)
        if let main {
            let target = fold(main.link)
            if main.module == "resource" || target.hasSuffix(".pdf") { item.pdfURL = main.link }
        }
        if let solution = solution.first { item.solutionURL = solution.link }
        item.links = (statement + solution.filter { s in !statement.contains(s) }).map(link(for:))
        return item
    }

    // MARK: Échéances

    private static func deadline(for activity: MoodleActivity, calendar: Calendar) -> ContentDraftItem {
        let name = fold(activity.name)
        let kind: ExamKind = matches(name, #"(projet|project)"#) ? .project : .assignment
        var title = ContentDraftBuilder.cleanTitle(activity.name)
        if matches(name, #"\ben groupe\b|\bgroup\b"#), !title.lowercased().contains("groupe") { title += " (en groupe)" }
        return deadline(title: title, date: activity.dueDate, kind: kind, url: activity.link)
    }

    private static func deadline(title: String, date: Date?, kind: ExamKind, url: String) -> ContentDraftItem {
        var item = ContentDraftItem(kind: .deadline, number: "", title: title, url: url, videoCount: 0,
                                    seriesNumber: nil, theoryKind: .reading)
        item.date = date
        item.examKind = kind
        return item
    }

    /// Dans une section « projet », ce qui a une date est une échéance
    /// (« Selection d'un groupe (DÉLAI 13.10, 18:00) ») ; le reste, un document.
    private static func projectDeadline(_ activity: MoodleActivity, section: String,
                                        termStart: Date?, calendar: Calendar) -> ContentDraftItem? {
        if activity.module == "assign" {
            var item = deadline(for: activity, calendar: calendar)
            item.examKind = .project
            return item
        }
        guard let date = shortDate(in: activity.name, termStart: termStart, calendar: calendar) else { return nil }
        let clean = ContentDraftBuilder.cleanTitle(activity.name)
            .replacingOccurrences(of: #"[⚠️]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\((?:délai|delai|deadline|due)[^)]*\)"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
        return deadline(title: "\(section) : \(clean)", date: date, kind: .project, url: activity.link)
    }

    /// « Examen Final (samedi 12.12, 09:00-12:00) » → le 12 décembre à 9 h.
    static func examDate(in title: String, termStart: Date?, calendar: Calendar) -> Date? {
        shortDate(in: title, termStart: termStart, calendar: calendar)
    }

    private static func examTitle(_ title: String) -> String {
        title.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Une date courte (« 12.12, 09:00 », « 13.10, 18:00 ») rapportée à
    /// l'année du semestre ; l'heure si elle est donnée.
    static func shortDate(in text: String, termStart: Date?, calendar: Calendar) -> Date? {
        guard let regex = try? NSRegularExpression(pattern: #"\b(\d{1,2})\.(\d{1,2})(?:\.(\d{2,4}))?\b(?:[^\d]{0,6}(\d{1,2})[:h](\d{2}))?"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ index: Int) -> Int? {
            Range(match.range(at: index), in: text).flatMap { Int(text[$0]) }
        }
        guard let day = group(1), let month = group(2), (1...31).contains(day), (1...12).contains(month) else { return nil }
        var year = group(3) ?? calendar.component(.year, from: termStart ?? Date())
        if year < 100 { year += 2000 }
        if group(3) == nil, let termStart {
            let startMonth = calendar.component(.month, from: termStart)
            if month < startMonth - 2 { year += 1 }
        }
        return calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                  hour: group(4) ?? 9, minute: group(5) ?? 0))
    }

    /// « Due: Friday, 2 October 2026, 11:59 PM », « À remettre : vendredi
    /// 2 octobre 2026, 23:59 » — l'échéance d'un devoir sur sa page.
    static func dueDate(fromActivityDates text: String) -> Date? {
        let lower = fold(text)
        guard let range = lower.range(of: #"(due|a remettre|echeance|date de remise|close[sd]?|ferme)\s*:?"#, options: .regularExpression) else { return nil }
        let tail = String(lower[range.upperBound...])
        guard let regex = try? NSRegularExpression(pattern: #"(\d{1,2})\s+([a-z]+)\.?\s+(\d{4})(?:[, ]+(?:a\s+)?(\d{1,2})[:h](\d{2})\s*(am|pm)?)?"#),
              let match = regex.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)) else { return nil }
        func string(_ index: Int) -> String? { Range(match.range(at: index), in: tail).map { String(tail[$0]) } }
        let months = ["janvier": 1, "january": 1, "fevrier": 2, "february": 2, "mars": 3, "march": 3, "avril": 4, "april": 4,
                      "mai": 5, "may": 5, "juin": 6, "june": 6, "juillet": 7, "july": 7, "aout": 8, "august": 8,
                      "septembre": 9, "september": 9, "octobre": 10, "october": 10, "novembre": 11, "november": 11,
                      "decembre": 12, "december": 12]
        guard let day = string(1).flatMap(Int.init), let month = string(2).flatMap({ months[$0] }),
              let year = string(3).flatMap(Int.init) else { return nil }
        var hour = string(4).flatMap(Int.init) ?? 23
        let minute = string(5).flatMap(Int.init) ?? 59
        if let meridiem = string(6) {
            if meridiem == "pm", hour < 12 { hour += 12 }
            if meridiem == "am", hour == 12 { hour = 0 }
        }
        return Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: TimeZone(identifier: "Europe/Zurich"),
                                                                          year: year, month: month, day: day,
                                                                          hour: hour, minute: minute))
    }

    // MARK: Anciens examens

    private static func pastExamItems(_ activities: [MoodleActivity]) -> [ContentDraftItem] {
        var exams: [(key: String, statement: MoodleActivity?, solution: MoodleActivity?)] = []
        for activity in activities where classify(activity, inWeek: false) != .ignore {
            let name = fold(activity.name)
            let key = firstMatch(name, #"\b(20\d{2}|19\d{2})\b"#) ?? name
            let isSol = isSolution(name)
            if let index = exams.firstIndex(where: { $0.key == key }) {
                if isSol { exams[index].solution = activity } else { exams[index].statement = activity }
            } else {
                exams.append((key, isSol ? nil : activity, isSol ? activity : nil))
            }
        }
        return exams.compactMap { exam in
            guard let main = exam.statement ?? exam.solution else { return nil }
            var item = ContentDraftItem(kind: .pastExam, number: exam.key.count == 4 ? exam.key : "",
                                        title: ContentDraftBuilder.cleanTitle(main.name), url: main.link, videoCount: 0,
                                        seriesNumber: nil, theoryKind: .reading)
            item.solutionURL = exam.solution?.link ?? ""
            return item
        }
    }

    // MARK: Documents

    private static func document(_ activity: MoodleActivity, section: String) -> ContentDraftItem {
        var item = ContentDraftItem(kind: .resource, number: "", title: ContentDraftBuilder.cleanTitle(activity.name),
                                    url: activity.link, videoCount: 0, seriesNumber: nil, theoryKind: .reading)
        item.links = [link(for: activity)]
        item.group = section
        return item
    }

    // MARK: Texte

    static func fold(_ text: String) -> String { ContentDraftBuilder.fold(text) }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func firstMatch(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func matchesAll(_ text: String, _ pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}

/// Un document d'un cours, gardé comme lien : ni théorie ni série.
struct CourseDocument: Codable, Equatable, Hashable, Identifiable {
    var title: String
    var url: String
    var group: String
    var kind: ContentLink.Kind

    var id: String { url + title }

    static func decodeList(_ raw: String) -> [CourseDocument] {
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([CourseDocument].self, from: data)) ?? []
    }

    static func encodeList(_ documents: [CourseDocument]) -> String {
        guard !documents.isEmpty, let data = try? JSONEncoder().encode(documents) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
