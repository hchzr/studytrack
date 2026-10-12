import Foundation
import Observation
import OSLog
import WebKit

/// Une seule connexion EPFL, puis l'app fait le reste.
///
/// Observé (rétro-ingénierie, session réelle) : les quatre sites finissent tous
/// chez Microsoft Entra, locataire de l'EPFL :
/// - **Moodle** : `/auth/oauth2/login.php?id=3` (« EPFL – Entra ID ») ;
/// - **Courseware** : `/auth/login/edx-oauth2/` → OpenLearnity
///   (`id.openlearnity.org`) → SAML `idp=epfl-ol` → `idp.epfl.ch` → Entra ;
/// - **MediaSpace** : SWITCH WAYF (formulaire `IdPList`, champ `user_idp`,
///   EPFL = `https://idp.epfl.ch/idp/shibboleth`) → Entra ;
/// - **Ed** : `POST eu.edstem.org/api/login_type {login: courriel}` rend une
///   redirection SAML vers Entra pour une adresse `@epfl.ch`.
///
/// La feuille de connexion ne montre donc que Microsoft (une fois, « rester
/// connecté »). Ensuite chaque site est ouvert **sans l'afficher** : la session
/// Microsoft des cookies WebKit répond à sa place, et l'on choisit l'EPFL aux
/// étapes intermédiaires (WAYF, OpenLearnity, Ed).
@MainActor
@Observable
final class EPFLConnect {
    static let shared = EPFLConnect()

    enum Site: String, CaseIterable, Identifiable {
        case moodle, courseware, mediaspace, ed
        var id: String { rawValue }
        var title: String {
            switch self {
            case .moodle: return "Moodle"
            case .courseware: return "Courseware"
            case .mediaspace: return "MediaSpace"
            case .ed: return "Ed"
            }
        }
    }

    enum State: Equatable { case unknown, connecting, connected, failed }

    private(set) var states: [Site: State] = [:]
    private(set) var isRunning = false
    /// Augmente après chaque connexion : les lecteurs se rechargent.
    private(set) var revision = 0

    /// L'adresse EPFL (pour Ed), lue sur Moodle une fois connecté·e.
    var email: String? {
        get { UserDefaults.standard.string(forKey: "mac.epflEmail") }
        set { UserDefaults.standard.set(newValue, forKey: "mac.epflEmail") }
    }

    @ObservationIgnored private let log = Logger(subsystem: "com.hczr.studytrack.mac", category: "epfl")

    func state(_ site: Site) -> State { states[site] ?? .unknown }

    var allConnected: Bool { Site.allCases.allSatisfy { state($0) == .connected } }

    /// Ouvre chaque site dans la session Microsoft, l'un après l'autre.
    func connectAll() async {
        guard !isRunning else {
            while isRunning { try? await Task.sleep(for: .milliseconds(400)) }
            return
        }
        isRunning = true
        defer { isRunning = false; revision += 1 }
        for site in Site.allCases { await connect(site) }
    }

    /// Avant de lire un site : connecté·e, ou on s'y connecte sans rien afficher
    /// (en attendant la connexion déjà en cours, s'il y en a une).
    func ensure(_ site: Site) async {
        while isRunning, state(site) != .connected { try? await Task.sleep(for: .milliseconds(400)) }
        if state(site) != .connected { await connect(site) }
    }

    func connect(_ site: Site) async {
        states[site] = .connecting
        let driver = SSODriver()
        let done: Bool
        switch site {
        case .moodle:
            done = await driver.run(start: URL(string: "https://moodle.epfl.ch/login/index.php")!) { url, view in
                if url.host == "moodle.epfl.ch", url.path.hasPrefix("/login") {
                    _ = try? await view.evaluateJavaScript(Self.clickEntra)
                    return false
                }
                if url.host == "moodle.epfl.ch" {
                    return (try? await view.evaluateJavaScript(Self.moodleSignedIn)) as? Bool == true
                }
                await Self.answerMicrosoft(view, email: self.email)
                return false
            }
            if done, email == nil { email = await driver.moodleEmail() }
        case .courseware:
            done = await driver.run(start: URL(string: "https://courseware.epfl.ch/auth/login/edx-oauth2/?auth_entry=login&next=%2Fdashboard")!) { url, view in
                if url.host == "id.openlearnity.org", url.path.hasPrefix("/login") {
                    _ = try? await view.evaluateJavaScript(Self.chooseOpenLearnityEPFL)
                    return false
                }
                if url.host == "courseware.epfl.ch" {
                    return (try? await view.callAsyncJavaScript(Self.coursewareSignedIn, contentWorld: .page)) as? Bool == true
                }
                await Self.answerMicrosoft(view, email: self.email)
                return false
            }
        case .mediaspace:
            done = await driver.run(start: URL(string: "https://mediaspace.epfl.ch/user/login")!) { url, view in
                if url.host == "wayf.switch.ch" {
                    _ = try? await view.evaluateJavaScript(Self.chooseWAYFEPFL)
                    return false
                }
                if url.host == "mediaspace.epfl.ch" {
                    return (try? await view.evaluateJavaScript(Self.mediaspaceSignedIn)) as? Bool == true
                }
                await Self.answerEduID(view, email: self.email)
                await Self.answerMicrosoft(view, email: self.email)
                return false
            }
        case .ed:
            guard let email else { states[site] = .failed; return }
            var asked = false
            done = await driver.run(start: URL(string: "https://edstem.org/eu/login")!) { url, view in
                if url.host == "edstem.org" {
                    if (try? await view.evaluateJavaScript("!!localStorage.getItem('authToken')")) as? Bool == true { return true }
                    if url.path.hasPrefix("/eu/login"), !asked {
                        asked = true
                        _ = try? await view.callAsyncJavaScript(Self.edLogin, arguments: ["email": email], contentWorld: .page)
                    }
                    return false
                }
                await Self.answerMicrosoft(view, email: email)
                return false
            }
        }
        states[site] = done ? .connected : .failed
        log.notice("connexion \(site.rawValue, privacy: .public) : \(done ? "ok" : "échec", privacy: .public)")
    }

    /// Les pages de Microsoft qui demandent un clic, quand la session existe
    /// déjà : choisir le compte, « Rester connecté ? » → oui.
    static func answerMicrosoft(_ view: WKWebView, email: String?) async {
        guard view.url?.host?.contains("microsoftonline.com") == true || view.url?.host?.contains("login.live.com") == true else { return }
        _ = try? await view.callAsyncJavaScript(#"""
        const tile = [...document.querySelectorAll('[data-test-id], .table[role="button"], .tile')]
          .find(t => email && (t.getAttribute('data-test-id') === email || (t.textContent || '').includes(email)));
        if (tile) { tile.click(); return; }
        const yes = document.querySelector('#idSIButton9');
        if (yes && /kmsi|reprocess/i.test(location.href + document.body.innerText)) { yes.click(); }
        """#, arguments: ["email": email ?? ""], contentWorld: .page)
    }

    /// SWITCH edu-ID (`epfl.login.eduid.ch`, où mène l'IdP de l'EPFL pour
    /// MediaSpace — observé) : la page de stockage local s'envoie seule ; la
    /// page « E-mail » reçoit l'adresse EPFL, puis edu-ID renvoie vers Microsoft.
    static func answerEduID(_ view: WKWebView, email: String?) async {
        guard view.url?.host?.contains("eduid.ch") == true, let email else { return }
        _ = try? await view.callAsyncJavaScript(#"""
        const field = document.querySelector('form#loginForm input[type="email"], form#loginForm input[name="username"], form#loginForm input[name="j_username"], input#username');
        if (field && !field.value) {
          field.value = email;
          field.dispatchEvent(new Event('input', { bubbles: true }));
          const button = field.form.querySelector('button[type="submit"], input[type="submit"], button[name="_eventId_proceed"]');
          if (button) { button.click(); } else { field.form.submit(); }
          return;
        }
        const external = [...document.querySelectorAll('a, button')].find(b => /epfl|microsoft|continuer|continue|weiter/i.test(b.innerText || ''));
        if (external && !/help|aide/i.test(external.innerText)) external.click();
        """#, arguments: ["email": email], contentWorld: .page)
    }

    // MARK: Scripts (observés sur les vraies pages)

    static let clickEntra = """
    (() => { const a = document.querySelector('a[href*="auth/oauth2/login.php?id=3"]'); if (a) { location.href = a.href; return true; } return false; })()
    """
    static let moodleSignedIn = "!!document.querySelector('#user-menu-toggle, .usermenu .userbutton')"
    static let chooseOpenLearnityEPFL = """
    (() => { const next = new URLSearchParams(location.search).get('next') || '/';
      location.href = '/auth/login/tpa-saml/?auth_entry=login&idp=epfl-ol&next=' + encodeURIComponent(next); return true; })()
    """
    static let coursewareSignedIn = "const r = await fetch('/api/user/v1/me', { credentials: 'include' }); return r.status === 200;"
    static let chooseWAYFEPFL = """
    (() => { const s = document.querySelector('select[name="user_idp"]'); if (!s) return false;
      s.value = 'https://idp.epfl.ch/idp/shibboleth'; s.form.submit(); return true; })()
    """
    static let mediaspaceSignedIn = "!!document.querySelector('a[href*=\"/user/logout\"]')"
    static let edLogin = """
    const r = await fetch('https://eu.edstem.org/api/login_type', { method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ login: email, redirect: '/eu/dashboard' }) });
    const d = await r.json();
    if (d.url) { location.href = d.url; return true; }
    return false;
    """
}

/// Un navigateur invisible qui suit une chaîne de connexion : à chaque page
/// chargée (et chaque seconde, pour les pages qui changent sans recharger),
/// `step` regarde où l'on est, agit, et dit si c'est fini.
@MainActor
final class SSODriver: NSObject, WKNavigationDelegate {
    private let view: WKWebView
    private var step: ((URL, WKWebView) async -> Bool)?
    private var finished: CheckedContinuation<Bool, Never>?
    private var busy = false

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        view = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 900), configuration: configuration)
        view.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        super.init()
        view.navigationDelegate = self
    }

    func run(start: URL, timeout: TimeInterval = 40, step: @escaping (URL, WKWebView) async -> Bool) async -> Bool {
        self.step = step
        return await withCheckedContinuation { continuation in
            finished = continuation
            view.load(URLRequest(url: start))
            Task { @MainActor in
                let deadline = Date().addingTimeInterval(timeout)
                while Date() < deadline, finished != nil {
                    try? await Task.sleep(for: .seconds(1))
                    await check()
                }
                finish(false)
            }
        }
    }

    /// L'adresse électronique du compte, lue sur la page de profil de Moodle.
    func moodleEmail() async -> String? {
        let value = try? await view.callAsyncJavaScript("""
        const r = await fetch('/user/edit.php', { credentials: 'include' });
        const doc = new DOMParser().parseFromString(await r.text(), 'text/html');
        const e = doc.querySelector('#id_email');
        return e ? e.value : '';
        """, contentWorld: .page)
        let email = (value as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return email.contains("@") ? email : nil
    }

    private func check() async {
        guard !busy, let step, let url = view.url, finished != nil else { return }
        #if DEBUG
        if CommandLine.arguments.contains("-epflTrace") {
            FileHandle.standardError.write(Data("SSO \(url.absoluteString.prefix(160))\n".utf8))
            if url.host?.contains("eduid") == true || url.host?.contains("microsoft") == true,
               let page = try? await view.evaluateJavaScript("[...document.querySelectorAll('a,button,input,form')].map(e => e.tagName + ' ' + (e.id||'') + ' ' + (e.name||'') + ' ' + (e.getAttribute('href')||e.getAttribute('action')||'') + ' ' + (e.innerText||e.value||'').trim().slice(0,40)).join(' | ')") as? String {
                FileHandle.standardError.write(Data("PAGE \(page.prefix(1500))\n".utf8))
            }
        }
        #endif
        busy = true
        let done = await step(url, view)
        busy = false
        if done { finish(true) }
    }

    private func finish(_ value: Bool) {
        guard let finished else { return }
        self.finished = nil
        finished.resume(returning: value)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in await self.check() }
    }
}
