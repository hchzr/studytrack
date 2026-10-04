import Foundation
import BackgroundTasks
import SwiftData
import UserNotifications

/// Prévient d'une série, d'un corrigé ou d'un rendu publiés sur Moodle,
/// **même app fermée**.
///
/// iOS réveille l'app de temps en temps (`BGAppRefreshTask`, au mieux toutes
/// les deux heures, selon l'usage et la batterie). Le relevé doit tenir en
/// quelques secondes : pas de WebView ni d'IA, une requête par cours —
/// `core_courseformat_get_state`, le plan du cours en JSON — avec les cookies
/// gardés par `CookieKeeper`. Ce qui est nouveau (`MoodleNews.diff`) devient
/// une notification par cours ; l'import complet se fait à la prochaine
/// ouverture (`ContentRefresher`), qui est alors avancée.
///
/// Une session Moodle expirée ne se renouvelle pas en arrière-plan (la
/// connexion EPFL demande une page web) : le relevé s'arrête sans bruit, et
/// les réglages disent qu'il faut rouvrir l'app.
@MainActor
enum MoodleWatcher {
    static let taskIdentifier = "com.hczr.studytrack.moodle-watch"
    static let categoryIdentifier = "moodle-news"
    static let interval: TimeInterval = 2 * 3600

    private static let knownKey = "moodleWatch.known"
    private static let lastCheckKey = "moodleWatch.lastCheck"
    private static let statusKey = "moodleWatch.status"
    private static let base = URL(string: "https://moodle.epfl.ch")!
    private static var running = false

    enum Status: String, Error {
        case ok, signedOut, offline
    }

    struct Report {
        var courses = 0
        var news: [(code: String, items: [MoodleNews.Item])] = []
        var status: Status = .ok
    }

    /// La surveillance a trouvé du neuf : la prochaine ouverture importe,
    /// même si un autre appareil a relu Moodle récemment.
    static var hasPendingNews: Bool {
        get { UserDefaults.standard.bool(forKey: "moodleWatch.pendingNews") }
        set { UserDefaults.standard.set(newValue, forKey: "moodleWatch.pendingNews") }
    }

    static var lastCheck: Date? { UserDefaults.standard.object(forKey: lastCheckKey) as? Date }
    static var lastStatus: Status? { UserDefaults.standard.string(forKey: statusKey).flatMap(Status.init) }

    // MARK: Planification

    /// Demande le prochain réveil. iOS choisit le moment ; il faut redemander
    /// à chaque fois (au passage en arrière-plan et à chaque relevé).
    static func schedule(settings: SettingsStore) {
        guard settings.moodleNewsEnabled else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(interval)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Le réveil d'iOS.
    static func runInBackground() async {
        guard let app = AppRuntime.container else { return }
        schedule(settings: app.settings)
        _ = await check(container: app.modelContainer, settings: app.settings)
    }

    // MARK: Relevé

    /// Relit le plan de chaque cours suivi et relié à Moodle ; notifie ce qui
    /// est nouveau (si `notify`), et retient tout ce qui a été vu.
    @discardableResult
    static func check(container: ModelContainer, settings: SettingsStore, notify: Bool = true) async -> Report {
        var report = Report()
        guard settings.moodleNewsEnabled, !running else { return report }
        running = true
        defer { running = false }

        let context = ModelContext(container)
        let courses = ((try? context.fetch(FetchDescriptor<Course>())) ?? []).filter(\.isTracked).compactMap { course -> (Course, Int)? in
            MoodleCourseMatcher.linkedID(in: course.contentSources).map { (course, $0) }
        }
        guard !courses.isEmpty else { return report }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        let jar = configuration.httpCookieStorage ?? HTTPCookieStorage()
        for cookie in CookieKeeper.stored() { jar.setCookie(cookie) }
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let key: String
        switch await sesskey(session) {
        case .success(let value): key = value
        case .failure(let status):
            report.status = status
            remember(status: status)
            return report
        }

        var known = loadKnown()
        let kinds = settings.moodleNewsKinds
        let muted = settings.moodleNewsMuted
        var anything = false
        for (course, id) in courses {
            guard let snapshot = await state(of: id, title: course.name, sesskey: key, session: session) else { continue }
            report.courses += 1
            let diff = MoodleNews.diff(snapshot, known: known[String(id)].map(Set.init))
            known[String(id)] = diff.seen.sorted()
            anything = anything || !diff.new.isEmpty
            let wanted = diff.new.filter { kinds.contains($0.kind) }
            guard !wanted.isEmpty, !muted.contains(course.id) else { continue }
            report.news.append((course.displayCode, wanted))
            if notify { await post(wanted, course: course, settings: settings) }
        }
        saveKnown(known)
        // Moodle prolonge sa session à chaque requête : on garde la nouvelle.
        CookieKeeper.merge(jar.cookies ?? [])
        // Quelque chose a bougé : la prochaine ouverture importe sans attendre
        // les douze heures.
        if anything {
            settings.contentLastRefresh = nil
            hasPendingNews = true
        }
        remember(status: .ok)
        AppLog.record(.info, "import", "Relevé Moodle",
                      detail: "\(report.courses) cours · \(report.news.reduce(0) { $0 + $1.items.count }) nouveauté(s)")
        return report
    }

    /// Ce que l'import au premier plan a déjà montré n'est pas annoncé ensuite.
    static func markSeen(_ snapshot: MoodleCourseSnapshot, moodleID: Int) {
        var known = loadKnown()
        let current = known[String(moodleID)].map(Set.init) ?? []
        known[String(moodleID)] = current.union(MoodleNews.visibleItems(of: snapshot).map(\.id)).sorted()
        saveKnown(known)
    }

    /// Oublie tout ce qui a été vu (déconnexion, données effacées).
    static func reset() {
        UserDefaults.standard.removeObject(forKey: knownKey)
    }

    // MARK: Moodle sans page web

    /// La clé de session, lue dans la page d'accueil. Une redirection vers la
    /// connexion = session expirée.
    private static func sesskey(_ session: URLSession) async -> Result<String, Status> {
        guard let (data, response) = try? await session.data(from: base.appendingPathComponent("my/")) else {
            return .failure(.offline)
        }
        let final = response.url?.absoluteString ?? ""
        let html = String(decoding: data, as: UTF8.self)
        guard !final.contains("/login"),
              let range = html.range(of: #""sesskey":"([^"]+)""#, options: .regularExpression) else {
            return .failure(.signedOut)
        }
        let match = html[range].dropFirst(#""sesskey":""#.count).dropLast()
        return .success(String(match))
    }

    private static func state(of id: Int, title: String, sesskey: String, session: URLSession) async -> MoodleCourseSnapshot? {
        var components = URLComponents(url: base.appendingPathComponent("lib/ajax/service.php"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "sesskey", value: sesskey),
                                 URLQueryItem(name: "info", value: "core_courseformat_get_state")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            ["index": 0, "methodname": "core_courseformat_get_state", "args": ["courseid": id]]
        ])
        guard let (data, _) = try? await session.data(for: request),
              let reply = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              let first = reply.first, first["error"] as? Bool != true,
              let json = first["data"] as? String else { return nil }
        return MoodleStateParser.snapshot(fromStateJSON: json, title: title,
                                          url: "https://moodle.epfl.ch/course/view.php?id=\(id)")
    }

    // MARK: Notification

    private static func post(_ items: [MoodleNews.Item], course: Course, settings: SettingsStore) async {
        guard let message = MoodleNews.message(courseCode: course.displayCode, items: items) else { return }
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.body
        content.sound = .default
        content.threadIdentifier = "moodle-\(course.id.uuidString)"
        content.categoryIdentifier = categoryIdentifier
        let theoryOnly = items.allSatisfy { $0.kind == .lecture }
        content.userInfo = ["courseID": course.id.uuidString, "section": theoryOnly ? "theory" : "exercises"]
        var trigger: UNNotificationTrigger?
        if settings.quietHoursEnabled,
           let date = MoodleNews.deliveryDate(now: Date(), quietStart: settings.quietHoursStart, quietEnd: settings.quietHoursEnd) {
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        }
        let identifier = "moodle-news-\(course.id.uuidString)-\(Int(Date().timeIntervalSince1970))"
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }

    // MARK: Mémoire

    /// Ce qui a été vu **sur tous les appareils** : une série annoncée sur
    /// l'iPhone ne l'est pas une seconde fois sur l'iPad.
    private static func loadKnown() -> [String: [String]] {
        let local = UserDefaults.standard.dictionary(forKey: knownKey) as? [String: [String]] ?? [:]
        return CloudRelay.mergeKnown(local, CloudRelay.moodleKnown())
    }

    private static func saveKnown(_ known: [String: [String]]) {
        UserDefaults.standard.set(known, forKey: knownKey)
        CloudRelay.publishMoodleKnown(known)
    }

    private static func remember(status: Status) {
        UserDefaults.standard.set(Date(), forKey: lastCheckKey)
        UserDefaults.standard.set(status.rawValue, forKey: statusKey)
    }
}
