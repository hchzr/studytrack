import SwiftUI
import WebKit

/// Ton compte Google pour NotebookLM : se connecter une fois, puis StudyTrack crée le carnet,
/// y dépose la fiche, lance le podcast et le rapporte ici.
///
/// **Comment** : NotebookLM n'a pas d'API publique pour un compte personnel. On ouvre la vraie
/// page de connexion de Google dans une fenêtre de l'app (StudyTrack ne voit jamais ton mot de
/// passe : seule la session reste, dans le stockage web de l'app), puis on parle au site comme
/// il se parle à lui-même (`NotebookLMWire`). C'est **non officiel** : Google peut changer le
/// protocole sans préavis (l'appel échoue alors, avec un message, et l'export manuel reste là),
/// et ses conditions n'autorisent pas explicitement les outils tiers. Rien ne sort de ton
/// appareil vers un autre serveur que Google.
@MainActor @Observable
final class NotebookLMAccount {
    static let shared = NotebookLMAccount()

    enum State: Equatable { case unknown, checking, signedOut, ready }

    private(set) var state: State = .unknown
    /// Ce qui se passe, par cours (« Je dépose la fiche… »).
    private(set) var progress: [UUID: String] = [:]
    private(set) var failure: [UUID: String] = [:]

    private var token: String?
    private var session: String?
    private var cookies = ""
    private var host = NotebookLMWire.hosts[0]
    private var jobs: [UUID: Task<Void, Never>] = [:]

    private let agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    enum Failure: LocalizedError {
        case signedOut, refused(Int?), noAnswer, noAudio, timedOut, failed

        var errorDescription: String? {
            switch self {
            case .signedOut: return String(localized: "La connexion à Google a expiré : reconnecte-toi.")
            case .refused(let code): return String(localized: "Google a refusé la demande (code \(code.map(String.init) ?? "?")) : la limite du jour est peut-être atteinte, ou NotebookLM a changé son fonctionnement.")
            case .noAnswer: return String(localized: "NotebookLM n'a pas répondu comme prévu : son fonctionnement a peut-être changé. L'export manuel reste possible.")
            case .noAudio: return String(localized: "Le podcast est prêt mais son fichier n'a pas pu être récupéré.")
            case .timedOut: return String(localized: "Le podcast met trop de temps. Il continue peut-être dans NotebookLM : « Récupérer » le retrouvera.")
            case .failed: return String(localized: "NotebookLM n'a pas pu créer le podcast.")
            }
        }
    }

    // MARK: Session

    var isReady: Bool { state == .ready }

    /// La session web de l'app (persistante : on ne se reconnecte pas à chaque lancement).
    static var store: WKWebsiteDataStore { .default() }

    /// Vérifie si une session Google valable existe déjà.
    func refresh() async {
        state = .checking
        let all = await Self.store.httpCookieStore.allCookies().filter { $0.domain.hasSuffix("google.com") }
        guard NotebookLMWire.isSignedIn(cookieNames: all.map(\.name)) else { state = .signedOut; return }
        cookies = all.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        for candidate in NotebookLMWire.hosts {
            guard let url = URL(string: candidate + "/") else { continue }
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
            request.setValue(agent, forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await Self.client.data(for: request),
                  let final = response.url?.host, NotebookLMWire.isApp(host: final),
                  let html = String(data: data, encoding: .utf8),
                  let at = NotebookLMWire.field("SNlM0e", inPage: html),
                  let sid = NotebookLMWire.field("FdrFJe", inPage: html) else { continue }
            token = at; session = sid; host = candidate
            state = .ready
            return
        }
        state = .signedOut
    }

    func signOut() async {
        let records = await Self.store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await Self.store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records.filter { $0.displayName.contains("google") })
        token = nil; session = nil; cookies = ""
        state = .signedOut
    }

    /// Un client sans cookies à lui : ceux de la session Google sont écrits à la main.
    private static let client: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    // MARK: Appels

    private func call(_ rpc: NotebookLMWire.RPC, _ params: [Any], path: String = "/", retry: Bool = true) async throws -> Any? {
        guard let token, let session,
              let url = NotebookLMWire.url(host: host, rpc: rpc, sourcePath: path, session: session) else { throw Failure.signedOut }
        var request = URLRequest(url: url, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.httpBody = NotebookLMWire.body(rpc: rpc, params: params, token: token).data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(cookies, forHTTPHeaderField: "Cookie")
        request.setValue(host, forHTTPHeaderField: "Origin")
        request.setValue(host + "/", forHTTPHeaderField: "Referer")
        request.setValue("1", forHTTPHeaderField: "X-Same-Domain")
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        let expired: Bool
        do {
            let (data, response) = try await Self.client.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200, let text = String(data: data, encoding: .utf8) {
                do { return try NotebookLMWire.result(of: text, rpc: rpc) }
                catch NotebookLMWire.ParseError.refused(let code) { throw Failure.refused(code) }
                catch NotebookLMWire.ParseError.notAnswer { expired = true }
            } else {
                expired = [400, 401, 403].contains(status)
                if !expired { throw Failure.noAnswer }
            }
        }
        // Le jeton a expiré : on le relit une fois, puis on retente.
        guard retry else { throw Failure.signedOut }
        await refresh()
        guard state == .ready else { throw Failure.signedOut }
        return try await call(rpc, params, path: path, retry: false)
    }

    // MARK: Le podcast d'un cours

    var isWorking: Set<UUID> { Set(jobs.keys) }

    func cancel(_ course: Course) {
        jobs[course.id]?.cancel()
        jobs[course.id] = nil
        progress[course.id] = nil
    }

    /// Crée un carnet, y dépose la fiche, lance le podcast, l'attend et le rapporte dans le cours.
    func makePodcast(for course: Course, sheet: RevisionSheet) {
        guard jobs[course.id] == nil, isReady else { return }
        failure[course.id] = nil
        let id = course.id
        jobs[id] = Task { [weak self] in
            guard let self else { return }
            do { try await self.run(course, sheet: sheet) }
            catch is CancellationError {}
            catch { self.failure[id] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            self.progress[id] = nil
            self.jobs[id] = nil
        }
    }

    /// Retrouve et rapporte le dernier podcast du carnet gardé (après un lancement interrompu).
    func fetchLatest(for course: Course) {
        guard jobs[course.id] == nil, isReady, let address = StudyMapStore.shared.map(course).notebookURL,
              let notebook = NotebookLMWire.notebookID(fromURL: address) else { return }
        failure[course.id] = nil
        let id = course.id
        jobs[id] = Task { [weak self] in
            guard let self else { return }
            do {
                self.progress[id] = String(localized: "Je cherche le podcast dans ton carnet…")
                let list = NotebookLMWire.artifacts(from: try await self.call(.listArtifacts, NotebookLMWire.listArtifactsParams(notebookID: notebook), path: "/notebook/\(notebook)"))
                guard let podcast = list.last(where: { $0.type == 1 && $0.state == .ready && $0.audioURL != nil }) else { throw Failure.noAudio }
                try await self.bring(podcast, to: course)
            } catch is CancellationError {}
            catch { self.failure[id] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            self.progress[id] = nil
            self.jobs[id] = nil
        }
    }

    private func run(_ course: Course, sheet: RevisionSheet) async throws {
        let id = course.id
        let map = StudyMapStore.shared.map(course)
        let files = NotebookExport.files(courseName: course.name, code: course.displayCode, sheet: sheet, map: map)
            .filter { !$0.name.hasPrefix("00") }

        progress[id] = String(localized: "Je crée le carnet…")
        let title = "StudyTrack · \(course.name)"
        let created = try await call(.createNotebook, NotebookLMWire.createNotebookParams(title: title))
        guard let notebook = NotebookLMWire.firstID(in: created) else { throw Failure.noAnswer }
        let path = "/notebook/\(notebook)"
        StudyMapStore.shared.update(course) { $0.notebookURL = NotebookLMWire.notebookURL(id: notebook, host: self.host) }

        var sources: [String] = []
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            progress[id] = String(localized: "Je dépose la fiche (\(index + 1)/\(files.count))…")
            let added = try await call(.addSource, NotebookLMWire.addTextSourceParams(notebookID: notebook, title: file.name.replacingOccurrences(of: ".md", with: ""), text: file.text), path: path)
            if let source = NotebookLMWire.firstID(in: added) { sources.append(source) }
        }
        guard !sources.isEmpty else { throw Failure.noAnswer }

        progress[id] = String(localized: "Je lance le podcast…")
        let started = try await call(.createArtifact, NotebookLMWire.createAudioParams(
            notebookID: notebook, sourceIDs: sources, instructions: NotebookLMWire.podcastInstructions(courseName: course.name),
            language: "fr", format: .deepDive, length: .standard), path: path)
        let artifact = NotebookLMWire.firstID(in: started)

        // Un podcast met de 3 à 10 minutes : on revient voir toutes les 10 s, 20 minutes au plus.
        for attempt in 0..<120 {
            try Task.checkCancellation()
            progress[id] = String(localized: "NotebookLM prépare le podcast… (\(attempt * 10 / 60) min)")
            try await Task.sleep(for: .seconds(10))
            let list = NotebookLMWire.artifacts(from: try await call(.listArtifacts, NotebookLMWire.listArtifactsParams(notebookID: notebook), path: path))
            let mine = list.first { $0.id == artifact } ?? list.last { $0.type == 1 }
            switch mine?.state {
            case .failed: throw Failure.failed
            case .ready:
                guard let mine, mine.audioURL != nil else { continue }
                try await bring(mine, to: course)
                return
            default: continue
            }
        }
        throw Failure.timedOut
    }

    /// Télécharge le son (avec la session : l'adresse n'est pas publique) et l'ajoute au cours.
    private func bring(_ podcast: NotebookLMWire.Artifact, to course: Course) async throws {
        guard let source = podcast.audioURL else { throw Failure.noAudio }
        progress[course.id] = String(localized: "Je télécharge le podcast…")
        var request = URLRequest(url: source, timeoutInterval: 300)
        request.setValue(cookies, forHTTPHeaderField: "Cookie")
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        let (temporary, response) = try await Self.client.download(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.noAudio }
        let name = "Podcast · \(course.displayCode) · \(Date.now.formatted(.dateTime.day().month(.abbreviated))).m4a"
        let file = FileManager.default.temporaryDirectory.appending(path: name.replacingOccurrences(of: "/", with: "-"))
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temporary, to: file)
        guard let stored = PodcastStore.importFile(file, for: course) else { throw Failure.noAudio }
        let title = (name as NSString).deletingPathExtension
        StudyMapStore.shared.update(course) {
            $0.resources.append(.init(id: UUID().uuidString, kind: .podcast, title: title, url: nil, fileName: stored, addedAt: Date()))
        }
        if let resource = StudyMapStore.shared.map(course).resources.last, let played = PodcastStore.url(for: resource, in: course) {
            PodcastPlayer.shared.play(played, title: title)
        }
    }
}

// MARK: - La fenêtre de connexion

/// La vraie page de connexion de Google, dans l'app. Quand NotebookLM s'affiche, la session est là.
struct NotebookLMLogin: View {
    var done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Connexion à Google").font(.headline).foregroundStyle(Carnet.ink)
                Spacer()
                Button("Fermer") { done() }.buttonStyle(.paper)
            }
            .padding(12)
            Divider()
            LoginWebView(finished: done)
        }
        .background(Carnet.ground)
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 640, idealHeight: 720)
        #endif
    }
}

private final class LoginCoordinator: NSObject, WKNavigationDelegate {
    let finished: () -> Void
    init(finished: @escaping () -> Void) { self.finished = finished }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // NotebookLM s'affiche (et non la page de connexion de Google) : c'est fait.
        // La page d'accueil de NotebookLM s'affiche aussi sans compte : on ne ferme que lorsque la
        // session Google existe vraiment (sinon la fenêtre se fermait aussitôt ouverte).
        guard let host = webView.url?.host, NotebookLMWire.isApp(host: host) else { return }
        Task { @MainActor in
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            if NotebookLMWire.isSignedIn(cookieNames: cookies.filter { $0.domain.hasSuffix("google.com") }.map(\.name)) { self.finished() }
        }
    }
}

#if os(macOS)
private struct LoginWebView: NSViewRepresentable {
    var finished: () -> Void
    func makeCoordinator() -> LoginCoordinator { LoginCoordinator(finished: finished) }
    func makeNSView(context: Context) -> WKWebView { make(context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#else
private struct LoginWebView: UIViewRepresentable {
    var finished: () -> Void
    func makeCoordinator() -> LoginCoordinator { LoginCoordinator(finished: finished) }
    func makeUIView(context: Context) -> WKWebView { make(context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif

@MainActor private func make(_ coordinator: LoginCoordinator) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = NotebookLMAccount.store
    let view = WKWebView(frame: .zero, configuration: configuration)
    // Google refuse les navigateurs intégrés qui se présentent comme tels : on se présente comme Safari.
    view.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    view.navigationDelegate = coordinator
    // Directement la page de connexion de Google, qui renvoie vers NotebookLM une fois connecté·e
    // (la page d'accueil de NotebookLM, elle, s'affiche aussi sans compte).
    view.load(URLRequest(url: URL(string: "https://accounts.google.com/ServiceLogin?continue=" + NotebookLMWire.hosts[0] + "/")!))
    return view
}
