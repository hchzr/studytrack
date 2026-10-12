import SwiftUI
import SwiftData

/// Le cours, dans le bureau, en natif : ce que StudyTrack en sait (semaine
/// par semaine, avec ce qui est vu et fait), le plan Moodle en direct, et le
/// site Botafogo lu comme un livre — pages, séries, indications, solutions.
/// Les documents PDF s'ouvrent ici (PDFKit) ; seules les pages qu'on ne sait
/// pas lire passent par l'onglet Web.
struct CoursePane: View {
    let course: Course?
    var desk: StudyDesk
    var openWeb: (URL, String) -> Void

    enum Source: String, CaseIterable, Identifiable {
        case studytrack, moodle, botafogo
        var id: String { rawValue }
        var label: String {
            switch self {
            case .studytrack: return "Le cours"
            case .moodle: return "Moodle"
            case .botafogo: return "Botafogo"
            }
        }
    }

    @State private var source: Source = .studytrack
    /// Ce qu'on lit à droite.
    @State private var reading: Reading?
    @State private var book = BotafogoBook()

    enum Reading: Equatable {
        case pdf(title: String, address: String)
        case botafogo(title: String, url: String)
        case theory(UUID)
    }

    private var moodleID: Int? {
        guard let course else { return nil }
        return MoodleCourseMatcher.linkedID(in: course.contentSources + [course.moodleURLString])
    }

    private var botafogoURL: URL? {
        course?.contentSources.compactMap(URL.init(string:)).first { ContentSource.detect(host: $0.host) == .botafogo }
    }

    private var sources: [Source] {
        Source.allCases.filter { $0 == .studytrack || ($0 == .moodle && moodleID != nil) || ($0 == .botafogo && botafogoURL != nil) }
    }

    var body: some View {
        if let course {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if sources.count > 1 {
                        Picker("Source", selection: $source) {
                            ForEach(sources) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .padding(12)
                    }
                    switch source {
                    case .studytrack: studyTrackList(course)
                    case .moodle: moodleList(course)
                    case .botafogo: botafogoList
                    }
                }
                .frame(width: 320)
                #if DEBUG
                .onAppear {
                    if CommandLine.arguments.contains("-botafogo") { source = .botafogo }
                }
                .onChange(of: book.ready) { _, ready in
                    // `-botafogo` : ouvrir la première série du programme.
                    guard ready, CommandLine.arguments.contains("-botafogo"), case .ready(let weeks) = book.state else { return }
                    let node = weeks.flatMap { $0.children ?? [] }.first { $0.type == "series" && $0.url != nil }
                    if let node, let url = node.url { reading = .botafogo(title: node.displayName, url: url) }
                }
                #endif
                Rectangle().fill(Carnet.rule).frame(width: 1)
                reader(course)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ContentUnavailableView("Session libre", systemImage: "books.vertical",
                                   description: Text("Choisis un cours pour la session : son contenu s'ouvre ici."))
        }
    }

    // MARK: StudyTrack

    private func studyTrackList(_ course: Course) -> some View {
        let tint = Carnet.tint(course.colorHex)
        let weeks = Array(Set(course.sortedTheoryItems.map(\.plannedWeek) + course.sortedSeries.map(\.plannedWeek))).sorted {
            ($0 == 0 ? Int.max : $0) < ($1 == 0 ? Int.max : $1)
        }
        return ScrollViewReader { proxy in
            List {
                ForEach(weeks, id: \.self) { week in
                    Section {
                        ForEach(course.sortedTheoryItems.filter { $0.plannedWeek == week }) { item in
                            TheoryLine(item: item, tint: tint, selected: reading == .theory(item.id)) { open(item) }
                        }
                        ForEach(course.sortedSeries.filter { $0.plannedWeek == week && !$0.exercises.isEmpty }) { series in
                            Button {
                                if !series.urlString.isEmpty {
                                    reading = .pdf(title: series.title.isEmpty ? "Série \(series.seriesNumber)" : series.title, address: series.urlString)
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "list.number").foregroundStyle(tint).frame(width: 18)
                                    Text(series.title.isEmpty ? "Série \(series.seriesNumber)" : series.title).foregroundStyle(Carnet.ink)
                                    Spacer()
                                    Text("\(series.doneCount)/\(series.requiredExercises.count)").font(.caption.monospacedDigit())
                                        .foregroundStyle(Carnet.inkSecondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        HStack {
                            Text(week > 0 ? "Semaine \(week)" : "Documents").font(Carnet.serif(.headline)).foregroundStyle(Carnet.ink)
                            if week == course.currentWeek { Kicker("en cours", color: tint) }
                        }
                        .id(week)
                    }
                }
                if !course.documents.isEmpty {
                    Section("Documents du cours") {
                        ForEach(course.documents) { document in
                            Button { openLink(document.url, title: document.title, kind: document.kind) } label: {
                                Label(document.title, systemImage: document.kind.icon).foregroundStyle(Carnet.ink)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .onAppear { proxy.scrollTo(course.currentWeek, anchor: .top) }
        }
    }

    private func open(_ item: TheoryItem) {
        reading = .theory(item.id)
    }

    /// Un lien du cours : un PDF s'ouvre ici, une page dans l'onglet Web.
    private func openLink(_ address: String, title: String, kind: ContentLink.Kind? = nil) {
        guard let url = URL(string: address), url.scheme?.hasPrefix("http") == true else { return }
        if Self.isDocument(url) || kind == .pdf || kind == .slides || kind == .notes || kind == .solution {
            reading = .pdf(title: title, address: address)
        } else {
            openWeb(url, title)
        }
    }

    static func isDocument(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return path.hasSuffix(".pdf") || path.contains("/pluginfile.php/") || path.contains("/mod/resource/")
    }

    // MARK: Moodle

    @ViewBuilder
    private func moodleList(_ course: Course) -> some View {
        if let id = moodleID {
            if let outline = desk.moodleOutlines[id] {
                List {
                    ForEach(outline.sections.filter { !$0.activities.isEmpty }, id: \.number) { section in
                        Section {
                            ForEach(section.activities.filter(\.isVisible), id: \.id) { activity in
                                Button { openActivity(activity) } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: Self.icon(for: activity.module)).foregroundStyle(Carnet.tint(course.colorHex)).frame(width: 18)
                                        Text(activity.name).foregroundStyle(Carnet.ink).lineLimit(2)
                                        Spacer(minLength: 0)
                                        if activity.module != "resource" {
                                            Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(Carnet.inkTertiary)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            Text(MoodleCourseAnalyzer.sectionTitle(section)).font(Carnet.serif(.headline)).foregroundStyle(Carnet.ink)
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            } else if let error = desk.moodleError[id] {
                VStack(spacing: 12) {
                    Text(error).foregroundStyle(Carnet.inkSecondary).multilineTextAlignment(.center)
                    Button("Se connecter à Moodle") { openWeb(MoodleClient.login, "Moodle") }.buttonStyle(.ink)
                    Button("Réessayer") { loadMoodle(id, course: course) }.buttonStyle(.paper)
                }
                .padding(20)
                .frame(maxHeight: .infinity)
            } else {
                ProgressView("Plan Moodle…")
                    .frame(maxHeight: .infinity)
                    .onAppear { loadMoodle(id, course: course) }
            }
        }
    }

    private func loadMoodle(_ id: Int, course: Course) {
        desk.moodleError[id] = nil
        Task { @MainActor in
            do {
                desk.moodleOutlines[id] = try await desk.moodle.outline(courseID: id, title: course.name)
            } catch {
                desk.moodleError[id] = (error as? HiddenSiteSession.SiteError).map { _ in
                    "Moodle ne répond pas, ou il faut te connecter (une fois, dans l'onglet Web)."
                } ?? error.localizedDescription
            }
        }
    }

    private func openActivity(_ activity: MoodleActivity) {
        if activity.module == "resource" {
            reading = .pdf(title: activity.name, address: activity.link)
        } else if let url = URL(string: activity.link) {
            openWeb(url, activity.name)
        }
    }

    static func botafogoIcon(_ type: String) -> String {
        switch type {
        case "series": return "list.number"
        case "session": return "person.2"
        case "weekContent": return "calendar"
        default: return "book.pages"
        }
    }

    static func icon(for module: String) -> String {
        switch module {
        case "resource": return "doc.richtext"
        case "folder": return "folder"
        case "url": return "link"
        case "page": return "doc.text"
        case "assign": return "tray.and.arrow.up"
        case "forum": return "bubble.left.and.bubble.right"
        case "quiz": return "checklist"
        default: return "square.grid.2x2"
        }
    }

    // MARK: Botafogo

    @ViewBuilder
    private var botafogoList: some View {
        if let url = botafogoURL {
            switch book.state {
            case .ready(let weeks):
                List {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                        Section {
                            ForEach(Array((week.children ?? []).enumerated()), id: \.offset) { _, node in
                                if let address = node.url {
                                    Button { reading = .botafogo(title: node.displayName, url: address) } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: Self.botafogoIcon(node.type))
                                                .foregroundStyle(Carnet.tint(course?.colorHex ?? "")).frame(width: 18)
                                            MacMathText(node.displayName, size: 13).foregroundStyle(Carnet.ink).lineLimit(2)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        } header: {
                            MacMathText(week.name ?? "Semaine", size: 14, design: .serif).foregroundStyle(Carnet.ink)
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            case .failed(let message):
                VStack(spacing: 10) {
                    Text(message).foregroundStyle(Carnet.inkSecondary)
                    Button("Ouvrir le site") { openWeb(url, "Botafogo") }.buttonStyle(.paper)
                }
                .frame(maxHeight: .infinity)
            case .idle, .loading:
                ProgressView("Programme Botafogo…")
                    .frame(maxHeight: .infinity)
                    .task { await book.load(url) }
            }
        }
    }

    // MARK: Lecture

    @ViewBuilder
    private func reader(_ course: Course) -> some View {
        switch reading {
        case .pdf(let title, let address)?:
            VStack(spacing: 0) {
                readerHeader(title, address: address)
                switch desk.document(address) {
                case .ready(let file)?:
                    PDFPane(url: file)
                case .needsLogin?:
                    VStack(spacing: 10) {
                        Text("Ce document est sur Moodle : connecte-toi une fois.").foregroundStyle(Carnet.inkSecondary)
                        HStack {
                            Button("Se connecter") { openWeb(MoodleClient.login, "Moodle") }.buttonStyle(.ink)
                            Button("Réessayer") { desk.retry(address) }.buttonStyle(.paper)
                        }
                    }
                    .frame(maxHeight: .infinity)
                case .failed(let message)?:
                    VStack(spacing: 10) {
                        Text(message).foregroundStyle(Carnet.inkSecondary)
                        if let url = URL(string: address) { Button("Ouvrir la page") { openWeb(url, title) }.buttonStyle(.paper) }
                    }
                    .frame(maxHeight: .infinity)
                case .loading?, nil:
                    ProgressView().frame(maxHeight: .infinity).onAppear { desk.loadPDF(address) }
                }
            }
            .id(address)
        case .botafogo(let title, let url)?:
            BotafogoReader(book: book, title: title, url: url, desk: desk, openWeb: openWeb)
                .id(url)
        case .theory(let id)?:
            if let item = course.theoryItems.first(where: { $0.id == id }) {
                TheoryDetail(item: item, tint: Carnet.tint(course.colorHex), openLink: { openLink($0, title: $1, kind: $2) })
            }
        case nil:
            ContentUnavailableView {
                Label(course.name, systemImage: "books.vertical")
            } description: {
                Text("Choisis une vidéo, une section, une série : elle s'ouvre ici.")
            }
        }
    }

    private func readerHeader(_ title: String, address: String) -> some View {
        HStack {
            Text(title).font(Carnet.serif(.title3)).foregroundStyle(Carnet.ink).lineLimit(1)
            Spacer()
            Button { desk.ask("J'ai une question sur ce document (« \(title) »).", attachSeries: false) } label: {
                Label("Demander à Claude", systemImage: "sparkle")
            }
            .buttonStyle(.paper)
            if let url = URL(string: address) {
                Button { openWeb(url, title) } label: { Image(systemName: "globe") }
                    .buttonStyle(.paper)
                    .help("Ouvrir dans l'onglet Web")
            }
        }
        .padding(12)
    }
}

private struct TheoryLine: View {
    @Bindable var item: TheoryItem
    let tint: Color
    let selected: Bool
    var open: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                item.watchedAt = item.isWatched ? nil : Date()
            } label: {
                Image(systemName: item.isWatched ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isWatched ? tint : Carnet.inkTertiary)
            }
            .buttonStyle(.plain)
            Button(action: open) {
                HStack(spacing: 6) {
                    Image(systemName: item.kind.icon).foregroundStyle(tint).frame(width: 16)
                    Text(item.title.isEmpty ? item.kind.label : item.numberAndTitle)
                        .foregroundStyle(item.isWatched ? Carnet.inkSecondary : Carnet.ink)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        .listRowBackground(selected ? tint.opacity(0.12) : Color.clear)
    }
}

/// Une vidéo, une section : ses liens, son résumé, le cocher.
private struct TheoryDetail: View {
    @Bindable var item: TheoryItem
    let tint: Color
    var openLink: (String, String, ContentLink.Kind?) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Kicker([item.kind.label, item.plannedWeek > 0 ? "semaine \(item.plannedWeek)" : nil].compactMap { $0 }.joined(separator: " · "), color: tint)
                Text(item.title.isEmpty ? item.kind.label : item.numberAndTitle).font(Carnet.serif(30)).foregroundStyle(Carnet.ink)
                Toggle("Vu", isOn: Binding(get: { item.isWatched }, set: { item.watchedAt = $0 ? (item.watchedAt ?? Date()) : nil }))
                    .toggleStyle(.checkbox)
                if let summary = item.summaryText, !summary.isEmpty {
                    RichTextView(text: summary, size: 15)
                }
                VStack(alignment: .leading, spacing: 8) {
                    if !item.urlString.isEmpty {
                        Button { openLink(item.urlString, item.title, nil) } label: {
                            Label(item.kind.label + " — ouvrir", systemImage: item.kind.icon)
                        }
                        .buttonStyle(.ink)
                    }
                    ForEach(item.links, id: \.url) { link in
                        Button { openLink(link.url, link.title, link.kind) } label: { Label(link.title, systemImage: link.kind.icon) }
                            .buttonStyle(.paper)
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Botafogo

/// Le site Botafogo d'un cours, lu en natif : le programme (semaines, cours,
/// séries) et chaque document (`/api/content/node`).
@MainActor
@Observable
final class BotafogoBook {
    enum State {
        case idle, loading
        case ready([BotafogoNode])
        case failed(String)
    }

    private(set) var state: State = .idle {
        didSet { if case .ready = state { ready = true } }
    }
    private(set) var ready = false
    private(set) var root: URL?
    private var nodes: [String: [String: Any]] = [:]

    func load(_ url: URL) async {
        if case .ready = state { return }
        state = .loading
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let html = String(decoding: data, as: UTF8.self)
            let root = BotafogoParser.siteRoot(html: html, pageURL: url)
            self.root = root
            if let program = await BotafogoClient.program(html: html, root: root, session: .shared), !program.isEmpty {
                state = .ready(program.filter { $0.type == "week" })
            } else {
                state = .failed("Ce site Botafogo ne publie pas de programme lisible.")
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Le corps d'un document du site.
    func body(of url: String) async -> [String: Any]? {
        if let cached = nodes[url] { return cached }
        guard let root else { return nil }
        let path = BotafogoProgram.contentPath(url).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url
        guard let address = URL(string: root.absoluteString + "api/content/node?collection=content&path=" + path),
              let (data, _) = try? await URLSession.shared.data(from: address),
              let body = BotafogoDocument.body(fromNodeJSON: data) else { return nil }
        nodes[url] = body
        return body
    }

    func pageURL(_ url: String) -> URL? {
        root.flatMap { URL(string: BotafogoProgram.pageURL(root: $0, url: url)) }
    }

    func assetURL(_ source: String) -> URL? {
        if source.hasPrefix("http") { return URL(string: source) }
        guard let root else { return nil }
        return URL(string: source.hasPrefix("/") ? (root.scheme ?? "https") + "://" + (root.host ?? "") + source : root.absoluteString + source)
    }
}

/// Un document Botafogo rendu nativement : titres, paragraphes et formules,
/// listes, figures, vidéos, environnements (théorème, définition…), et pour
/// une série chaque exercice avec son indication et sa solution repliées.
private struct BotafogoReader: View {
    var book: BotafogoBook
    let title: String
    let url: String
    var desk: StudyDesk
    var openWeb: (URL, String) -> Void

    @State private var blocks: [ReaderBlock]?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(Carnet.serif(.title3)).foregroundStyle(Carnet.ink).lineLimit(1)
                Spacer()
                Button { desk.ask("J'ai une question sur « \(title) » (Botafogo).", attachSeries: false) } label: {
                    Label("Demander à Claude", systemImage: "sparkle")
                }
                .buttonStyle(.paper)
                if let page = book.pageURL(url) {
                    Button { openWeb(page, title) } label: { Image(systemName: "globe") }
                        .buttonStyle(.paper)
                        .help("La page sur le site (figures interactives)")
                }
            }
            .padding(12)
            if let blocks {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(title).font(Carnet.serif(30)).foregroundStyle(Carnet.ink)
                        ReaderBlocks(blocks: blocks, book: book, openWeb: openWeb)
                    }
                    .padding(32)
                    .frame(maxWidth: 780, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            } else {
                ProgressView().frame(maxHeight: .infinity)
            }
        }
        .task {
            guard let body = await book.body(of: url) else { blocks = []; return }
            blocks = ReaderBlock.parse(body)
        }
    }
}

/// Un morceau de document Botafogo (Nuxt Content, « minimark »).
indirect enum ReaderBlock: Equatable {
    case text(String)
    case image(String)
    case video(id: String, title: String)
    case box(title: String, [ReaderBlock])
    case folded(title: String, [ReaderBlock])

    /// L'arbre → des blocs. Le texte devient du Markdown léger, les formules
    /// gardent leur LaTeX entre `$…$` (`RichTextView` les met en forme).
    static func parse(_ node: [String: Any]) -> [ReaderBlock] {
        var blocks: [ReaderBlock] = []
        var paragraph = ""
        func flush() {
            let text = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.text(text)) }
            paragraph = ""
        }
        for child in children(node) {
            let tag = child["tagName"] as? String ?? ""
            let properties = child["properties"] as? [String: Any] ?? [:]
            if (child["type"] as? String) == "text" {
                paragraph += child["value"] as? String ?? ""
                continue
            }
            switch tag {
            case "h1", "h2", "h3", "h4":
                flush()
                let level = Int(tag.dropFirst()) ?? 2
                blocks.append(.text(String(repeating: "#", count: min(level + 1, 4)) + " " + BotafogoDocument.text(of: child).trimmingCharacters(in: .whitespaces)))
            case "p":
                flush()
                blocks.append(.text(inline(child)))
            case "ul", "ol":
                flush()
                let items = children(child).filter { ($0["tagName"] as? String) == "li" }
                let lines = items.enumerated().map { index, item in
                    (tag == "ol" ? "\(index + 1). " : "- ") + inline(item)
                }
                blocks.append(.text(lines.joined(separator: "\n")))
            case "katex-renderer":
                let content = BotafogoDocument.simplifyMath(properties["content"] as? String ?? "")
                if (properties["displayMode"] as? Bool) == true || (properties["display"] as? Bool) == true {
                    flush()
                    blocks.append(.text("$$" + content + "$$"))
                } else {
                    paragraph += "$" + content + "$"
                }
            case "img":
                flush()
                if let source = properties["src"] as? String { blocks.append(.image(source)) }
            case "videokaltura":
                flush()
                if let id = properties["entryId"] as? String {
                    blocks.append(.video(id: id, title: (properties["title"] as? String) ?? "Vidéo"))
                }
            case "solution", "indication", "proof", "preuve":
                flush()
                let title = ["solution": "Solution", "indication": "Indication", "proof": "Preuve", "preuve": "Preuve"][tag] ?? tag
                blocks.append(.folded(title: title, parse(content(child))))
            case "exercise":
                flush()
                blocks.append(.box(title: "Exercice", parse(content(child))))
            case "theorem", "theoreme", "definition", "proposition", "lemma", "lemme", "corollary", "corollaire", "remark", "remarque", "example", "exemple":
                flush()
                let names = ["theorem": "Théorème", "theoreme": "Théorème", "definition": "Définition", "proposition": "Proposition",
                             "lemma": "Lemme", "lemme": "Lemme", "corollary": "Corollaire", "corollaire": "Corollaire",
                             "remark": "Remarque", "remarque": "Remarque", "example": "Exemple", "exemple": "Exemple"]
                blocks.append(.box(title: (properties["title"] as? String).map { "\(names[tag] ?? tag) — \($0)" } ?? (names[tag] ?? tag),
                                   parse(content(child))))
            case "br":
                paragraph += "\n"
            case "b", "strong":
                paragraph += "**" + BotafogoDocument.text(of: child).trimmingCharacters(in: .whitespaces) + "** "
            case "jsxgraph":
                flush()
                blocks.append(.text("*Figure interactive : ouvre la page sur le site pour la manipuler.*"))
            default:
                // Un conteneur (div, template, multicols…) : on lit dedans.
                let inner = parse(content(child))
                if inner.isEmpty {
                    paragraph += BotafogoDocument.text(of: child)
                } else {
                    flush()
                    blocks += inner
                }
            }
        }
        flush()
        return blocks
    }

    private static func children(_ node: [String: Any]) -> [[String: Any]] {
        (node["children"] as? [[String: Any]]) ?? []
    }

    /// Le contenu d'un élément à gabarit (`template` → `content`), sinon l'élément.
    private static func content(_ element: [String: Any]) -> [String: Any] {
        if let content = element["content"] as? [String: Any] { return content }
        for child in children(element) where (child["tagName"] as? String) == "template" {
            if let content = child["content"] as? [String: Any] { return content }
        }
        return element
    }

    /// Une ligne : texte, gras, formules en ligne.
    private static func inline(_ node: [String: Any]) -> String {
        var text = ""
        for child in children(node) {
            if (child["type"] as? String) == "text" { text += child["value"] as? String ?? ""; continue }
            switch child["tagName"] as? String {
            case "b", "strong": text += "**" + inline(child).trimmingCharacters(in: .whitespaces) + "**"
            case "em", "i": text += "*" + inline(child).trimmingCharacters(in: .whitespaces) + "*"
            case "br": text += " "
            default: text += BotafogoDocument.text(of: child)
            }
        }
        return text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

private struct ReaderBlocks: View {
    let blocks: [ReaderBlock]
    var book: BotafogoBook
    var openWeb: (URL, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(block)
            }
        }
    }

    @ViewBuilder
    private func view(_ block: ReaderBlock) -> some View {
        switch block {
        case .text(let markdown):
            RichTextView(text: markdown, size: 15)
        case .image(let source):
            if let url = book.assetURL(source) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit().frame(maxHeight: 360)
                } placeholder: {
                    ProgressView()
                }
                .frame(maxWidth: .infinity)
            }
        case .video(let id, let title):
            Button {
                if let url = URL(string: "https://mediaspace.epfl.ch/media/t/\(id)") { openWeb(url, title) }
            } label: {
                Label(title, systemImage: "play.rectangle.fill")
            }
            .buttonStyle(.paper)
        case .box(let title, let inner):
            VStack(alignment: .leading, spacing: 8) {
                Kicker(title)
                ReaderBlocks(blocks: inner, book: book, openWeb: openWeb)
            }
            .paperSheet(padding: 16)
        case .folded(let title, let inner):
            DisclosureGroup {
                ReaderBlocks(blocks: inner, book: book, openWeb: openWeb).padding(.top, 6)
            } label: {
                Text(title).font(.callout.weight(.semibold)).foregroundStyle(Carnet.inkSecondary)
            }
            .padding(12)
            .background(Carnet.sheetRaised.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}
