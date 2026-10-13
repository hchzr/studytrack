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
final class SchoolConnect {
    static let shared = SchoolConnect()

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

    /// `needsYou` : le site demande quelque chose que seule la personne peut
    /// faire (mot de passe, validation Authenticator, clé d'accès) — la page
    /// cachée s'arrête tout de suite au lieu d'attendre pour rien.
    enum State: Equatable { case unknown, connecting, connected, failed, needsYou }

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

    func state(_ site: Site) -> State { states[site] ?? (waiting.contains(site.rawValue) ? .needsYou : .unknown) }

    /// Les sites qui attendent la personne, retenus d'un lancement à l'autre :
    /// la page de validation de Microsoft envoie une notification Authenticator
    /// à chaque chargement — on ne la recharge pas en silence à chaque
    /// lancement. Effacé dès que la connexion réussit (la feuille).
    private var waiting: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "school.waitingForYou") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "school.waitingForYou") }
    }

    /// Les sites que l'école a (son profil) : on ne se connecte qu'à eux.
    var sites: [Site] {
        let school = Institution.current
        return Site.allCases.filter { site in
            switch site {
            case .moodle: return school.moodle != nil
            case .courseware: return school.openEdX != nil
            case .mediaspace: return school.video != nil
            case .ed: return school.ed != nil
            }
        }
    }

    var allConnected: Bool { sites.allSatisfy { state($0) == .connected } }

    /// Un site attend la personne (mot de passe, Authenticator…).
    var needsYou: Bool { sites.contains { state($0) == .needsYou } }

    /// Où montrer la feuille de connexion : Microsoft passe par Moodle ;
    /// MediaSpace a son propre mot de passe (edu-ID).
    var signInSite: StudySite? {
        if [.moodle, .courseware, .ed].contains(where: { state($0) == .needsYou }) { return .moodle }
        if state(.mediaspace) == .needsYou { return .mediaspace }
        return nil
    }

    /// Ouvre la feuille de connexion du bureau quand un site attend la
    /// personne — seulement quand elle est en train de lire un site (pas au
    /// lancement de l'app, où une feuille surgirait sans raison).
    private func prompt() {
        guard needsYou, SiteHub.shared.signIn == nil, let site = signInSite else { return }
        SiteHub.shared.signIn = site
    }

    /// Ouvre chaque site dans la session Microsoft, l'un après l'autre.
    /// `force` : après la feuille de connexion, on réessaie aussi les sites qui
    /// attendaient la personne.
    func connectAll(prompting: Bool = false, force: Bool = false) async {
        guard !isRunning else {
            while isRunning { try? await Task.sleep(for: .milliseconds(400)) }
            if prompting { prompt() }
            return
        }
        isRunning = true
        defer { isRunning = false; revision += 1 }
        // Tous les sites en même temps (chacun sa page cachée, mêmes cookies) :
        // l'attente est celle du plus lent, pas la somme.
        await withTaskGroup(of: Void.self) { group in
            for site in sites {
                if !force, waiting.contains(site.rawValue) {
                    states[site] = .needsYou
                    continue
                }
                group.addTask { await self.connect(site) }
            }
        }
        if prompting { prompt() }
    }

    /// Avant de lire un site : connecté·e, ou on s'y connecte sans rien afficher
    /// (en attendant la connexion déjà en cours, s'il y en a une).
    func ensure(_ site: Site, prompting: Bool = true) async {
        // On n'attend que ce site : Courseware prêt n'attend pas Ed.
        while isRunning, [.unknown, .connecting].contains(state(site)) { try? await Task.sleep(for: .milliseconds(400)) }
        if state(site) != .connected, !waiting.contains(site.rawValue) { await connect(site) }
        if prompting { prompt() }
    }

    /// La session d'un site a expiré en cours de lecture : on s'y reconnecte
    /// (sans rien afficher), sauf s'il attend déjà la personne.
    func refresh(_ site: Site) async {
        if state(site) == .connected { states[site] = nil }
        await ensure(site)
    }

    func connect(_ site: Site) async {
        let school = Institution.current
        guard sites.contains(site) else { return }
        states[site] = .connecting
        let driver = SSODriver()
        let done: Bool
        switch site {
        case .moodle:
            done = await driver.run(start: URL(string: school.moodleBase + "/login/index.php")!) { url, view in
                if url.host == school.moodleHostName {
                    // Déjà connecté·e, même sur la page de connexion (Moodle y
                    // demande alors « se déconnecter ? ») : c'est fait.
                    if (try? await view.evaluateJavaScript(Self.moodleSignedIn)) as? Bool == true { return true }
                    if url.path.hasPrefix("/login") { _ = try? await view.evaluateJavaScript(Self.clickOAuth(school)) }
                    return false
                }
                await Self.answerMicrosoft(view, email: self.email)
                return false
            }
            if done, email == nil { email = await driver.moodleEmail() }
        case .courseware:
            let backend = school.openEdX?.loginBackend.map { "/auth/login/\($0)/?auth_entry=login&next=%2Fdashboard" } ?? "/login"
            done = await driver.run(start: URL(string: school.coursewareBase + backend)!) { url, view in
                if let sso = school.openEdX?.ssoHost, url.host == sso, url.path.hasPrefix("/login"), let idp = school.openEdX?.ssoIdP {
                    _ = try? await view.evaluateJavaScript(Self.chooseSSOIdP(idp))
                    return false
                }
                if url.host == school.coursewareHostName {
                    return (try? await view.callAsyncJavaScript(Self.coursewareSignedIn, contentWorld: .page)) as? Bool == true
                }
                await Self.answerMicrosoft(view, email: self.email)
                return false
            }
        case .mediaspace:
            done = await driver.run(start: URL(string: "https://\(school.videoHostName)/user/login")!) { url, view in
                if let wayf = school.video?.wayfHost, url.host == wayf, let idp = school.video?.identityProvider {
                    _ = try? await view.evaluateJavaScript(Self.chooseWAYF(idp))
                    return false
                }
                if url.host == school.videoHostName {
                    return (try? await view.evaluateJavaScript(Self.mediaspaceSignedIn)) as? Bool == true
                }
                await Self.answerEduID(view, email: self.email)
                await Self.answerMicrosoft(view, email: self.email)
                return false
            }
        case .ed:
            guard let email else { states[site] = .failed; return }
            var asked = false
            done = await driver.run(start: URL(string: "https://edstem.org/\(school.edRegion)/login")!) { url, view in
                if url.host == "edstem.org" {
                    if (try? await view.evaluateJavaScript("!!localStorage.getItem('authToken')")) as? Bool == true { return true }
                    if url.path.hasPrefix("/\(school.edRegion)/login"), !asked {
                        asked = true
                        _ = try? await view.callAsyncJavaScript(Self.edLogin, arguments: ["email": email, "region": school.edRegion],
                                                                contentWorld: .page)
                    }
                    return false
                }
                await Self.answerMicrosoft(view, email: email)
                return false
            }
        }
        states[site] = done ? .connected : (driver.needsPerson ? .needsYou : .failed)
        if done { waiting.remove(site.rawValue) } else if driver.needsPerson { waiting.insert(site.rawValue) }
        log.notice("connexion \(site.rawValue, privacy: .public) : \(done ? "ok" : (driver.needsPerson ? "à toi (\(driver.reason ?? "?"))" : "échec"), privacy: .public)")
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
        guard let idp = Institution.current.video?.passwordIdPHost, view.url?.host?.contains(idp) == true, let email else { return }
        _ = try? await view.callAsyncJavaScript(#"""
        // La page du mot de passe est à la personne : on n'y touche pas (un clic
        // sur « Continuer » l'envoyait vide — « La connexion a échoué »).
        const visible = e => !!(e && (e.offsetWidth || e.offsetHeight || e.getClientRects().length));
        if (document.querySelector('form#passwordForm') || [...document.querySelectorAll('input[type="password"]')].some(visible)) return;
        const field = document.querySelector('form#loginForm input[type="email"], form#loginForm input[name="username"], form#loginForm input[name="j_username"], input#username');
        if (field && !field.value) {
          field.value = email;
          field.dispatchEvent(new Event('input', { bubbles: true }));
          const button = field.form.querySelector('button[type="submit"], input[type="submit"], button[name="_eventId_proceed"]');
          if (button) { button.click(); } else { field.form.submit(); }
          return;
        }
        const pattern = new RegExp(school + '|microsoft', 'i');
        const external = [...document.querySelectorAll('a, button')].find(b => pattern.test(b.innerText || ''));
        if (external && !/help|aide/i.test(external.innerText)) external.click();
        """#, arguments: ["email": email, "school": Institution.current.id], contentWorld: .page)
    }

    // MARK: Scripts (observés sur les vraies pages)

    /// Une page que seule la personne peut passer, ou `nil`. Observé : quand
    /// Microsoft redemande la validation, la page porte un formulaire vers
    /// `/common/SAS/ProcessAuth` (Authenticator, SMS) ; sinon un champ de mot de
    /// passe visible (Microsoft, edu-ID), ou une clé d'accès.
    /// Les pages d'identité où la personne peut être attendue : Microsoft, et
    /// le fournisseur à mot de passe de la vidéo (edu-ID). Les pages
    /// intermédiaires (OpenLearnity, WAYF) ont aussi des champs : l'app y
    /// choisit l'école, elles ne comptent pas.
    static func isIdentityProvider(_ host: String) -> Bool {
        host.hasSuffix("microsoftonline.com") || host.hasSuffix("login.live.com")
            || Institution.current.video?.passwordIdPHost.map { host.hasSuffix($0) } == true
    }

    static let personStep = #"""
    (() => {
      const visible = e => !!(e && (e.offsetWidth || e.offsetHeight || e.getClientRects().length));
      if ([...document.querySelectorAll('form[action*="/SAS/"]')].length || document.querySelector('#idDiv_SAOTCAS_Title, #idDiv_SAOTCC_Title, #idRichContext_DisplaySign')) return 'validation';
      if ([...document.querySelectorAll('input[type="password"]')].some(visible)) return 'mot de passe';
      if (/fido|passkey/i.test(location.pathname)) return 'clé d’accès';
      return '';
    })()
    """#

    /// Le bouton de connexion OAuth de Moodle (EPFL : `id=3`, « Entra ID »).
    static func clickOAuth(_ school: Institution) -> String {
        let id = school.moodle?.oauthProviderID.map(String.init) ?? ""
        return """
        (() => { const a = document.querySelector('a[href*="auth/oauth2/login.php?id=\(id)"]'); if (a) { location.href = a.href; return true; } return false; })()
        """
    }
    static var clickEntra: String { clickOAuth(Institution.current) }
    /// Le menu du compte, ou « Vous êtes connecté·e en tant que … (Déconnexion) »
    /// en bas de page — seul signe sur la page de connexion quand la session
    /// existe déjà (observé).
    static let moodleSignedIn = "!!document.querySelector('#user-menu-toggle, .usermenu .userbutton, .logininfo a[href*=\"login/logout.php\"]')"
    static func chooseSSOIdP(_ idp: String) -> String {
        """
        (() => { const next = new URLSearchParams(location.search).get('next') || '/';
          location.href = '/auth/login/tpa-saml/?auth_entry=login&idp=\(idp)&next=' + encodeURIComponent(next); return true; })()
        """
    }
    static let coursewareSignedIn = "const r = await fetch('/api/user/v1/me', { credentials: 'include' }); return r.status === 200;"
    static func chooseWAYF(_ idp: String) -> String {
        """
        (() => { const s = document.querySelector('select[name="user_idp"]'); if (!s) return false;
          s.value = '\(idp)'; s.form.submit(); return true; })()
        """
    }
    static var chooseWAYFEPFL: String { chooseWAYF(Institution.current.video?.identityProvider ?? "") }
    static let mediaspaceSignedIn = "!!document.querySelector('a[href*=\"/user/logout\"]')"
    static let edLogin = """
    const r = await fetch('https://' + region + '.edstem.org/api/login_type', { method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ login: email, redirect: '/' + region + '/dashboard' }) });
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
    /// La chaîne s'est arrêtée sur une page pour la personne (et laquelle).
    private(set) var needsPerson = false
    private(set) var reason: String?
    /// Depuis quand une page pour la personne est affichée : Microsoft montre
    /// parfois une étape un instant puis passe seul (observé sur Courseware) —
    /// on n'abandonne que si elle reste.
    private var personSince: Date?

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
        // Pendant un chargement, la page n'accepte pas de script : on attend
        // `didFinish` (sinon WebKit journalise « runJavaScript failed »).
        guard !busy, !view.isLoading, let step, let url = view.url, finished != nil else { return }
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
        if let host = url.host, SchoolConnect.isIdentityProvider(host),
           let reason = await personStep(), !reason.isEmpty {
            let since = personSince ?? Date()
            personSince = since
            busy = false
            if Date().timeIntervalSince(since) >= 4 {
                needsPerson = true
                self.reason = reason
                finish(false)
            }
            return
        }
        personSince = nil
        let done = await step(url, view)
        busy = false
        if done { finish(true) }
    }

    private func personStep() async -> String? {
        do {
            let value = try await view.evaluateJavaScript(SchoolConnect.personStep)
            #if DEBUG
            if CommandLine.arguments.contains("-epflTrace") { FileHandle.standardError.write(Data("PERSON \(value ?? "nil")\n".utf8)) }
            #endif
            return value as? String
        } catch {
            #if DEBUG
            if CommandLine.arguments.contains("-epflTrace") { FileHandle.standardError.write(Data("PERSON erreur \(error)\n".utf8)) }
            #endif
            return nil
        }
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
