import Foundation
import WebKit

/// Un navigateur **invisible**, dans la session de l'étudiant·e.
///
/// L'EPFL ne donne aucun jeton d'API. Ce que Moodle et Courseware savent faire,
/// en revanche, c'est répondre à leurs **propres pages** : la page du tableau de
/// bord de Moodle appelle `lib/ajax/service.php` avec la clé de session, Open
/// edX sert son plan de cours en JSON à qui est connecté. On charge donc une
/// page du site, sans l'afficher, et on y fait les mêmes appels. Les cookies
/// sont ceux du magasin WebKit par défaut, persistant : la connexion faite une
/// fois dans le navigateur intégré sert à tous les imports suivants, et à la
/// mise à jour automatique.
@MainActor
final class HiddenSiteSession: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var loading: CheckedContinuation<Void, Error>?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    var currentURL: URL? { webView.url }

    /// Charge une page et attend la fin du chargement (20 s au plus).
    func load(_ url: URL) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { continuation in
                    self.loading?.resume(throwing: CancellationError())
                    self.loading = continuation
                    self.webView.load(URLRequest(url: url))
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(20))
                throw SiteError.timeout
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    /// Exécute un script `async` dans la page et rend sa valeur texte.
    func run(_ script: String, arguments: [String: Any] = [:]) async throws -> String {
        let value = try await webView.callAsyncJavaScript(script, arguments: arguments, contentWorld: .page)
        return (value as? String) ?? ""
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.finish(nil) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finish(error) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finish(error) }
    }

    private func finish(_ error: Error?) {
        guard let loading else { return }
        self.loading = nil
        if let error { loading.resume(throwing: error) } else { loading.resume() }
    }

    enum SiteError: LocalizedError {
        case timeout
        case notSignedIn
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .timeout: return "Le site ne répond pas. Vérifie ta connexion."
            case .notSignedIn: return "Connecte-toi d'abord (une seule fois)."
            case .failed(let message): return message
            }
        }
    }
}

// MARK: - Moodle

/// Moodle, par les appels AJAX de ses propres pages.
///
/// Vérifié sur moodle.epfl.ch (Moodle 4.5) :
///   • `core_course_search_courses` répond **sans connexion** — l'app trouve
///     le cours Moodle d'un code (MATH-101) sans rien demander ;
///   • `core_course_get_enrolled_courses_by_timeline_classification` dit à quels
///     cours on est inscrit·e, une fois connecté·e ;
///   • `core_courseformat_get_state` rend le plan du cours en JSON.
@MainActor
final class MoodleClient {
    static let home = URL(string: "https://moodle.epfl.ch/my/")!
    static let login = URL(string: "https://moodle.epfl.ch/login/index.php")!

    private let session = HiddenSiteSession()
    private var isReady = false

    /// Charge le tableau de bord, une fois : c'est lui qui porte la clé de session.
    func prepare(force: Bool = false) async throws {
        guard !isReady || force else { return }
        try await session.load(Self.home)
        isReady = true
    }

    /// Connecté·e ? (le menu de l'utilisateur n'existe qu'une fois connecté·e ;
    /// un visiteur anonyme a une clé de session, mais pas de menu.)
    func isSignedIn() async -> Bool {
        do {
            try await prepare(force: true)
            let result = try await session.run(#"""
            return JSON.stringify({ user: !!document.querySelector('#user-menu-toggle, .usermenu .userbutton'),
                                    login: location.pathname.indexOf('/login') === 0 });
            """#)
            return result.contains(#""user":true"#) && !result.contains(#""login":true"#)
        } catch {
            return false
        }
    }

    /// Les cours Moodle dont le nom contient `query` (« MATH-101 »).
    func search(_ query: String) async throws -> [MoodleCourseRef] {
        let json = try await call("core_course_search_courses",
                                  args: ["criterianame": "search", "criteriavalue": query, "page": 0, "perpage": 30])
        return MoodleStateParser.courses(fromJSON: json)
    }

    /// Les cours où l'on est inscrit·e (vide sans connexion).
    func enrolled() async throws -> [MoodleCourseRef] {
        let json = try await call("core_course_get_enrolled_courses_by_timeline_classification",
                                  args: ["offset": 0, "limit": 0, "classification": "all", "sort": "fullname"])
        return MoodleStateParser.courses(fromJSON: json)
    }

    /// Le cours tel qu'un·e étudiant·e le lit : chaque activité, **où elle
    /// mène vraiment** (la vidéo MediaSpace, le PDF d'un site de cours) et, pour
    /// un devoir, son échéance.
    ///
    /// Ni la cible d'un lien ni l'échéance d'un devoir ne sont dans le plan du
    /// cours : elles sont sur la page de l'activité (le lien de
    /// « urlworkaround », la ligne « Due: … »). On lit ces pages dans la
    /// session, six à la fois — c'est ce que ferait l'étudiant·e en cliquant.
    func snapshot(of course: MoodleCourseRef) async throws -> MoodleCourseSnapshot {
        let json = try await call("core_courseformat_get_state", args: ["courseid": course.id])
        let state = (try? JSONDecoder().decode(String.self, from: Data(json.utf8))) ?? json
        guard var snapshot = MoodleStateParser.snapshot(fromStateJSON: state,
                                                        title: "\(course.fullname) (\(course.shortname))",
                                                        url: course.url.absoluteString) else {
            throw WebContentScraper.ScrapeError.empty
        }
        let wanted = snapshot.sections.flatMap(\.activities)
            .filter { $0.isVisible && ($0.module == "url" || $0.module == "assign") }
            .map { ["id": $0.id, "module": $0.module] }
        guard !wanted.isEmpty else { return snapshot }
        let argsJSON = String(decoding: try JSONSerialization.data(withJSONObject: wanted), as: UTF8.self)
        let raw = try await session.run(#"""
        const items = JSON.parse(list);
        const out = {};
        const one = async (item) => {
          try {
            const r = await fetch('/mod/' + item.module + '/view.php?id=' + item.id, { credentials: 'include' });
            const html = await r.text();
            const doc = new DOMParser().parseFromString(html, 'text/html');
            if (item.module === 'url') {
              const a = doc.querySelector('.urlworkaround a, .resourceworkaround a, #region-main a[href^="http"]:not([href*="moodle.epfl.ch"])');
              out[item.id] = { target: a ? a.href : (r.redirected ? r.url : '') };
            } else {
              const dates = doc.querySelector('[data-region="activity-dates"], .activity-dates');
              out[item.id] = { dates: dates ? dates.innerText : '' };
            }
          } catch (e) { out[item.id] = {}; }
        };
        for (let i = 0; i < items.length; i += 6) { await Promise.all(items.slice(i, i + 6).map(one)); }
        return JSON.stringify(out);
        """#, arguments: ["list": argsJSON])
        struct Found: Decodable { var target: String?; var dates: String? }
        let found = (try? JSONDecoder().decode([String: Found].self, from: Data(raw.utf8))) ?? [:]
        for s in snapshot.sections.indices {
            for a in snapshot.sections[s].activities.indices {
                let id = snapshot.sections[s].activities[a].id
                guard let info = found[id] else { continue }
                if let target = info.target, target.hasPrefix("http") { snapshot.sections[s].activities[a].target = target }
                if let dates = info.dates, let due = MoodleCourseAnalyzer.dueDate(fromActivityDates: dates) {
                    snapshot.sections[s].activities[a].dueDate = due
                }
            }
        }
        return snapshot
    }

    /// Un appel AJAX, fait depuis la page. Rend le champ `data` en JSON, ou
    /// lève l'erreur de Moodle (`requireloginerror` = pas connecté·e).
    private func call(_ method: String, args: [String: Any]) async throws -> String {
        try await prepare()
        let argsJSON = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
        let raw = try await session.run(#"""
        if (!(window.M && M.cfg && M.cfg.sesskey)) { return JSON.stringify({ error: true, errorcode: 'nosesskey' }); }
        const response = await fetch('/lib/ajax/service.php?sesskey=' + M.cfg.sesskey + '&info=' + method, {
          method: 'POST', credentials: 'include', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify([{ index: 0, methodname: method, args: JSON.parse(args) }])
        });
        const body = await response.json();
        const first = Array.isArray(body) ? body[0] : body;
        if (!first || first.error) { return JSON.stringify({ error: true, errorcode: (first && (first.errorcode || (first.exception && first.exception.errorcode))) || 'inconnu', message: first && (first.message || (first.exception && first.exception.message)) }); }
        return JSON.stringify({ data: first.data });
        """#, arguments: ["method": method, "args": argsJSON])
        struct Reply: Decodable {
            var error: Bool?
            var errorcode: String?
            var message: String?
        }
        let reply = try? JSONDecoder().decode(Reply.self, from: Data(raw.utf8))
        if reply?.error == true {
            if reply?.errorcode == "requireloginerror" || reply?.errorcode == "nosesskey" {
                throw HiddenSiteSession.SiteError.notSignedIn
            }
            throw HiddenSiteSession.SiteError.failed("Moodle : \(reply?.message ?? reply?.errorcode ?? "erreur inconnue")")
        }
        guard let object = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let data = object["data"] else { throw HiddenSiteSession.SiteError.failed("Réponse de Moodle illisible.") }
        if let text = data as? String {
            return String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: data), as: UTF8.self)
    }

    /// Trouve le cours Moodle d'un cours de l'app : le lien déjà retenu, sinon
    /// la recherche par code, départagée par les inscriptions.
    func resolve(_ course: Course, enrolled: [MoodleCourseRef]) async throws -> MoodleCourseMatcher.Match {
        if let id = MoodleCourseMatcher.linkedID(in: course.contentSources) {
            if let known = enrolled.first(where: { $0.id == id }) { return .unique(known) }
            return .unique(MoodleCourseRef(id: id, fullname: course.name, shortname: course.code))
        }
        let code = MoodleCourseMatcher.baseCode(course.code)
        let candidates = try await search(code)
        return MoodleCourseMatcher.match(code: course.code, candidates: candidates, enrolled: enrolled)
    }
}

// MARK: - Courseware

/// Courseware (Open edX), par ses API de page.
@MainActor
final class CoursewareClient {
    static let home = URL(string: "https://courseware.epfl.ch/dashboard")!
    static let login = URL(string: "https://courseware.epfl.ch/login")!

    private let session = HiddenSiteSession()
    private var isReady = false

    private func prepare() async throws {
        guard !isReady else { return }
        try await session.load(URL(string: "https://courseware.epfl.ch/courses/")!)
        isReady = true
    }

    func isSignedIn() async -> Bool {
        do {
            try await prepare()
            let status = try await session.run(#"""
            const r = await fetch('/api/user/v1/me', { credentials: 'include' });
            return String(r.status);
            """#)
            return status == "200"
        } catch {
            return false
        }
    }

    struct Enrollment: Identifiable, Hashable {
        var id: String { key }
        var key: String
        var name: String
    }

    /// Les cours où l'on est inscrit·e.
    func enrollments() async throws -> [Enrollment] {
        try await prepare()
        let raw = try await session.run(#"""
        const r = await fetch('/api/enrollment/v1/enrollment', { credentials: 'include', headers: { Accept: 'application/json' } });
        if (r.status === 401 || r.status === 403) { return JSON.stringify({ error: 'login' }); }
        const list = await r.json();
        return JSON.stringify((list || []).filter(e => e.is_active).map(e => ({ key: e.course_details.course_id, name: e.course_details.course_name })));
        """#)
        if raw.contains(#""error":"login""#) { throw HiddenSiteSession.SiteError.notSignedIn }
        struct Row: Decodable { var key: String; var name: String }
        let rows = (try? JSONDecoder().decode([Row].self, from: Data(raw.utf8))) ?? []
        return rows.map { Enrollment(key: $0.key, name: BotafogoParser.decode($0.name)) }
    }

    /// Le plan d'un cours : chapitres, leçons et vidéos.
    func content(of key: String) async throws -> ScrapedCourse {
        try await prepare()
        let raw = try await session.run(WebContentScraper.coursewareOutlineScript, arguments: ["key": key])
        if let failure = try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8)), let message = failure["error"] {
            throw HiddenSiteSession.SiteError.failed(message)
        }
        guard let page = try? JSONDecoder().decode(ScrapedCourse.self, from: Data(raw.utf8)),
              page.sections.contains(where: { !$0.items.isEmpty }) else {
            throw WebContentScraper.ScrapeError.empty
        }
        return page
    }
}
