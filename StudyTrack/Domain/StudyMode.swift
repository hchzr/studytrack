import Foundation

/// Le **mode étude** : pendant une session, le Mac et l'iPhone n'ouvrent que ce
/// qui sert à travailler — les sites de cours (Moodle, Courseware, Botafogo…),
/// Claude pour l'aide, GoodNotes pour écrire.
///
/// Il n'a pas d'état à lui : c'est une date (`FocusTimerState.studyUntil`) portée
/// par le chrono partagé. Démarré sur un appareil, il arrive sur l'autre par les
/// mêmes voies que « play » ; terminer la session le termine partout. Les
/// décisions sont ici, pures et testées ; le blocage lui-même est propre à
/// chaque système (fenêtres et activations sur le Mac, Temps d'écran sur
/// l'iPhone).
enum StudyMode {

    /// Les durées proposées au lancement, en minutes.
    static let durations = [25, 50, 90, 120]

    // MARK: Pendant la session

    /// Le mode étude est-il en vigueur à `now` ?
    static func isActive(_ state: FocusTimerState?, at now: Date = Date()) -> Bool {
        guard let until = state?.studyUntil else { return false }
        return now < until
    }

    /// Ce qui reste, en secondes (zéro une fois passé).
    static func remaining(_ state: FocusTimerState?, at now: Date = Date()) -> TimeInterval {
        guard let until = state?.studyUntil else { return 0 }
        return max(0, until.timeIntervalSince(now))
    }

    /// La fraction écoulée du mode étude (0 → 1), depuis `studySince`.
    static func progress(_ state: FocusTimerState?, at now: Date = Date()) -> Double {
        progress(state, since: state?.studySince ?? state?.sessionStartedAt ?? now, at: now)
    }

    static func progress(_ state: FocusTimerState?, since start: Date, at now: Date = Date()) -> Double {
        guard let until = state?.studyUntil else { return 0 }
        let total = until.timeIntervalSince(start)
        guard total > 0 else { return 1 }
        return min(1, max(0, now.timeIntervalSince(start) / total))
    }

    /// Le mode étude a fini (la date est passée) mais la session tourne
    /// encore : on propose de terminer ou de prolonger.
    static func isOver(_ state: FocusTimerState?, at now: Date = Date()) -> Bool {
        guard let until = state?.studyUntil else { return false }
        return now >= until
    }

    /// Prolonger : à partir de la fin prévue si elle n'est pas passée, sinon de
    /// maintenant — prolonger après coup ne doit pas rendre des minutes déjà
    /// écoulées.
    static func extended(_ until: Date?, by minutes: Int, now: Date = Date()) -> Date {
        let base = max(until ?? now, now)
        return base.addingTimeInterval(TimeInterval(minutes * 60))
    }

    /// Entre en mode étude pour `minutes` à partir de `now`.
    static func enter(_ state: inout FocusTimerState, minutes: Int, now: Date = Date()) {
        state.studySince = now
        state.studyUntil = now.addingTimeInterval(TimeInterval(minutes * 60))
    }

    /// Lève le mode étude (la session continue).
    static func leave(_ state: inout FocusTimerState) {
        state.studyUntil = nil
        state.studySince = nil
    }

    // MARK: Sites permis

    /// Les sites ouverts par défaut. Un domaine couvre ses sous-domaines :
    /// `epfl.ch` laisse passer moodle, courseware, botafogo, mediaspace, la
    /// connexion Tequila… Les pages de connexion (Microsoft, Google, Apple)
    /// sont là pour que se connecter à Moodle ou à Claude reste possible.
    static let defaultSites: [String] = [
        "epfl.ch",
        "claude.ai", "anthropic.com", "claudeusercontent.com",
        "login.microsoftonline.com", "login.live.com", "msauth.net", "msftauth.net",
        "accounts.google.com", "appleid.apple.com",
        "kaltura.com", "switch.ch",
        "geogebra.org", "desmos.com", "wolframalpha.com",
    ]

    /// Les sites ajoutés à la liste par défaut après coup : ils rejoignent une
    /// liste déjà enregistrée (sans rétablir ceux qu'on a retirés).
    static let addedLater: Set<String> = ["geogebra.org", "desmos.com", "wolframalpha.com"]

    /// `https://www.Moodle.epfl.ch/my/` → `moodle.epfl.ch`. Ce que l'utilisateur·rice
    /// tape dans les réglages, ramené à un domaine ; `nil` si ce n'en est pas un.
    static func normalizedDomain(_ entry: String) -> String? {
        var text = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        if let slash = text.firstIndex(where: { "/?#".contains($0) }) { text = String(text[..<slash]) }
        if let at = text.lastIndex(of: "@") { text = String(text[text.index(after: at)...]) }
        if let colon = text.firstIndex(of: ":") { text = String(text[..<colon]) }
        if text.hasPrefix("*.") { text.removeFirst(2) }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        while text.hasSuffix(".") { text.removeLast() }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        guard text.contains("."), !text.hasPrefix("."), !text.contains(".."),
              text.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return text
    }

    /// Ce site est-il permis ? Un domaine permet ses sous-domaines, **à une
    /// frontière de point** : `epfl.ch` permet `moodle.epfl.ch`, pas `notepfl.ch`.
    static func isAllowed(host: String?, sites: [String]) -> Bool {
        guard let host = host.flatMap(normalizedDomain) else { return false }
        return sites.compactMap(normalizedDomain).contains { site in
            host == site || host.hasSuffix("." + site)
        }
    }

    /// Une adresse est-elle permise ? Les pages internes (`about:blank`, un PDF
    /// ouvert en mémoire) le sont toujours : elles ne mènent nulle part.
    static func isAllowed(url: URL?, sites: [String]) -> Bool {
        guard let url else { return false }
        switch url.scheme?.lowercased() {
        case "about", "data", "blob": return true
        case "http", "https": return isAllowed(host: url.host, sites: sites)
        default: return false
        }
    }

    // MARK: Apps permises (Mac)

    /// Les apps permises par défaut sur le Mac. GoodNotes et Claude ont leur
    /// app ; Aperçu ouvre les PDF des séries ; Finder, pour aller les chercher.
    static let defaultMacApps: [String] = [
        "com.goodnotesapp.x",
        "com.anthropic.claudefordesktop",
        "com.apple.Preview",
        "com.apple.finder",
        "com.apple.calculator",
    ]

    /// Ce qui fait marcher le Mac lui-même : jamais bloqué (fenêtre de
    /// connexion, Touch ID, économiseur, Dock, Spotlight, centre de contrôle…).
    static let systemBundles: Set<String> = [
        "com.apple.loginwindow", "com.apple.SecurityAgent", "com.apple.coreautha",
        "com.apple.ScreenSaver.Engine", "com.apple.dock", "com.apple.Spotlight",
        "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.systemuiserver",
        "com.apple.screencaptureui", "com.apple.PIPAgent", "com.apple.UserNotificationCenter",
        "com.apple.universalcontrol", "com.apple.WindowManager", "com.apple.accessibility.AXVisualSupportAgent",
    ]

    /// Une app qui passe au premier plan doit-elle être arrêtée ?
    ///
    /// - `regular` : l'app a une fenêtre et une icône dans le Dock. Les agents
    ///   (barre des menus, services) ne sont jamais bloqués : ce ne sont pas des
    ///   distractions, et les bloquer casserait le système.
    static func shouldBlock(bundleID: String?, isRegular: Bool, own: String, allowed: [String]) -> Bool {
        guard isRegular, let bundleID, !bundleID.isEmpty else { return false }
        if bundleID == own || systemBundles.contains(bundleID) { return false }
        // Les assistants d'une app permise (« … .helper ») le sont avec elle.
        return !allowed.contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
    }

    // MARK: Outils

    /// Ce que l'écran du mode étude propose d'ouvrir.
    struct Tool: Identifiable, Equatable {
        enum Kind: Equatable {
            /// Un site, ouvert dans le navigateur du mode étude.
            case web(URL)
            /// Une app, par son identifiant (Mac) et son adresse (iPhone).
            case app(bundleID: String, scheme: String)
        }
        var id: String
        var title: String
        var subtitle: String
        var icon: String
        var kind: Kind
    }

    /// Les outils de la session : d'abord les pages du cours travaillé (sa
    /// page Moodle, ses sites), puis les outils de toujours.
    static func tools(courseName: String?, courseLinks: [String]) -> [Tool] {
        var result: [Tool] = []
        var seen: Set<String> = []
        for link in courseLinks {
            guard let url = URL(string: link), url.scheme?.hasPrefix("http") == true,
                  let host = url.host?.lowercased(), !seen.contains(url.absoluteString) else { continue }
            seen.insert(url.absoluteString)
            let (title, icon) = siteLabel(host)
            result.append(Tool(id: "course:" + url.absoluteString, title: title,
                               subtitle: courseName ?? host, icon: icon, kind: .web(url)))
        }
        let base: [Tool] = [
            // Claude n'est plus un site : il est dans l'app (le bureau du Mac).
            Tool(id: "moodle", title: "Moodle", subtitle: "Tes cours", icon: "graduationcap",
                 kind: .web(URL(string: "https://moodle.epfl.ch/my/")!)),
            Tool(id: "claude-app", title: "Claude", subtitle: "L'app", icon: "sparkles",
                 kind: .app(bundleID: "com.anthropic.claudefordesktop", scheme: "claude://")),
            Tool(id: "goodnotes", title: "GoodNotes", subtitle: "Écrire", icon: "pencil.and.scribble",
                 kind: .app(bundleID: "com.goodnotesapp.x", scheme: "goodnotes://")),
            Tool(id: "courseware", title: "Courseware", subtitle: "MOOC et vidéos", icon: "play.rectangle",
                 kind: .web(URL(string: "https://courseware.epfl.ch/dashboard")!)),
        ]
        return result + base
    }

    /// Le nom et l'icône d'un site de cours connu.
    static func siteLabel(_ host: String) -> (String, String) {
        if host.hasPrefix("moodle.") { return ("Moodle du cours", "graduationcap") }
        if host.hasPrefix("courseware.") { return ("Courseware", "play.rectangle") }
        if host.hasPrefix("botafogo.") { return ("Botafogo", "book.pages") }
        if host.hasPrefix("mediaspace.") { return ("Vidéos du cours", "video") }
        if host.hasPrefix("explique.") { return ("Explique", "text.bubble") }
        return (host.replacingOccurrences(of: "www.", with: ""), "globe")
    }
}
