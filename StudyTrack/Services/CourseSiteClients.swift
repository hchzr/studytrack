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

    /// Connecté·e, quitte à se **reconnecter sans rien demander**.
    ///
    /// La session Moodle expire au bout de quelques heures d'inactivité, mais
    /// la connexion EPFL (le compte Microsoft mémorisé) dure des semaines :
    /// rouvrir la page de connexion de Moodle dans le navigateur invisible
    /// suffit, en général, à revenir connecté·e — sans un seul écran. On ne
    /// demande de se reconnecter que si cette tentative échoue
    /// (`ConnectionCenter`).
    func ensureSignedIn() async -> Bool {
        if await isSignedIn() {
            ConnectionCenter.shared.report(.moodle, .connected)
            return true
        }
        // Jamais connecté·e : il n'y a rien à rejouer, et rien n'a « expiré ».
        guard ConnectionCenter.shared.state(of: .moodle) != .unknown else { return false }
        do {
            try await session.load(Self.login)
            // La connexion EPFL passe par plusieurs redirections : on attend
            // d'être revenu sur Moodle, hors de la page de connexion.
            for _ in 0..<12 {
                if let url = session.currentURL, url.host == "moodle.epfl.ch", !url.path.hasPrefix("/login") { break }
                try await Task.sleep(for: .seconds(1))
            }
        } catch {
            // Hors ligne : on ne sait pas. Rien n'est demandé.
            return false
        }
        isReady = false
        let signedIn = await isSignedIn()
        ConnectionCenter.shared.report(.moodle, signedIn ? .connected : .expired)
        if signedIn { AppLog.record(.info, "connexion", "Moodle : reconnecté·e sans intervention") }
        return signedIn
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
        // Les liens et devoirs, comme avant ; et **chaque série ou corrigé**,
        // quel que soit son module : une série publiée en page, en dossier ou en
        // fichier s'ouvrait sur la page Moodle qui porte le lien du PDF (AICC),
        // et l'app ne pouvait ni l'afficher ni en lire les exercices.
        // **Chaque** lien, fichier, page et dossier est ouvert : ce qu'il y a
        // derrière (un PDF d'exercices, une page qui les contient, un chapitre
        // de MOOC) dit ce qu'il faut en faire mieux que son nom. Les règles et
        // le modèle le lisent pour tous les cours, connus ou non.
        let wanted = snapshot.sections.flatMap(\.activities)
            .filter { $0.isVisible && ["url", "assign", "resource", "page", "folder"].contains($0.module) }
            .prefix(160)
            .map { ["id": $0.id, "module": $0.module] }
        snapshot.moocLinks = await moocLinks(courseID: course.id, snapshot: snapshot)
        await addSectionTexts(courseID: course.id, to: &snapshot)
        guard !wanted.isEmpty else { return snapshot }
        let argsJSON = String(decoding: try JSONSerialization.data(withJSONObject: wanted), as: UTF8.self)
        let raw = try await session.run(#"""
        const items = JSON.parse(list);
        const out = {};
        const isSolution = (a) => /(corrig|solution|\bsol\b|_sol\b|-sol\b|loesung|answers?\b|reponses|réponses)/i.test((a.innerText || '') + ' ' + a.href);
        const isDocument = (href) => /\/pluginfile\.php\//.test(href) || /\.pdf($|[?#])/i.test(href);
        const one = async (item) => {
          try {
            // `forceview=1` : la page « cliquez ici » d'un lien ou d'un fichier,
            // sans la redirection qu'un `fetch` ne peut pas suivre hors de Moodle.
            const force = (item.module === 'url' || item.module === 'resource') ? '&forceview=1' : '';
            const r = await fetch('/mod/' + item.module + '/view.php?id=' + item.id + force, { credentials: 'include' });
            const type = r.headers.get('content-type') || '';
            if (item.module === 'resource' && /\/pluginfile\.php\//.test(r.url)) { out[item.id] = { target: r.url, kind: type.includes('pdf') ? 'pdf' : 'fichier' }; return; }
            if (!type.includes('html')) { out[item.id] = { target: r.redirected ? r.url : '', kind: type.includes('pdf') ? 'pdf' : 'fichier' }; return; }
            const html = await r.text();
            const doc = new DOMParser().parseFromString(html, 'text/html');
            if (item.module === 'assign') {
              const dates = doc.querySelector('[data-region="activity-dates"], .activity-dates');
              out[item.id] = { dates: dates ? dates.innerText : '' };
              return;
            }
            const main = doc.querySelector('#region-main') || doc;
            const work = main.querySelector('.urlworkaround a, .resourceworkaround a');
            if (work) { out[item.id] = { target: new URL(work.getAttribute('href'), r.url).href }; return; }
            const embedded = main.querySelector('.resourcecontent iframe[src], .resourcecontent object[data], .resourcecontent embed[src], iframe[src*="pluginfile"], object[data*="pluginfile"]');
            if (embedded) { out[item.id] = { target: new URL(embedded.getAttribute('src') || embedded.getAttribute('data'), r.url).href }; return; }
            const links = Array.from(main.querySelectorAll('a[href]')).map(a => ({ a, href: new URL(a.getAttribute('href'), r.url).href }));
            const docs = links.filter(l => isDocument(l.href));
            const statement = docs.find(l => !isSolution(l.a));
            const solution = docs.find(l => isSolution(l.a));
            const text = (main.querySelector('.box.generalbox, .no-overflow, [role="main"]') || main).innerText || '';
            const preview = text.replace(/\s+/g, ' ').trim().slice(0, 500);
            if (statement || solution) {
              out[item.id] = { target: (statement || solution).href, solution: statement && solution ? solution.href : '',
                               kind: item.module === 'folder' ? 'dossier' : 'pdf', preview: item.module === 'page' ? preview : '' };
              return;
            }
            if (item.module === 'url') {
              const external = main.querySelector('a[href^="http"]:not([href*="moodle.epfl.ch"])');
              out[item.id] = { target: external ? external.href : '' };
              return;
            }
            out[item.id] = { kind: item.module === 'folder' ? 'dossier' : 'page moodle', preview };
          } catch (e) { out[item.id] = {}; }
        };
        for (let i = 0; i < items.length; i += 6) { await Promise.all(items.slice(i, i + 6).map(one)); }
        return JSON.stringify(out);
        """#, arguments: ["list": argsJSON])
        struct Found: Decodable { var target: String?; var solution: String?; var dates: String?; var kind: String?; var preview: String? }
        let found = (try? JSONDecoder().decode([String: Found].self, from: Data(raw.utf8))) ?? [:]
        for s in snapshot.sections.indices {
            for a in snapshot.sections[s].activities.indices {
                let id = snapshot.sections[s].activities[a].id
                guard let info = found[id] else { continue }
                if let target = info.target, target.hasPrefix("http") { snapshot.sections[s].activities[a].target = target }
                if let solution = info.solution, solution.hasPrefix("http") { snapshot.sections[s].activities[a].solutionTarget = solution }
                if let dates = info.dates, let due = MoodleCourseAnalyzer.dueDate(fromActivityDates: dates) {
                    snapshot.sections[s].activities[a].dueDate = due
                }
                if let kind = info.kind, !kind.isEmpty { snapshot.sections[s].activities[a].destination = kind }
                if let preview = info.preview, !preview.isEmpty { snapshot.sections[s].activities[a].preview = preview }
            }
        }
        await CourseEvidence.peekTargets(in: &snapshot)
        return snapshot
    }

    /// Le texte de chaque section (résumé, étiquettes) et ses liens, lus sur
    /// la page du cours : la consigne de la semaine y est souvent écrite
    /// (« regardez les vidéos du module 2, la série est sur le site du cours »).
    private func addSectionTexts(courseID: Int, to snapshot: inout MoodleCourseSnapshot) async {
        let raw = (try? await session.run(#"""
        const r = await fetch('/course/view.php?id=' + course, { credentials: 'include' });
        const doc = new DOMParser().parseFromString(await r.text(), 'text/html');
        const out = [];
        doc.querySelectorAll('li.section[data-sectionnumber], li.section[data-number], [data-for="section"][data-number]').forEach(section => {
          const n = Number(section.getAttribute('data-sectionnumber') ?? section.getAttribute('data-number'));
          if (isNaN(n)) return;
          const parts = [];
          const links = [];
          const holders = section.querySelectorAll('.summarytext, .course-description-item, .activity.modtype_label .activity-altcontent, .activity.label .contentwithoutlink, .activity.modtype_label .no-overflow');
          holders.forEach(h => {
            const t = (h.innerText || h.textContent || '').replace(/\s+/g, ' ').trim();
            if (t && !parts.includes(t)) parts.push(t);
            h.querySelectorAll('a[href^="http"]').forEach(a => {
              const href = a.href;
              if (/moodle\.epfl\.ch\/(user|course\/view|login)/.test(href) || links.some(l => l.url === href)) return;
              links.push({ url: href, title: (a.innerText || a.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 120) });
            });
          });
          out.push({ number: n, text: parts.join(' · ').slice(0, 2000), links: links.slice(0, 25) });
        });
        return JSON.stringify(out);
        """#, arguments: ["course": String(courseID)])) ?? "[]"
        struct Row: Decodable { var number: Int; var text: String; var links: [Link]; struct Link: Decodable { var url: String; var title: String } }
        let rows = (try? JSONDecoder().decode([Row].self, from: Data(raw.utf8))) ?? []
        for row in rows {
            guard let index = snapshot.sections.firstIndex(where: { $0.number == row.number }) else { continue }
            snapshot.sections[index].text = row.text
            snapshot.sections[index].links = row.links.map { link in
                ContentLink(title: link.title, url: link.url, kind: CourseEvidence.linkKind(link.url))
            }
        }
    }

    /// Les liens Courseware du cours : ceux de la page du cours (texte des
    /// sections, étiquettes) et ceux des pages Moodle (« Matériel MOOC de la
    /// semaine »), chacun avec le numéro de sa section.
    private func moocLinks(courseID: Int, snapshot: MoodleCourseSnapshot) async -> [MoocReference] {
        var pages: [[String: Any]] = []
        for section in snapshot.sections {
            for activity in section.activities where activity.isVisible && activity.module == "page" {
                pages.append(["id": activity.id, "section": section.number])
            }
        }
        guard let pagesJSON = try? JSONSerialization.data(withJSONObject: pages) else { return [] }
        let raw = (try? await session.run(#"""
        const out = [];
        const collect = (doc, section) => {
          doc.querySelectorAll('a[href*="courseware.epfl.ch"]').forEach(a => {
            let s = section;
            if (s === null || s === undefined) {
              const holder = a.closest('[data-sectionnumber], [data-number], li.section');
              const n = holder && (holder.getAttribute('data-sectionnumber') || holder.getAttribute('data-number') || (holder.id || '').replace('section-', ''));
              s = n !== null && n !== undefined && n !== '' && !isNaN(Number(n)) ? Number(n) : null;
            }
            out.push({ url: a.href, title: (a.innerText || a.textContent || '').trim(), section: s });
          });
        };
        try {
          const r = await fetch('/course/view.php?id=' + course, { credentials: 'include' });
          collect(new DOMParser().parseFromString(await r.text(), 'text/html'), null);
        } catch (e) {}
        const pages = JSON.parse(list);
        for (let i = 0; i < pages.length; i += 6) {
          await Promise.all(pages.slice(i, i + 6).map(async p => {
            try {
              const r = await fetch('/mod/page/view.php?id=' + p.id, { credentials: 'include' });
              collect(new DOMParser().parseFromString(await r.text(), 'text/html'), p.section);
            } catch (e) {}
          }));
        }
        return JSON.stringify(out);
        """#, arguments: ["course": String(courseID), "list": String(decoding: pagesJSON, as: UTF8.self)])) ?? "[]"
        struct Row: Decodable { var url: String; var title: String; var section: Int? }
        let rows = (try? JSONDecoder().decode([Row].self, from: Data(raw.utf8))) ?? []
        var seen = Set<String>()
        return rows.compactMap { row in
            guard MoocReference.courseKey(in: row.url) != nil, seen.insert(row.url + "|\(row.section ?? -1)").inserted else { return nil }
            return MoocReference(url: row.url, title: row.title, sectionNumber: row.section)
        }
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

// MARK: - MOOC cités depuis Moodle

/// Le MOOC qu'un cours Moodle cite, lu sur Courseware et rangé dans ses
/// semaines (`MoocMerger`).
// MARK: - Explique

/// Explique (explique.epfl.ch), lu dans la session de l'étudiant·e : la page
/// charge cours et exercices après connexion (Convex) ; on attend qu'elle les
/// affiche, puis on lit ses titres « Week N » et ses liens.
@MainActor
final class ExpliqueClient {
    static let home = URL(string: "https://explique.epfl.ch/")!

    private let session = HiddenSiteSession()

    enum Failure: Error { case notSignedIn }

    /// Connecté·e ? La page d'accueil affiche le compte (« …@epfl.ch ») ou
    /// renvoie vers `/login`.
    func isSignedIn() async -> Bool {
        do {
            try await session.load(Self.home)
            let result = try await session.run(#"""
            for (let i = 0; i < 20; i++) {
              if (location.pathname.startsWith('/login')) return 'false';
              if (/@epfl\.ch/.test(document.body.innerText) || document.querySelector('h2')) return 'true';
              await new Promise(r => setTimeout(r, 400));
            }
            return 'false';
            """#)
            return result == "true"
        } catch {
            return false
        }
    }

    func lectures(slug: String) async throws -> [ExpliqueImport.Lecture] {
        let raw = try await read(URL(string: "https://explique.epfl.ch/\(slug)/lectures")!, script: #"""
        return JSON.stringify(weeks.flatMap(({ h, week }) => {
          let sec = h;
          while (sec && !sec.querySelector('a[href*="/v/"]')) {
            sec = sec.parentElement;
            if (sec && [...sec.querySelectorAll('h2')].filter(x => /^Week \d+$/.test(x.textContent.trim())).length > 1) return [];
          }
          return sec ? [...sec.querySelectorAll('a[href*="/v/"]')].map(a => ({ week, title: a.innerText.trim().replace(/\s+/g, ' '), url: a.href })) : [];
        }));
        """#)
        return (try? JSONDecoder().decode([ExpliqueImport.Lecture].self, from: Data(raw.utf8))) ?? []
    }

    func exercises(slug: String) async throws -> [ExpliqueImport.Exercise] {
        let raw = try await read(URL(string: "https://explique.epfl.ch/\(slug)/exercises")!, script: #"""
        return JSON.stringify(weeks.flatMap(({ h, week }) => {
          const header = h.closest('header');
          const sec = header ? header.parentElement : h.parentElement;
          const due = sec.querySelector('strong');
          const done = /completed|terminé/i.test((header || h).innerText);
          return [...sec.querySelectorAll('a[href*="/e/"]')].map(a => ({ week, title: a.innerText.trim().replace(/\s+/g, ' '), url: a.href, due: due ? due.innerText.trim() : '', done }));
        }));
        """#)
        return (try? JSONDecoder().decode([ExpliqueImport.Exercise].self, from: Data(raw.utf8))) ?? []
    }

    /// Charge la page, attend ses semaines (15 s au plus), puis exécute
    /// `script` avec `weeks` = [{ h, week }].
    private func read(_ url: URL, script: String) async throws -> String {
        try await session.load(url)
        let result = try await session.run(#"""
        const until = Date.now() + 15000;
        const find = () => [...document.querySelectorAll('h2')].filter(h => /^Week \d+$/.test(h.textContent.trim()));
        while (Date.now() < until) {
          if (location.pathname.startsWith('/login')) return '__login__';
          if (find().length) break;
          await new Promise(r => setTimeout(r, 400));
        }
        if (location.pathname.startsWith('/login')) return '__login__';
        const weeks = find().map(h => ({ h, week: Number(h.textContent.trim().split(' ')[1]) }));
        """# + script)
        if result == "__login__" { throw Failure.notSignedIn }
        return result
    }
}

/// Explique, quand Moodle y renvoie (AICC) : ses cours en replay et ses
/// exercices, ajoutés au brouillon dans leurs semaines.
@MainActor
enum ExpliqueSupplement {
    struct Outcome {
        var draft: ContentDraft
        var note: String?
        var needsLogin = false
    }

    static func complete(_ draft: ContentDraft, snapshot: MoodleCourseSnapshot,
                         termStart: Date?, totalWeeks: Int) async -> Outcome {
        let links = snapshot.sections.flatMap(\.activities).flatMap { [$0.url, $0.target ?? ""] }
        guard let slug = ExpliqueImport.slug(in: links) else { return Outcome(draft: draft) }
        let client = ExpliqueClient()
        do {
            let lectures = try await client.lectures(slug: slug)
            let exercises = (try? await client.exercises(slug: slug)) ?? []
            let merged = ExpliqueImport.merge(lectures: lectures, exercises: exercises, into: draft,
                                              termStart: termStart, totalWeeks: totalWeeks)
            let note = merged.added > 0 ? "+ Explique (\(lectures.count) vidéo\(lectures.count > 1 ? "s" : ""), \(exercises.count) exercice\(exercises.count > 1 ? "s" : ""))" : nil
            return Outcome(draft: merged.draft, note: note)
        } catch ExpliqueClient.Failure.notSignedIn {
            return Outcome(draft: draft, note: "Explique cité sur Moodle — connecte-toi à Explique (Profil › Comptes) pour ses vidéos", needsLogin: true)
        } catch {
            AppLog.record(.warning, "import", "Explique illisible", detail: error.localizedDescription)
            return Outcome(draft: draft, note: "Explique illisible")
        }
    }
}

// MARK: - MediaSpace

/// MediaSpace (Kaltura), lu dans la session : les listes de lecture, chaînes et
/// catégories qu'un cours cite sur Moodle (« Lecture recordings 2025 »),
/// déroulées jusqu'au bout, vidéo par vidéo.
@MainActor
final class MediaSpaceClient {
    private let session = HiddenSiteSession()

    enum Failure: Error { case notSignedIn }

    /// L'identifiant Kaltura d'une vidéo (« 0_6y8w1d2s ») : le dernier d'une adresse.
    nonisolated static func entryID(in link: String) -> String? {
        let decoded = link.removingPercentEncoding ?? link
        guard let regex = try? NSRegularExpression(pattern: #"[/=]([01]_[a-z0-9]{8})(?=[/?#&]|$)"#) else { return nil }
        let matches = regex.matches(in: decoded, range: NSRange(decoded.startIndex..., in: decoded))
        return matches.last.flatMap { Range($0.range(at: 1), in: decoded).map { String(decoded[$0]) } }
    }

    /// Une page qui regroupe des vidéos (et non une vidéo seule).
    nonisolated static func isCollection(_ link: String) -> Bool {
        guard let url = URL(string: link), url.host?.hasSuffix("mediaspace.epfl.ch") == true else { return false }
        let path = url.path
        if path.contains("/channel/") || path.contains("/category/") || path.contains("/channels/") { return true }
        // `/playlist/dedicated/<cat>/<liste>` : la liste ; avec un dernier
        // identifiant en plus, c'est une vidéo de la liste.
        if path.contains("/playlist/") {
            let ids = path.split(separator: "/").filter { $0.range(of: #"^[01]_[a-z0-9]{8}$"#, options: .regularExpression) != nil }
            return ids.count == 1
        }
        return false
    }

    /// Connecté·e ? « Mes médias » montre « Logout » ; sinon MediaSpace renvoie
    /// vers le choix de l'établissement (WAYF).
    func isSignedIn() async -> Bool {
        do {
            try await session.load(URL(string: "https://mediaspace.epfl.ch/my-media")!)
            let result = try await session.run(#"""
            for (let i = 0; i < 15; i++) {
              if (/wayf|eduid|login|saml/i.test(location.href)) return 'false';
              if (document.querySelector('a[href*="/user/logout"]')) return 'true';
              await new Promise(r => setTimeout(r, 400));
            }
            return 'false';
            """#)
            return result == "true"
        } catch {
            return false
        }
    }

    func entries(of collection: URL) async throws -> [CourseVideos.Video] {
        try await session.load(collection)
        let own = Self.entryID(in: collection.absoluteString) ?? ""
        let raw = try await session.run(#"""
        const sleep = ms => new Promise(r => setTimeout(r, ms));
        const isLogin = () => /wayf|eduid|login|shibboleth|saml/i.test(location.href);
        const until = Date.now() + 15000;
        while (Date.now() < until) {
          if (isLogin()) return '__login__';
          // Une liste de lecture (lecteur Kaltura : éléments « playlist-item ») ou
          // une galerie (chaîne, catégorie : liens « /media/… »).
          if (document.querySelector('[class*="playlistItemThumbnailWrap"]')) break;
          if ([...document.querySelectorAll('a[href]')].filter(a => /[01]_[a-z0-9]{8}/.test(a.href) && !a.href.includes(own)).length > 2) break;
          await sleep(400);
        }
        if (isLogin()) return '__login__';
        // « Charger plus » et défilement : les chaînes ne montrent qu'une page.
        for (let i = 0; i < 10; i++) {
          window.scrollTo(0, document.body.scrollHeight);
          const more = [...document.querySelectorAll('button, a')].find(b => /load more|charger plus|afficher plus|voir plus|more media|show more/i.test(b.innerText || ''));
          if (more) { more.click(); await sleep(1200); } else { await sleep(500); }
        }
        const seen = new Set([own]);
        const out = [];
        // Liste de lecture : l'identifiant est dans l'aperçu, le titre dans
        // l'élément (« 1 02:12:56 PHYS-101(en) Lecture 01a: … »). Vérifié sur
        // « Lecture recordings 2025 » de PHYS-101 : 25 vidéos.
        const base = location.href.replace(/\/[01]_[a-z0-9]{8}\/?(\?.*)?$/, '').replace(/\?.*$/, '');
        document.querySelectorAll('[class*="playlistItemThumbnailWrap"]').forEach(t => {
          const id = ((t.getAttribute('style') || '').match(/[01]_[a-z0-9]{8}/) || [])[0];
          let item = t.parentElement;
          while (item && ![...item.classList].some(c => /^playlist-item__playlistItem___/.test(c))) item = item.parentElement;
          item = item || t.parentElement;
          const title = (item.innerText || '').trim().replace(/\s+/g, ' ').replace(/^\d+\s+(\d{1,2}:)?\d{1,2}:\d{2}\s+/, '');
          if (!id || seen.has(id) || title.length < 3) return;
          seen.add(id);
          out.push({ title, url: base.includes('/playlist/') ? base + '/' + id : 'https://mediaspace.epfl.ch/media/t/' + id });
        });
        document.querySelectorAll('a[href]').forEach(a => {
          const href = decodeURIComponent(a.href);
          const ids = href.match(/[01]_[a-z0-9]{8}/g);
          if (!ids) return;
          const id = ids[ids.length - 1];
          if (seen.has(id)) return;
          const img = a.querySelector('img');
          const title = (a.getAttribute('title') || a.getAttribute('aria-label') || a.innerText || (img && img.alt) || '').trim().replace(/\s+/g, ' ');
          if (!title || title.length < 3) return;
          seen.add(id);
          out.push({ title, url: a.href });
        });
        return JSON.stringify(out);
        """#, arguments: ["own": own])
        if raw == "__login__" { throw Failure.notSignedIn }
        struct Row: Decodable { var title: String; var url: String }
        let rows = (try? JSONDecoder().decode([Row].self, from: Data(raw.utf8))) ?? []
        return rows.map { CourseVideos.Video(title: $0.title, url: $0.url, week: nil) }
    }
}

/// Les listes de lecture MediaSpace qu'un cours cite sur Moodle : chacune de
/// leurs vidéos rejoint l'élément de théorie de sa semaine.
@MainActor
enum MediaSpaceSupplement {
    struct Outcome {
        var draft: ContentDraft
        var note: String?
        var needsLogin = false
    }

    static func complete(_ draft: ContentDraft, snapshot: MoodleCourseSnapshot,
                         termStart: Date?, totalWeeks: Int) async -> Outcome {
        let links = snapshot.sections.flatMap(\.activities).flatMap { [$0.url, $0.target ?? ""] }
        let collections = Array(Set(links.filter(MediaSpaceClient.isCollection))).sorted().compactMap(URL.init(string:))
        guard !collections.isEmpty else { return Outcome(draft: draft) }
        // Les vidéos que Moodle donne déjà, par leur identifiant.
        let known = Set(draft.sections.flatMap(\.items).flatMap { [$0.url] + $0.links.map(\.url) }
            .compactMap(MediaSpaceClient.entryID(in:)))
        let client = MediaSpaceClient()
        var videos: [CourseVideos.Video] = []
        do {
            for collection in collections.prefix(4) {
                videos += try await client.entries(of: collection)
            }
        } catch MediaSpaceClient.Failure.notSignedIn {
            return Outcome(draft: draft, note: "Liste de vidéos MediaSpace citée — connecte-toi à MediaSpace (Profil › Comptes)", needsLogin: true)
        } catch {
            AppLog.record(.warning, "import", "MediaSpace illisible", detail: error.localizedDescription)
            return Outcome(draft: draft, note: "MediaSpace illisible")
        }
        var seen = known
        let fresh = videos.filter { video in
            guard let id = MediaSpaceClient.entryID(in: video.url) else { return false }
            return seen.insert(id).inserted
        }
        guard !fresh.isEmpty else { return Outcome(draft: draft) }
        let perWeek = CourseVideos.lecturesPerWeek(fresh.map(\.title), totalWeeks: totalWeeks)
        let placed = fresh.map { video in
            CourseVideos.Video(title: video.title, url: video.url,
                               week: CourseVideos.week(of: video.title, termStart: termStart, totalWeeks: totalWeeks, lecturesPerWeek: perWeek))
        }
        let merged = CourseVideos.merge(placed, into: draft, totalWeeks: totalWeeks, sourceLabel: "MediaSpace")
        return Outcome(draft: merged.draft, note: "+ MediaSpace (\(fresh.count) vidéo\(fresh.count > 1 ? "s" : ""))")
    }
}

// MARK: - Plan du cours

/// Le plan (ou calendrier) d'un cours, quand Moodle en cite un : le texte où
/// l'enseignant·e dit, semaine par semaine, quoi regarder et quoi faire.
///
/// Reconnu à son nom (« plan du cours », « syllabus », « schedule »…) **ou à
/// son contenu** : un document qui parle de nombreuses semaines (« Semaine 3 »,
/// « Week 5 », des dates) est un calendrier, quel que soit son nom.
@MainActor
enum CoursePlanReader {
    static func text(for snapshot: MoodleCourseSnapshot) async -> String? {
        let activities = snapshot.sections.flatMap(\.activities).filter(\.isVisible)
        func score(_ activity: MoodleActivity) -> Int {
            let name = ContentDraftBuilder.fold(activity.name)
            var score = 0
            if name.range(of: #"\b(plan du cours|planning|calendrier|programme|syllabus|schedule|course plan|deroulement|planification|outline|timetable|semesterplan|kursplan)\b"#,
                          options: .regularExpression) != nil { score += 10 }
            let preview = ContentDraftBuilder.fold(activity.preview ?? "")
            score += min(preview.components(separatedBy: .whitespaces).filter { $0 == "semaine" || $0 == "week" || $0 == "woche" }.count, 6)
            score += min(preview.matches(of: /\d{1,2}[.\/]\d{1,2}[.\/]\d{2,4}/).count, 4)
            return score
        }
        let candidates = activities.map { ($0, score($0)) }.filter { $0.1 >= 3 }.sorted { $0.1 > $1.1 }.map(\.0)
        for activity in candidates.prefix(3) {
            guard let url = URL(string: activity.link), url.scheme?.hasPrefix("http") == true,
                  MoocReference.courseKey(in: activity.link) == nil else { continue }
            if let text = await AuthenticatedDownloader.text(at: url), text.count > 200 {
                let folded = ContentDraftBuilder.fold(text)
                // Un vrai calendrier cite plusieurs semaines.
                let weeks = folded.matches(of: /\b(semaine|week|woche|sem\.)\s*\d{1,2}\b/).count
                    + folded.matches(of: /(?m)^\s*\d{1,2}\s+\d{1,2}[.\/]\d{1,2}/).count
                if weeks >= 3 || score(activity) >= 10 { return String(text.prefix(12_000)) }
            }
        }
        return nil
    }
}

@MainActor
enum MoocImport {
    struct Outcome {
        var draft: ContentDraft
        /// « + MOOC Algèbre linéaire (24 leçons) », ou pourquoi il manque.
        var note: String?
        /// Courseware demande une connexion.
        var needsLogin = false
    }

    /// Les MOOC cités par Moodle, lus sur Courseware.
    static func fetch(_ snapshot: MoodleCourseSnapshot, client: CoursewareClient? = nil)
        async -> (moocs: [(key: String, course: ScrapedCourse)], note: String?, needsLogin: Bool) {
        let client = client ?? CoursewareClient()
        let keys = Array(Set(snapshot.moocLinks.compactMap(\.courseKey))).sorted()
        guard !keys.isEmpty else { return ([], nil, false) }
        guard await client.isSignedIn() else {
            return ([], "MOOC cité sur Moodle — connecte-toi à Courseware pour l'ajouter", true)
        }
        var moocs: [(String, ScrapedCourse)] = []
        for key in keys {
            do {
                moocs.append((key, try await client.content(of: key)))
            } catch {
                AppLog.record(.warning, "import", "MOOC illisible", detail: "\(key) — \(error.localizedDescription)")
            }
        }
        return (moocs, nil, false)
    }

    /// Range les leçons demandées de chaque MOOC dans les semaines du cours.
    static func merge(_ draft: ContentDraft, moocs: [(key: String, course: ScrapedCourse)], snapshot: MoodleCourseSnapshot,
                      termStart: Date?, totalWeeks: Int, plannedWeeks: [String: Int],
                      plannedLessons: [String: Int] = [:]) -> (draft: ContentDraft, note: String?) {
        var result = draft
        var notes: [String] = []
        for (index, mooc) in moocs.enumerated() {
            let before = result.theoryCount
            result = MoocMerger.merge(mooc: mooc.course,
                                      references: snapshot.moocLinks.filter { $0.courseKey == mooc.key },
                                      snapshot: snapshot, into: result,
                                      termStart: termStart, totalWeeks: totalWeeks, plannedWeeks: plannedWeeks,
                                      plannedLessons: plannedLessons, ordinal: index + 1)
            let chapters = result.theoryCount - before
            notes.append("+ MOOC \(mooc.course.title) (\(chapters) chapitre\(chapters > 1 ? "s" : "") à travailler)")
        }
        return (result, notes.isEmpty ? nil : notes.joined(separator: " · "))
    }

    static func complete(_ draft: ContentDraft, snapshot: MoodleCourseSnapshot,
                         termStart: Date?, totalWeeks: Int,
                         client: CoursewareClient? = nil) async -> Outcome {
        let client = client ?? CoursewareClient()
        let keys = Array(Set(snapshot.moocLinks.compactMap(\.courseKey))).sorted()
        guard !keys.isEmpty else { return Outcome(draft: draft) }
        guard await client.isSignedIn() else {
            return Outcome(draft: draft, note: "MOOC cité sur Moodle — connecte-toi à Courseware pour l'ajouter", needsLogin: true)
        }
        var result = draft
        var notes: [String] = []
        for key in keys {
            do {
                let mooc = try await client.content(of: key)
                let before = result.theoryCount
                result = MoocMerger.merge(mooc: mooc,
                                          references: snapshot.moocLinks.filter { $0.courseKey == key },
                                          snapshot: snapshot, into: result,
                                          termStart: termStart, totalWeeks: totalWeeks)
                notes.append("+ MOOC \(mooc.title) (\(result.theoryCount - before) leçons)")
            } catch {
                AppLog.record(.warning, "import", "MOOC illisible", detail: "\(key) — \(error.localizedDescription)")
                notes.append("MOOC \(key) illisible")
            }
        }
        return Outcome(draft: result, note: notes.joined(separator: " · "))
    }
}


// MARK: - L'import d'un cours, de bout en bout

/// Tout ce qu'un cours Moodle donne, rangé : la même chaîne pour l'import
/// manuel et pour la mise à jour automatique.
///
/// 1. Moodle (le plan du cours, les cibles des liens) ;
/// 2. le **plan du cours** quand Moodle en cite un, et les MOOC cités ;
/// 3. le modèle range ce que les règles ne savent pas lire — activités aux noms
///    inattendus, chapitres du MOOC à regarder selon le plan ;
/// 4. les règles construisent le brouillon (un élément de théorie par semaine) ;
/// 5. MOOC, Explique et listes MediaSpace complètent chaque semaine.
@MainActor
enum CourseImportPipeline {
    struct Outcome {
        var draft: ContentDraft
        var notes: [String]
        /// Le polycopié Botafogo lu à la place (ou en plus) de Moodle.
        var botafogoTitle: String?
    }

    static func draft(from snapshot: MoodleCourseSnapshot, termStart: Date?, totalWeeks: Int,
                      settings: SettingsStore?, progress: (String) -> Void = { _ in }) async -> Outcome {
        var notes: [String] = []
        // Un cours vide sur Moodle vit ailleurs : le site Botafogo cité par le
        // cours, ou celui du catalogue dont le titre correspond. Lu dès que
        // besoin, et donné au modèle avec le reste.
        let rulesOnly = MoodleCourseAnalyzer.draft(from: snapshot, termStart: termStart, totalWeeks: totalWeeks)
        let thin = rulesOnly.theoryCount + rulesOnly.seriesCount == 0
        var botafogo: ContentDraft?
        var site = BotafogoCatalog.site(in: snapshot)
        if site == nil, thin {
            progress("vide sur Moodle — recherche du site du cours…")
            site = BotafogoCatalog.match(courseName: snapshot.title, in: (try? await BotafogoClient.catalog()) ?? [])
        }
        if let site {
            progress("lecture de Botafogo…")
            botafogo = (try? await BotafogoClient.draft(at: site, termStart: termStart, totalWeeks: totalWeeks)).flatMap { $0.isEmpty ? nil : $0 }
        }
        var moocs: [(key: String, course: ScrapedCourse)] = []
        if !snapshot.moocLinks.isEmpty {
            progress("MOOC cité — lecture de Courseware…")
            let fetched = await MoocImport.fetch(snapshot)
            moocs = fetched.moocs
            if let note = fetched.note { notes.append(note) }
        }
        var answer = MoodleCourseAI.Answer()
        var plan: String?
        if let settings {
            progress("lecture du plan du cours…")
            plan = await CoursePlanReader.text(for: snapshot)
            progress("rangement du cours…")
            answer = await MoodleCourseAIService.analyze(snapshot, termStart: termStart, totalWeeks: totalWeeks,
                                                         plan: plan, moocs: moocs.map(\.course),
                                                         sources: botafogo.map(\.outline), settings: settings)
        }
        if thin, var botafogo {
            // Le cours est sur Botafogo : son programme, avec la consigne de
            // chaque semaine comprise par le modèle.
            botafogo.weekGuide = answer.guide
            notes.append("lu sur Botafogo (vide sur Moodle)")
            return Outcome(draft: botafogo, notes: notes, botafogoTitle: botafogo.courseTitle)
        }
        var draft = MoodleCourseAnalyzer.draft(from: snapshot, termStart: termStart, totalWeeks: totalWeeks, hints: answer.hints)
        // Ce que le modèle a compris du cours entier : où sont les énoncés,
        // et la consigne de chaque semaine.
        draft = MoodleCourseAnalyzer.apply(answer, to: draft, snapshot: snapshot, totalWeeks: totalWeeks)
        if !moocs.isEmpty {
            // Le plan lu ligne par ligne l'emporte ; le modèle complète ce qu'il
            // n'a pas trouvé (un plan d'une autre forme).
            let parsed = plan.map { CoursePlanParser.chapterWeeks(CoursePlanParser.moocAssignments(in: $0, totalWeeks: totalWeeks),
                                                                  moocs: moocs.map(\.course)) } ?? [:]
            // Le plan lu ligne par ligne (« 3 … MOOC 1 : vidéos Module 2 ») est
            // une lecture littérale : il départage le modèle là où ils diffèrent.
            let plannedWeeks = answer.moocWeeks.merging(parsed) { _, literal in literal }
            if !parsed.isEmpty {
                AppLog.record(.info, "import", "Plan du cours lu", detail: "\(parsed.count) chapitres de MOOC rangés d'après le plan")
            }
            let lessons = MoodleCourseAI.lessonWeeks(answer, moocs: moocs.map(\.course))
            let merged = MoocImport.merge(draft, moocs: moocs, snapshot: snapshot, termStart: termStart,
                                          totalWeeks: totalWeeks, plannedWeeks: plannedWeeks, plannedLessons: lessons)
            draft = merged.draft
            if let note = merged.note { notes.append(note) }
        }
        progress("outils du cours…")
        let explique = await ExpliqueSupplement.complete(draft, snapshot: snapshot, termStart: termStart, totalWeeks: totalWeeks)
        draft = explique.draft
        if let note = explique.note { notes.append(note) }
        let media = await MediaSpaceSupplement.complete(draft, snapshot: snapshot, termStart: termStart, totalWeeks: totalWeeks)
        draft = media.draft
        if let note = media.note { notes.append(note) }
        if let botafogo {
            // Moodle et Botafogo à la fois : ce que Moodle n'a pas (une série,
            // la théorie d'une semaine) vient de Botafogo.
            draft = draft.completed(with: botafogo)
            notes.append("+ Botafogo")
        }
        return Outcome(draft: draft, notes: notes, botafogoTitle: nil)
    }
}
