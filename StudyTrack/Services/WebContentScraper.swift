import Foundation
import WebKit

/// Lit la page d'un cours dans le navigateur intégré.
///
/// Le script ne fait que **rapporter** ce qu'il voit — titres, liens, type de
/// module — sous la forme d'un `ScrapedCourse` en JSON. Aucune règle métier ici :
/// décider qu'un « Corrigé » s'ignore ou qu'une section datée tombe en semaine 3
/// est le travail de `ContentDraftBuilder`, en Swift pur et testé.
///
/// Le script tourne **dans la session de l'étudiant·e** : c'est ce qui rend la
/// lecture possible sans API. Rien ne quitte l'appareil.
enum WebContentScraper {

    enum ScrapeError: LocalizedError {
        case notACoursePage(ContentSource)
        case unreadable(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .notACoursePage(.moodle):
                return "Ouvre la page d'un cours Moodle (celle qui liste les semaines), puis réessaie."
            case .notACoursePage(.courseware):
                return "Ouvre un cours Courseware (son plan ou une leçon), puis réessaie."
            case .notACoursePage:
                return "Ouvre la page du cours, puis réessaie."
            case .unreadable(let detail):
                return "Lecture de la page impossible — \(detail)"
            case .empty:
                return "La page ne contient ni théorie ni série reconnaissables."
            }
        }
    }

    /// La page affichée est-elle celle d'un cours ?
    static func isCoursePage(_ url: URL?, source: ContentSource) -> Bool {
        guard let url else { return false }
        let text = url.absoluteString
        switch source {
        case .moodle: return text.contains("/course/view.php") || text.contains("/course/section.php")
        case .courseware: return text.contains("course-v1:") || text.contains("course-v1%3A")
        case .botafogo: return url.host?.contains("botafogo") == true && url.path.count > 1
        }
    }

    @MainActor
    static func scrape(_ webView: WKWebView, source: ContentSource) async throws -> ScrapedCourse {
        guard isCoursePage(webView.url, source: source) else { throw ScrapeError.notACoursePage(source) }
        if source == .botafogo, let url = webView.url {
            return try await BotafogoClient.course(at: BotafogoClient.courseRoot(of: url))
        }
        let script = source == .moodle ? moodleScript : coursewareScript
        let raw: Any?
        do {
            raw = try await webView.callAsyncJavaScript(script, contentWorld: .defaultClient)
        } catch {
            throw ScrapeError.unreadable(error.localizedDescription)
        }
        guard let json = raw as? String, let data = json.data(using: .utf8) else {
            throw ScrapeError.unreadable("réponse vide")
        }
        if let failure = try? JSONDecoder().decode([String: String].self, from: data), let message = failure["error"] {
            throw ScrapeError.unreadable(message)
        }
        do {
            let page = try JSONDecoder().decode(ScrapedCourse.self, from: data)
            guard page.sections.contains(where: { !$0.items.isEmpty }) else { throw ScrapeError.empty }
            return page
        } catch let error as ScrapeError {
            throw error
        } catch {
            throw ScrapeError.unreadable(error.localizedDescription)
        }
    }

    // MARK: Moodle

    /// Moodle 4 : une `li.section` (ou `.course-section`) par semaine ou thème,
    /// une `li.activity` par élément, le type dans la classe `modtype_…`.
    /// Les sous-sections (Moodle 4.5) sont des sections imbriquées : chaque
    /// activité n'est rattachée qu'à sa section la plus proche.
    static let moodleScript = #"""
    const clean = t => (t || '').replace(/\s+/g, ' ').trim();
    const heading = document.querySelector('.page-header-headings h1, #page-header h1, h1');
    const title = clean(heading ? heading.innerText : document.title);
    const sectionSelector = 'li.section, li.course-section';
    const sections = [];
    document.querySelectorAll(sectionSelector).forEach(sec => {
      const nameEl = sec.querySelector('.sectionname, .course-section-header h3, [data-for="section_title"], h3');
      let name = clean(nameEl ? nameEl.innerText : sec.getAttribute('aria-label'));
      const items = [];
      sec.querySelectorAll('li.activity').forEach(act => {
        if (act.closest(sectionSelector) !== sec) return;
        const type = ((act.className.match(/modtype_(\w+)/) || [])[1] || '');
        const nameNode = act.querySelector('.instancename, .activityname, [data-activityname]');
        let text = '';
        if (nameNode) {
          const copy = nameNode.cloneNode(true);
          copy.querySelectorAll('.accesshide, .sr-only, .visually-hidden').forEach(e => e.remove());
          text = clean(copy.innerText || copy.textContent);
        }
        if (!text) text = clean(act.getAttribute('data-activityname'));
        if (!text) return;
        const link = act.querySelector('a.aalink, a[href*="/mod/"]');
        items.push({ title: text, url: link ? link.href : '', type: type });
      });
      sections.push({ title: name, items: items });
    });
    if (sections.length === 0) return JSON.stringify({ error: "aucune section trouvée sur cette page" });
    return JSON.stringify({ source: 'moodle', title: title, url: location.href, sections: sections });
    """#

    // MARK: Courseware (Open edX)

    /// Open edX expose le plan du cours à l'étudiant·e connecté·e :
    /// `/api/course_home/outline/<clé>` (chapitres → leçons). Le nombre de vidéos
    /// par leçon vient de l'API des blocs, quand elle répond ; sinon on s'en passe.
    static let coursewareScript = #"""
    const match = decodeURIComponent(location.href).match(/(course-v1:[^/?#]+)/);
    if (!match) return JSON.stringify({ error: "ouvre la page d'un cours" });
    const key = match[1];
    const lms = 'https://courseware.epfl.ch';
    const get = async (path) => {
      try {
        const r = await fetch(lms + path, { credentials: 'include', headers: { 'Accept': 'application/json' } });
        return r.ok ? await r.json() : null;
      } catch (e) { return null; }
    };
    const outline = await get('/api/course_home/outline/' + encodeURIComponent(key))
                 || await get('/api/course_home/v1/outline/' + encodeURIComponent(key));
    const blocks = outline && outline.course_blocks && outline.course_blocks.blocks;
    if (!blocks) return JSON.stringify({ error: "plan du cours illisible — es-tu connecté·e et inscrit·e à ce cours ?" });

    let counts = {};
    const me = await get('/api/user/v1/me');
    if (me && me.username) {
      const q = '/api/courses/v2/blocks/?course_id=' + encodeURIComponent(key)
        + '&username=' + encodeURIComponent(me.username)
        + '&depth=all&block_counts=video&requested_fields=block_counts';
      const tree = await get(q);
      if (tree && tree.blocks) {
        Object.values(tree.blocks).forEach(b => { if (b.block_counts) counts[b.id] = b.block_counts.video || 0; });
      }
    }

    const all = Object.values(blocks);
    const root = all.find(b => b.type === 'course');
    const chapters = root ? (root.children || []).map(id => blocks[id]).filter(Boolean)
                          : all.filter(b => b.type === 'chapter');
    const sections = chapters.map(ch => ({
      title: ch.display_name || '',
      items: (ch.children || []).map(id => blocks[id]).filter(Boolean).map(seq => ({
        title: seq.display_name || '',
        url: seq.lms_web_url || '',
        type: 'sequential',
        videoCount: counts[seq.id] !== undefined ? counts[seq.id] : null
      }))
    }));
    const title = (root && root.display_name) || document.title;
    return JSON.stringify({ source: 'courseware', title: title, url: location.href, sections: sections });
    """#
}

// MARK: - Botafogo

/// Botafogo est public : ni navigateur ni connexion, on lit les pages.
enum BotafogoClient {

    static let home = URL(string: "https://botafogo.epfl.ch/")!

    /// Les polycopiés proposés sur la page d'accueil.
    static func catalog(session: URLSession = .shared) async throws -> [(title: String, url: URL)] {
        let html = try await text(at: home, session: session)
        return BotafogoParser.catalog(html: html, baseURL: home)
    }

    /// `…/analyse-1/resources/sections/x.html` → `…/analyse-1/`.
    static func courseRoot(of url: URL) -> URL {
        let parts = url.path.split(separator: "/")
        guard let first = parts.first else { return home }
        return URL(string: "/\(first)/", relativeTo: home)?.absoluteURL ?? home
    }

    /// La table des matières, puis chaque section pour y compter les vidéos.
    ///
    /// Huit pages à la fois : une centaine de sections se lisent en quelques
    /// secondes sans charger le serveur d'un enseignant.
    static func course(at url: URL, session: URLSession = .shared) async throws -> ScrapedCourse {
        let html = try await text(at: url, session: session)
        var page = BotafogoParser.parseTOC(html: html, baseURL: url)
        guard !page.sections.isEmpty else { throw WebContentScraper.ScrapeError.empty }

        var targets: [(section: Int, item: Int, url: URL)] = []
        for (s, section) in page.sections.enumerated() {
            for (i, item) in section.items.enumerated() {
                if let itemURL = URL(string: item.url) { targets.append((s, i, itemURL)) }
            }
        }
        try await withThrowingTaskGroup(of: (Int, Int, Int).self) { group in
            var iterator = targets.makeIterator()
            func enqueue() {
                guard let next = iterator.next() else { return }
                group.addTask {
                    let body = (try? await text(at: next.url, session: session)) ?? ""
                    return (next.section, next.item, BotafogoParser.videoTitles(inSection: body).count)
                }
            }
            for _ in 0..<8 { enqueue() }
            while let (s, i, count) = try await group.next() {
                page.sections[s].items[i].videoCount = count
                enqueue()
            }
        }
        return page
    }

    private static func text(at url: URL, session: URLSession) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WebContentScraper.ScrapeError.unreadable("le serveur a répondu \(http.statusCode)")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Téléchargement dans la session

/// Télécharge un fichier protégé (le PDF d'une série sur Moodle) avec les
/// cookies de la connexion faite dans le navigateur intégré.
enum AuthenticatedDownloader {

    @MainActor
    static func download(_ url: URL) async throws -> URL {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        // Tous les cookies EPFL : une ressource Moodle redirige vers
        // `pluginfile.php`, parfois via la page de connexion.
        let relevant = cookies.filter { cookie in
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return domain.hasSuffix("epfl.ch") || url.host?.hasSuffix(domain) == true
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage?.setCookies(relevant, for: url, mainDocumentURL: url)
        for cookie in relevant { configuration.httpCookieStorage?.setCookie(cookie) }
        let session = URLSession(configuration: configuration)
        let (temporary, response) = try await session.download(from: url)
        let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard type.contains("pdf") || response.suggestedFilename?.lowercased().hasSuffix(".pdf") == true else {
            throw WebContentScraper.ScrapeError.unreadable("ce lien ne mène pas à un PDF (connexion expirée ?)")
        }
        let name = response.suggestedFilename ?? "serie.pdf"
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + name)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
}
