import Foundation
import SwiftData
import Security

/// Relie l'app à son serveur MCP (`supabase/functions/mcp`).
///
/// Un aller-retour fait tout : l'app envoie son instantané et le compte rendu
/// des commandes déjà appliquées, le serveur répond par les commandes en
/// attente. S'il y en avait, l'app les applique (`AssistantCommandApplier`) et
/// refait un aller-retour pour les confirmer et publier l'état qui en résulte.
///
/// Appelée à l'ouverture, au passage en arrière-plan, et quelques secondes après
/// chaque enregistrement : une question cochée dans l'app se lit aussitôt chez
/// l'assistant, et une demande de l'assistant arrive dès que l'app est ouverte.
@MainActor
enum AssistantSync {

    /// L'adresse à donner à l'assistant ; `nil` si l'app n'est pas reliée.
    static func serverURL(token: String) -> URL? {
        guard !token.isEmpty, SupabaseConfig.isConfigured else { return nil }
        return URL(string: "\(SupabaseConfig.urlString)/functions/v1/mcp/\(token)")
    }

    /// Un jeton de 256 bits, en base64url : il sert de mot de passe.
    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Ce que la dernière synchronisation a appliqué, pour l'écran de réglages.
    private(set) static var lastApplied: [AssistantCommandResult] = []
    private(set) static var lastError: String?
    private static var running = false

    /// L'empreinte du dernier instantané accepté par le serveur, et quand.
    private static var lastFingerprint: Int?
    private static var lastSuccess: Date?
    /// Échecs d'affilée : chaque échec double l'attente avant la tentative
    /// automatique suivante (30 s, 1 min, 2 min… 30 min au plus).
    private static var failureStreak = 0
    private static var nextAttempt = Date.distantPast

    /// Synchronisation groupée : dix questions cochées d'affilée ne font qu'un envoi.
    ///
    /// Seule l'**attente** est annulée par un nouvel enregistrement, jamais un
    /// envoi en cours : l'annuler coupait la requête (« annulé » dans les
    /// diagnostics) et comptait pour un échec. Un enregistrement pendant un envoi
    /// en relance un juste après.
    static func scheduleSync(context: ModelContext, settings: SettingsStore) {
        guard !settings.assistantToken.isEmpty else { return }
        if running {
            rerunRequested = true
            return
        }
        waiting?.cancel()
        waiting = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            waiting = nil
            await sync(context: context, settings: settings, force: false)
            if rerunRequested {
                rerunRequested = false
                scheduleSync(context: context, settings: settings)
            }
        }
    }

    private static var waiting: Task<Void, Never>?
    private static var rerunRequested = false

    /// Les commandes déjà appliquées (identifiant → résultat), gardées d'un
    /// lancement à l'autre. Quand la confirmation au serveur échouait, il
    /// renvoyait les mêmes commandes, et l'app les réappliquait — trois fois
    /// « corrigé moyen » d'affilée, au risque d'écraser une correction faite
    /// entre-temps. Une commande connue n'est plus réappliquée : son résultat est
    /// seulement renvoyé.
    private static let appliedKey = "assistant.appliedCommands"
    private static var applied: [String: AssistantCommandResult] {
        get {
            guard let data = UserDefaults.standard.data(forKey: appliedKey) else { return [:] }
            let list = (try? JSONDecoder().decode([AssistantCommandResult].self, from: data)) ?? []
            return Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        }
        set {
            let list = Array(newValue.values.suffix(400))
            UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: appliedKey)
        }
    }

    /// - Parameter force: `false` pour les envois automatiques après un
    ///   enregistrement. Ils sont sautés quand rien n'a changé depuis le
    ///   dernier envoi réussi (moins de 10 min), ou pendant l'attente qui suit
    ///   un échec. C'étaient eux qui remplissaient les diagnostics de « La
    ///   requête a expiré » : l'instantané entier repartait quatre secondes
    ///   après chaque coche, réseau ou pas.
    @discardableResult
    static func sync(context: ModelContext, settings: SettingsStore, force: Bool = true) async -> Bool {
        guard let url = serverURL(token: settings.assistantToken)?.appendingPathComponent("sync"), !running else { return false }
        let now = Date()
        if !force, now < nextAttempt { return false }
        let current = snapshot(context: context, settings: settings)
        let fingerprint = fingerprint(of: current)
        if !force, fingerprint == lastFingerprint, let lastSuccess, now.timeIntervalSince(lastSuccess) < 600 { return true }
        running = true
        defer { running = false }
        do {
            var commands = try await exchange(url, snapshot: current, results: [])
            // Deux tours au plus : appliquer, confirmer. Une commande déposée
            // entre-temps attendra la prochaine synchronisation.
            if !commands.isEmpty {
                var known = applied
                let fresh = commands.filter { known[$0.id] == nil }
                let newResults = AssistantCommandApplier.apply(fresh, context: context)
                for result in newResults { known[result.id] = result }
                applied = known
                let results = commands.compactMap { known[$0.id] }
                lastApplied = (newResults + lastApplied).prefix(20).map { $0 }
                for result in newResults {
                    AppLog.record(result.status == "applied" ? .info : .warning, "assistant", result.message)
                }
                commands = try await exchange(url, snapshot: snapshot(context: context, settings: settings), results: results)
                if !results.isEmpty {
                    WidgetSnapshotWriter.scheduleRefresh(context: context, settings: settings)
                }
            }
            settings.assistantLastSync = Date()
            lastError = nil
            lastFingerprint = commands.isEmpty ? fingerprint : nil
            lastSuccess = Date()
            if failureStreak > 1 {
                AppLog.record(.info, "assistant", "Synchronisation rétablie", detail: "après \(failureStreak) échecs")
            }
            failureStreak = 0
            nextAttempt = .distantPast
            return true
        } catch {
            // Une requête annulée (l'app part en arrière-plan) n'est pas une panne.
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return false }
            lastError = error.localizedDescription
            failureStreak += 1
            nextAttempt = Date().addingTimeInterval(min(1800, 30 * pow(2, Double(failureStreak - 1))))
            // Une ligne par panne, pas une par tentative.
            if failureStreak == 1 {
                AppLog.record(.warning, "assistant", "Synchronisation impossible", detail: error.localizedDescription)
            }
            return false
        }
    }

    /// L'empreinte d'un instantané, sans son horodatage.
    private static func fingerprint(of snapshot: Any) -> Int? {
        guard var dictionary = snapshot as? [String: Any] else { return nil }
        dictionary["generatedAt"] = nil
        guard let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys]) else { return nil }
        return data.hashValue
    }

    /// Déconnecte l'assistant : le serveur efface l'instantané et les commandes.
    static func disconnect(settings: SettingsStore) async {
        if let url = serverURL(token: settings.assistantToken) {
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            _ = try? await URLSession.shared.data(for: request)
        }
        settings.assistantToken = ""
        settings.assistantLastSync = nil
        lastApplied = []
    }

    // MARK: Échange

    private static func snapshot(context: ModelContext, settings: SettingsStore) -> Any {
        let courses = (try? context.fetch(FetchDescriptor<Course>())) ?? []
        var sessionsQuery = FetchDescriptor<StudySession>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        sessionsQuery.fetchLimit = 2000
        let sessions = (try? context.fetch(sessionsQuery)) ?? []
        let milestones = (try? context.fetch(FetchDescriptor<AcademicMilestone>())) ?? []
        let groups = (try? context.fetch(FetchDescriptor<StudyGroup>())) ?? []
        return AssistantExport.make(courses: courses, sessions: sessions, milestones: milestones, groups: groups,
                                    hoursPerCredit: settings.hoursPerCredit, displayName: settings.displayName)
    }

    private static func exchange(_ url: URL, snapshot: Any, results: [AssistantCommandResult]) async throws -> [AssistantCommand] {
        var body: [String: Any] = ["snapshot": snapshot]
        if !results.isEmpty {
            body["results"] = results.map { ["id": $0.id, "status": $0.status, "message": $0.message] }
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // L'instantané pèse quelques centaines de ko : 20 s ne suffisaient pas
        // sur le réseau de l'EPFL aux heures de pointe.
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = String(decoding: data.prefix(200), as: UTF8.self)
            throw HiddenSiteSession.SiteError.failed("Serveur de l'assistant : \((response as? HTTPURLResponse)?.statusCode ?? 0) \(detail)")
        }
        struct Reply: Decodable { var commands: [AssistantCommand] }
        return try JSONDecoder().decode(Reply.self, from: data).commands
    }
}
