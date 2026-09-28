import SwiftUI
import SwiftData
import WebKit

/// « Importer du contenu » : d'où vient la théorie et les séries d'un cours.
///
/// Un seul point d'entrée pour tout ce qui remplit un cours. On choisit la
/// source, on se connecte si elle l'exige, on ouvre la page du cours, et l'app
/// propose un plan semaine par semaine à relire. Rien n'est écrit avant « Importer ».
struct ContentImportView: View {
    /// Le cours à remplir. `nil` depuis l'onglet Cours : la relecture propose
    /// le cours qui correspond à la page, ou d'en créer un.
    var course: Course?

    @Environment(\.dismiss) private var dismiss
    @State private var path: [Route] = []
    @State private var showingSeriesPDF = false
    @State private var showingFileImport = false

    enum Route: Hashable {
        case browser(ContentSource, URL?)
        case botafogo
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let course, !course.contentSources.isEmpty {
                    Section {
                        ForEach(course.contentSources, id: \.self) { link in
                            if let url = URL(string: link), let source = ContentSource.detect(host: url.host) {
                                Button {
                                    path.append(source == .botafogo ? .botafogo : .browser(source, url))
                                } label: {
                                    sourceRow(icon: "arrow.triangle.2.circlepath",
                                              title: "Mettre à jour depuis \(source.label)",
                                              detail: "Ajoute ce qui est nouveau, garde ton avancement")
                                }
                            }
                        }
                    } header: {
                        Text("Déjà importé")
                    }
                }

                Section {
                    ForEach(ContentSource.allCases) { source in
                        Button {
                            path.append(source == .botafogo ? .botafogo : .browser(source, nil))
                        } label: {
                            sourceRow(icon: source.icon, title: source.label, detail: source.detail)
                        }
                    }
                } header: {
                    Text("Depuis le site du cours")
                } footer: {
                    Text("Moodle et Courseware s'ouvrent ici : connecte-toi avec ton compte EPFL (une seule fois), ouvre le cours, puis touche « Importer cette page ». L'EPFL n'offre pas d'accès API : l'app lit la page, rien ne quitte ton téléphone.")
                }

                Section {
                    Button {
                        showingSeriesPDF = true
                    } label: {
                        sourceRow(icon: "doc.text.magnifyingglass", title: "Une série en PDF",
                                  detail: "Exercices et sous-questions lus dans l'énoncé")
                    }
                    Button {
                        showingFileImport = true
                    } label: {
                        sourceRow(icon: "square.and.arrow.down", title: "Horaire ou fichier",
                                  detail: "Horaire .ics d'IS-Academia, sauvegarde JSON, CSV")
                    }
                } header: {
                    Text("Autres imports")
                }
            }
            .navigationTitle(course.map { "Importer · \($0.displayCode)" } ?? "Importer du contenu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .browser(let source, let start):
                    WebImportBrowser(source: source, startURL: start, course: course, onDone: { dismiss() })
                case .botafogo:
                    BotafogoPicker(course: course, onDone: { dismiss() })
                }
            }
            .sheet(isPresented: $showingSeriesPDF) {
                SeriesImportSheet(course: course)
            }
            .sheet(isPresented: $showingFileImport) {
                ImportSheet()
            }
        }
    }

    private func sourceRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: Layout.block) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(Theme.accentInk)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: Layout.micro) {
                Text(title).font(.body).foregroundStyle(.primary)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: Layout.inline)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Navigateur intégré

/// Moodle ou Courseware, dans la session de l'étudiant·e.
///
/// Les cookies vivent dans le magasin **persistant** de WebKit : on se connecte
/// une fois, les imports suivants ouvrent directement la page.
struct WebImportBrowser: View {
    let source: ContentSource
    var startURL: URL?
    var course: Course?
    var onDone: () -> Void

    @StateObject private var model = BrowserModel()
    @State private var isReading = false
    @State private var errorMessage: String?
    @State private var draft: ContentDraft?

    var body: some View {
        VStack(spacing: 0) {
            WebView(model: model, initialURL: startURL ?? source.homeURL)
                .overlay(alignment: .top) {
                    if model.isLoading {
                        ProgressView(value: model.progress)
                            .progressViewStyle(.linear)
                            .tint(Theme.accent)
                    }
                }
            bottomBar
        }
        .navigationTitle(source.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { model.webView?.goBack() } label: { Image(systemName: "chevron.backward") }
                    .disabled(!model.canGoBack)
                    .accessibilityLabel("Page précédente")
                Button { model.webView?.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Recharger")
            }
        }
        .navigationDestination(item: $draft) { draft in
            ContentReviewView(draft: draft, course: course, onDone: onDone)
        }
    }

    private var isCoursePage: Bool { WebContentScraper.isCoursePage(model.url, source: source) }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: Layout.inline) {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.orange.accessibleInk)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(isCoursePage
                     ? "Page de cours détectée."
                     : (source.requiresLogin ? "Connecte-toi si besoin, puis ouvre la page du cours." : "Ouvre le cours à importer."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await read() }
            } label: {
                HStack {
                    if isReading { ProgressView().tint(.white) }
                    Text(isReading ? "Lecture de la page…" : "Importer cette page")
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, Layout.control)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isCoursePage || isReading)
        }
        .padding(Layout.gutter)
        .background(.bar)
    }

    @MainActor
    private func read() async {
        guard let webView = model.webView else { return }
        isReading = true
        errorMessage = nil
        defer { isReading = false }
        do {
            let page = try await WebContentScraper.scrape(webView, source: source)
            let built = ContentDraftBuilder.draft(from: page,
                                                  source: source,
                                                  termStart: course?.term?.startDate,
                                                  totalWeeks: course?.term?.totalWeeks ?? 14)
            guard !built.isEmpty else { throw WebContentScraper.ScrapeError.empty }
            Haptics.success()
            draft = built
        } catch {
            Haptics.error()
            errorMessage = error.localizedDescription
        }
    }
}

/// L'état du `WKWebView`, observé par SwiftUI.
@MainActor
final class BrowserModel: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var url: URL?
    @Published var isLoading = false
    @Published var progress: Double = 0
    @Published var canGoBack = false
    private(set) weak var webView: WKWebView?
    private var observations: [NSKeyValueObservation] = []

    func attach(_ view: WKWebView) {
        webView = view
        view.navigationDelegate = self
        observations = [
            view.observe(\.url) { [weak self] view, _ in Task { @MainActor in self?.url = view.url } },
            view.observe(\.isLoading) { [weak self] view, _ in Task { @MainActor in self?.isLoading = view.isLoading } },
            view.observe(\.estimatedProgress) { [weak self] view, _ in Task { @MainActor in self?.progress = view.estimatedProgress } },
            view.observe(\.canGoBack) { [weak self] view, _ in Task { @MainActor in self?.canGoBack = view.canGoBack } }
        ]
    }
}

private struct WebView: UIViewRepresentable {
    let model: BrowserModel
    let initialURL: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        model.attach(view)
        view.load(URLRequest(url: initialURL))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - Botafogo

/// Les polycopiés de Botafogo, lus directement : pas de connexion.
struct BotafogoPicker: View {
    var course: Course?
    var onDone: () -> Void

    @State private var catalog: [(title: String, url: URL)] = []
    @State private var loadingURL: URL?
    @State private var isLoadingCatalog = true
    @State private var errorMessage: String?
    @State private var draft: ContentDraft?

    var body: some View {
        List {
            Section {
                if isLoadingCatalog {
                    HStack { ProgressView(); Text("Lecture de botafogo.epfl.ch…").foregroundStyle(.secondary) }
                }
                ForEach(catalog, id: \.url) { entry in
                    Button {
                        Task { await open(entry.url) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: Layout.micro) {
                                Text(entry.title).foregroundStyle(.primary)
                                Text(entry.url.path).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if loadingURL == entry.url { ProgressView() }
                        }
                    }
                    .disabled(loadingURL != nil)
                }
            } header: {
                Text("Polycopiés en ligne")
            } footer: {
                Text("Chaque section du polycopié devient un élément de théorie, avec ses vidéos. Les chapitres sont proposés une semaine chacun : ajuste-les avant d'importer.")
            }
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.orange.accessibleInk)
                }
            }
        }
        .navigationTitle("Botafogo")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadCatalog() }
        .navigationDestination(item: $draft) { draft in
            ContentReviewView(draft: draft, course: course, onDone: onDone)
        }
    }

    private func loadCatalog() async {
        guard catalog.isEmpty else { return }
        defer { isLoadingCatalog = false }
        do {
            catalog = try await BotafogoClient.catalog()
            if catalog.isEmpty { errorMessage = "Aucun polycopié trouvé sur la page d'accueil." }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func open(_ url: URL) async {
        loadingURL = url
        errorMessage = nil
        defer { loadingURL = nil }
        do {
            let page = try await BotafogoClient.course(at: url)
            draft = ContentDraftBuilder.draft(from: page,
                                              source: .botafogo,
                                              termStart: course?.term?.startDate,
                                              totalWeeks: course?.term?.totalWeeks ?? 14)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension ContentDraft: Hashable, Identifiable {
    var id: String { url + courseTitle }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Relecture

/// Le plan proposé, semaine par semaine, à corriger avant d'écrire.
struct ContentReviewView: View {
    @State var draft: ContentDraft
    var course: Course?
    var onDone: () -> Void

    @Environment(\.modelContext) private var context
    @Query(sort: \Course.code) private var courses: [Course]
    /// Le cours cible ; `nil` = en créer un à partir du titre de la page.
    @State private var targetID: UUID?
    @State private var hasPickedTarget = false
    @State private var result: ContentImportResult?

    private var totalWeeks: Int { target?.term?.totalWeeks ?? course?.term?.totalWeeks ?? 14 }
    private var target: Course? { courses.first { $0.id == targetID } }

    var body: some View {
        List {
            summarySection
            if course == nil { targetSection }
            ForEach($draft.sections) { $section in
                sectionView($section)
            }
        }
        .navigationTitle("Relecture")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { importBar }
        .onAppear(perform: pickTarget)
        .alert("Import terminé", isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil; onDone() } })) {
            Button("OK") { result = nil; onDone() }
        } message: {
            Text(result?.message ?? "")
        }
    }

    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: Layout.tight) {
                Text(draft.courseTitle.isEmpty ? draft.source.label : draft.courseTitle)
                    .font(.headline)
                Text(summaryLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.vertical, Layout.tight)
        } footer: {
            Text(draft.sections.contains(where: \.weekIsInferred)
                 ? "Les semaines marquées « proposée » n'étaient pas écrites sur la page : vérifie-les. Rien n'est supprimé à l'import, et ton avancement est gardé."
                 : "Semaines lues sur la page. Rien n'est supprimé à l'import, et ton avancement est gardé.")
        }
    }

    private var summaryLine: String {
        var parts = ["\(draft.theoryCount) théorie"]
        if draft.videoCount > 0 { parts.append("\(draft.videoCount) vidéo\(draft.videoCount > 1 ? "s" : "")") }
        parts.append("\(draft.seriesCount) série\(draft.seriesCount > 1 ? "s" : "")")
        return parts.joined(separator: " · ")
    }

    private var targetSection: some View {
        Section("Dans le cours") {
            Picker("Cours", selection: $targetID) {
                Text("Nouveau cours « \(shortTitle) »").tag(UUID?.none)
                ForEach(courses.filter(\.isTracked)) { course in
                    Text("\(course.displayCode) — \(course.name)").tag(UUID?.some(course.id))
                }
            }
        }
    }

    private var shortTitle: String {
        let title = draft.courseTitle
        return title.count > 32 ? String(title.prefix(30)) + "…" : title
    }

    private func sectionView(_ section: Binding<ContentDraftSection>) -> some View {
        Section {
            if section.wrappedValue.isIncluded {
                ForEach(section.items) { $item in
                    itemRow($item)
                }
            }
        } header: {
            VStack(alignment: .leading, spacing: Layout.snug) {
                HStack(alignment: .firstTextBaseline) {
                    Toggle(isOn: section.isIncluded) {
                        MathText(section.wrappedValue.title.isEmpty ? "Sans titre" : section.wrappedValue.title,
                                 font: .subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .textCase(nil)
                    }
                    .toggleStyle(CheckToggleStyle())
                }
                if section.wrappedValue.isIncluded {
                    weekMenu(section)
                }
            }
            .padding(.vertical, Layout.tight)
        }
    }

    private func weekMenu(_ section: Binding<ContentDraftSection>) -> some View {
        Menu {
            Picker("Semaine", selection: section.week) {
                Text("Non planifié").tag(0)
                ForEach(1...max(totalWeeks, section.wrappedValue.week), id: \.self) { week in
                    Text("Semaine \(week)").tag(week)
                }
            }
        } label: {
            HStack(spacing: Layout.tight) {
                Image(systemName: "calendar")
                Text(section.wrappedValue.week == 0 ? "Non planifié" : "Semaine \(section.wrappedValue.week)")
                if section.wrappedValue.weekIsInferred {
                    Text("proposée").foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .font(.footnote.weight(.medium))
            .textCase(nil)
        }
        .onChange(of: section.wrappedValue.week) { _, _ in
            section.wrappedValue.weekIsInferred = false
        }
    }

    private func itemRow(_ item: Binding<ContentDraftItem>) -> some View {
        let value = item.wrappedValue
        return HStack(spacing: Layout.block) {
            Image(systemName: value.kind == .series ? TaskType.exercise.icon : value.theoryKind.icon)
                .foregroundStyle(value.kind == .ignore ? Color.secondary : (value.kind == .series ? TaskType.exercise.tint : TaskType.theory.tint).accessibleMark)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: Layout.micro) {
                MathText(value.kind == .series ? "Série \(value.number)" : "\(value.number) · \(value.title)",
                         font: .subheadline)
                    .foregroundStyle(value.kind == .ignore ? .secondary : .primary)
                    .lineLimit(2)
                if value.kind == .series, value.title != "Série \(value.number)" {
                    Text(value.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if value.kind == .theory, value.videoCount > 0 {
                    Text("\(value.videoCount) vidéo\(value.videoCount > 1 ? "s" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: Layout.inline)
            Menu {
                Picker("Type", selection: item.kind) {
                    ForEach(ContentItemKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
            } label: {
                Text(value.kind.label)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, Layout.inline)
                    .padding(.vertical, Layout.tight)
                    .background(Color(.tertiarySystemFill), in: Capsule())
            }
            .onChange(of: item.wrappedValue.kind) { _, kind in
                if kind == .series, item.wrappedValue.seriesNumber == nil {
                    item.wrappedValue.seriesNumber = ContentDraftBuilder.seriesNumber(in: item.wrappedValue.title)
                        ?? Int(item.wrappedValue.number.split(separator: ".").last ?? "") ?? 1
                    item.wrappedValue.number = String(item.wrappedValue.seriesNumber ?? 1)
                }
            }
        }
    }

    private var importBar: some View {
        Button {
            apply()
        } label: {
            Text(draft.isEmpty ? "Rien à importer" : "Importer \(summaryLine)")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, Layout.control)
        }
        .buttonStyle(.borderedProminent)
        .disabled(draft.isEmpty)
        .padding(Layout.gutter)
        .background(.bar)
    }

    private func pickTarget() {
        guard !hasPickedTarget else { return }
        hasPickedTarget = true
        if let course { targetID = course.id; return }
        // Le code EPFL écrit dans le titre de la page (« MATH-101 »), sinon le nom.
        let title = ContentDraftBuilder.fold(draft.courseTitle)
        targetID = courses.first { course in
            title.contains(ContentDraftBuilder.fold(course.code))
                || (!course.name.isEmpty && title.contains(ContentDraftBuilder.fold(course.name)))
        }?.id
    }

    private func apply() {
        let destination: Course
        if let target {
            destination = target
        } else if let course {
            destination = course
        } else {
            let code = draft.courseTitle.range(of: #"[A-Z]{2,5}-\d{3}"#, options: .regularExpression)
                .map { String(draft.courseTitle[$0]) } ?? ""
            let name = draft.courseTitle.replacingOccurrences(of: code, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: " ()-–·|"))
            let palette = Theme.coursePalette
            let created = Course(code: code.isEmpty ? String(name.prefix(8)).uppercased() : code,
                                 name: name.isEmpty ? draft.courseTitle : name,
                                 colorHex: palette[courses.count % palette.count],
                                 term: courses.compactMap(\.term).first)
            context.insert(created)
            destination = created
        }
        let outcome = ContentDraftWriter.apply(draft, to: destination, context: context)
        try? context.save()
        Haptics.success()
        result = outcome
    }
}

/// Une case à cocher de liste, plutôt qu'un interrupteur : on coche des
/// sections à importer, on n'allume pas un réglage.
struct CheckToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
            Haptics.soft()
        } label: {
            HStack(spacing: Layout.inline) {
                Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(configuration.isOn ? Theme.accentInk : Color.secondary)
                    .font(.title3)
                configuration.label
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "incluse" : "exclue")
    }
}
