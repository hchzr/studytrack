import AppKit
import Observation
import OSLog
import SwiftData

/// Avec mesure, côté Mac (le calcul est dans `ClaudeMeasure`, le mod dans
/// `ClaudePlugin/mesure`) :
///
/// - écrit `policy.json` — les règles réglées ici et le contexte de Polymestre
///   (mode étude, cours des sept jours, temps étudié) — **seulement quand
///   quelque chose change** : un geste du chrono, une donnée enregistrée, la fin
///   d'un cours, minuit. Rien ne tourne entre-temps ;
/// - relit ce que le mod a compté quand on le regarde (barre des menus, Bilan,
///   Réglages), et en confie les totaux du jour à iCloud pour l'iPhone ;
/// - branche le mod sur Claude Code : une copie dans Application Support,
///   déclarée comme marketplace locale, puis installée (`claude plugin`).
@MainActor
@Observable
final class ClaudeMeasureService {
    static let shared = ClaudeMeasureService()

    typealias CM = ClaudeMeasure

    private(set) var policy: CM.Policy?
    private(set) var today: CM.DaySummary?
    private(set) var week: [CM.DaySummary] = []
    private(set) var passes: [CM.Pass] = []
    /// Ce qu'une séance de projets rencontrerait maintenant (barre des menus).
    private(set) var verdict = CM.Verdict()
    private(set) var modSeenAt: Date?
    private(set) var modVersion: String?
    private(set) var installing = false
    private(set) var installMessage: String?

    @ObservationIgnored weak var timer: MacTimer?
    @ObservationIgnored weak var container: ModelContainer?
    @ObservationIgnored weak var settings: MacSettings?
    @ObservationIgnored private var pendingWrite: Task<Void, Never>?
    @ObservationIgnored private var boundary: Timer?
    @ObservationIgnored private var lastRead: Date?
    let log = Logger(subsystem: "ch.polymestre.mac", category: "mesure")

    static let summariesKey = "claude.measure.days"

    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Polymestre/Claude")
    }
    private var policyURL: URL { Self.root.appending(path: "policy.json") }

    // MARK: Réglages

    /// Les règles voulues (en attente comprises) : ce que montrent les réglages.
    var desired: CM.Rules { policy?.desired ?? Self.initialRules(settings) }
    /// Avec mesure est voulu allumé (même si l'extinction attend le lendemain).
    var wantsEnabled: Bool { policy.map { $0.pending?.enabled ?? $0.enabled } ?? false }
    var isConfigured: Bool { policy != nil }

    /// Les règles d'une première mise en route : le dossier d'étude est celui du
    /// projet Claude réglé dans Polymestre (`~/EPFL` par défaut).
    static func initialRules(_ settings: MacSettings?) -> CM.Rules {
        var rules = CM.Rules.standard
        if let folder = settings?.claudeProjectFolder, !folder.isEmpty {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            rules.studyFolders = [folder.hasPrefix(home) ? "~" + folder.dropFirst(home.count) : folder]
        }
        return rules
    }

    func setEnabled(_ on: Bool) {
        commit(CM.apply(desired: desired, enabled: on, to: policy, now: Date()))
    }

    func setRules(_ rules: CM.Rules) {
        commit(CM.apply(desired: rules, enabled: wantsEnabled || policy == nil, to: policy, now: Date()))
    }

    private func commit(_ next: CM.Policy) {
        var next = next
        next.context = context()
        write(next)
        scheduleBoundary()
        refreshUsage(force: true)
    }

    // MARK: Démarrage et contexte

    func start(timer: MacTimer, container: ModelContainer, settings: MacSettings) {
        self.timer = timer
        self.container = container
        self.settings = settings
        policy = read()
        guard var policy else { return }
        // Une demande échue s'applique à la relecture (le mod l'applique de lui-même).
        let settled = CM.settle(policy, now: Date())
        if settled != policy { policy = settled }
        policy.context = context()
        write(policy)
        scheduleBoundary()
        syncPlugin()
        migrateLegacyPlugin()
    }

    /// Le mod branché avant le changement de nom (marketplace « studytrack », copie dans
    /// l'ancien dossier) est remplacé par celui-ci, une fois : même état (allumé ou non).
    func migrateLegacyPlugin() {
        let key = "mac.claude.pluginRenamed"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let known = (try? Data(contentsOf: home.appending(path: ".claude/plugins/known_marketplaces.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        guard known["studytrack"] != nil else {
            UserDefaults.standard.set(true, forKey: key)
            return
        }
        guard let claude = ClaudeTutor.candidatePaths(home: home.path).first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              FileManager.default.fileExists(atPath: Self.pluginCopy.path) else { return }
        let settings = (try? Data(contentsOf: home.appending(path: ".claude/settings.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let enabled = (settings["enabledPlugins"] as? [String: Any])?["mesure@studytrack"] as? Bool ?? false
        let path = Self.pluginCopy.path
        Task.detached(priority: .utility) {
            _ = Self.run(claude, ["plugin", "marketplace", "add", path])
            if enabled { _ = Self.run(claude, ["plugin", "install", "mesure@polymestre"]) }
            _ = Self.run(claude, ["plugin", "uninstall", "mesure@studytrack"])
            let removed = Self.run(claude, ["plugin", "marketplace", "remove", "studytrack"])
            await MainActor.run {
                if removed.status == 0 { UserDefaults.standard.set(true, forKey: key) }
                ClaudeMeasureService.shared.log.notice("mod : studytrack → polymestre (\(enabled ? "allumé" : "éteint", privacy: .public), retrait \(removed.status))")
            }
        }
    }

    /// Un geste du chrono, une donnée enregistrée : le contexte est réécrit
    /// (une fois, deux secondes après la dernière demande).
    func contextChanged() {
        guard policy != nil else { return }
        pendingWrite?.cancel()
        pendingWrite = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, var policy = self.policy else { return }
            policy = CM.settle(policy, now: Date())
            let fresh = self.context()
            guard fresh != policy.context || policy != self.policy else { return }
            policy.context = fresh
            self.write(policy)
            self.scheduleBoundary()
        }
    }

    /// Le prochain instant où le contexte change de lui-même : la fin d'un cours
    /// (le temps étudié compte les cours suivis), minuit (un nouveau jour), une
    /// demande en attente. Une minuterie, une seule.
    private func scheduleBoundary() {
        boundary?.invalidate()
        guard let policy else { return }
        let now = Date()
        let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
        var next = midnight.addingTimeInterval(5)
        for lesson in policy.context.classes {
            let end = CM.date(lesson.end)
            if end > now, end < next { next = end.addingTimeInterval(5) }
        }
        if let pending = policy.pending, CM.date(pending.from) > now, CM.date(pending.from) < next { next = CM.date(pending.from) }
        boundary = Timer.scheduledTimer(withTimeInterval: max(5, next.timeIntervalSince(now)), repeats: false) { _ in
            MainActor.assumeIsolated { ClaudeMeasureService.shared.contextChanged() }
        }
    }

    /// Ce que le mod a besoin de savoir de Polymestre, maintenant.
    func context(now: Date = Date()) -> CM.Context {
        var studyMode: CM.StudyModeInfo?
        let state = timer?.engine.state
        if StudyMode.isActive(state, at: now), let state, let since = state.studySince, let until = state.studyUntil {
            // Sans fin : douze heures au plus, réécrites au prochain geste (comme le bouclier de l'iPhone).
            let end = StudyMode.isOpenEnded(state) ? now.addingTimeInterval(StudyMode.openEndedShieldSafety) : until
            studyMode = CM.StudyModeInfo(since: CM.ms(since), until: CM.ms(end),
                                         blocks: StudyMode.blocks(state, at: now), locks: StudyMode.locks(state, at: now))
        }
        var lessons: [CM.Lesson] = []
        var studied: CM.Studied?
        if let container {
            let context = ModelContext(container)
            let start = Calendar.current.startOfDay(for: now)
            let end = Calendar.current.date(byAdding: .day, value: 7, to: start) ?? now
            let descriptor = FetchDescriptor<LinkedCalendarEvent>(
                predicate: #Predicate { $0.startsAt >= start && $0.startsAt < end },
                sortBy: [SortDescriptor(\.startsAt)])
            let events = (try? context.fetch(descriptor)) ?? []
            lessons = DeskSchedule.classes(from: events).map {
                CM.Lesson(start: CM.ms($0.slot.start), end: CM.ms($0.slot.end), title: $0.slot.courseCode)
            }
            var accumulated = 0.0
            var running: Double?
            if let state, Calendar.current.isDate(state.sessionStartedAt, inSameDayAs: now) {
                accumulated = state.accumulated
                running = state.runningSince.map(CM.ms)
            }
            studied = CM.Studied(day: CM.dayKey(now), seconds: Double(StudyTime.today(in: context, now: now)),
                                 accumulated: accumulated, runningSince: running)
        }
        return CM.Context(studyMode: studyMode, classes: lessons, studied: studied)
    }

    // MARK: Fichiers

    private func read() -> CM.Policy? {
        guard let data = try? Data(contentsOf: policyURL) else { return nil }
        return try? JSONDecoder().decode(CM.Policy.self, from: data)
    }

    private func write(_ next: CM.Policy) {
        var next = next
        next.writtenAt = CM.ms(Date())
        do {
            try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: policyURL, options: .atomic)
            policy = next
        } catch {
            log.error("policy.json : \(error.localizedDescription, privacy: .public)")
            AppLog.record(.error, AppLog.Category.claude, "Avec mesure : règles non écrites", detail: error.localizedDescription)
        }
    }

    private func decodeAll<T: Decodable>(_ type: T.Type, in folder: URL) -> [T] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
        }
    }

    // MARK: Ce que le mod a compté

    /// Relu quand on le regarde ; une fois par demi-minute au plus, sauf `force`.
    func refreshUsage(force: Bool = false) {
        let now = Date()
        if !force, let lastRead, now.timeIntervalSince(lastRead) < 30 { return }
        lastRead = now
        let calendar = Calendar.current
        let rules = policy.map { CM.effectiveRules($0, now: now) } ?? desired
        var days: [CM.DaySummary] = []
        var allPasses: [CM.Pass] = []
        var todayRecords: [CM.SessionRecord] = []
        var cache: [String: [CM.SessionRecord]] = [:]
        func records(_ key: String) -> [CM.SessionRecord] {
            if let hit = cache[key] { return hit }
            let list = decodeAll(CM.SessionRecord.self, in: Self.root.appending(path: "sessions/\(key)"))
            cache[key] = list
            return list
        }
        for offset in (0..<14).reversed() {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let key = CM.dayKey(day)
            let previous = CM.dayKey(calendar.date(byAdding: .day, value: -1, to: day) ?? day)
            let list = records(previous) + records(key)
            let dayPasses = decodeAll(CM.Pass.self, in: Self.root.appending(path: "passes/\(key)"))
            allPasses += dayPasses
            days.append(CM.summary(day: day, records: list, passes: dayPasses, rules: rules, now: now))
            if offset == 0 { todayRecords = list }
        }
        week = Array(days.suffix(7))
        today = days.last
        passes = allPasses.sorted { $0.at > $1.at }
        let use = CM.usage(todayRecords, now: now, rules: rules)
        verdict = CM.evaluate(.projets, headless: false, policy: policy, use: use, passes: allPasses, now: now)
        if let data = try? Data(contentsOf: Self.root.appending(path: "mod.json")),
           let mod = try? JSONDecoder().decode(ModHeartbeat.self, from: data) {
            modSeenAt = CM.date(mod.seenAt)
            modVersion = mod.version
        }
        // L'iPhone montre les totaux (rien d'autre ne quitte le Mac).
        if policy != nil, let data = try? JSONEncoder().encode(days) {
            NSUbiquitousKeyValueStore.default.set(data, forKey: Self.summariesKey)
        }
    }

    private struct ModHeartbeat: Decodable {
        var version: String
        var seenAt: Double
    }

    // MARK: Brancher sur Claude Code

    static var pluginCopy: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Polymestre/ClaudePlugin")
    }

    /// La copie du mod suit celle de l'app (une nouvelle version de Polymestre
    /// apporte la sienne) ; Claude Code la relit à la séance suivante.
    func syncPlugin() {
        guard let bundled = Bundle.main.url(forResource: "ClaudePlugin", withExtension: nil) else { return }
        let fm = FileManager.default
        let target = Self.pluginCopy
        let marker = "mesure/.claude-plugin/plugin.json"
        let same = (try? Data(contentsOf: bundled.appending(path: "mesure/hooks/register.tsx")))
            == (try? Data(contentsOf: target.appending(path: "mesure/hooks/register.tsx")))
            && (try? Data(contentsOf: bundled.appending(path: "mesure/hooks/policy.ts")))
            == (try? Data(contentsOf: target.appending(path: "mesure/hooks/policy.ts")))
            && fm.fileExists(atPath: target.appending(path: marker).path)
        guard !same else { return }
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let staging = target.deletingLastPathComponent().appending(path: ".ClaudePlugin-\(UUID().uuidString)")
            try fm.copyItem(at: bundled, to: staging)
            if fm.fileExists(atPath: target.path) { _ = try fm.replaceItemAt(target, withItemAt: staging) }
            else { try fm.moveItem(at: staging, to: target) }
        } catch {
            log.error("copie du mod : \(error.localizedDescription, privacy: .public)")
        }
    }

    /// `claude plugin marketplace add <copie>` puis `claude plugin install mesure@polymestre`.
    func install() {
        guard !installing else { return }
        syncPlugin()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard let claude = ClaudeTutor.candidatePaths(home: home).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            installMessage = String(localized: "Claude Code est introuvable sur ce Mac (installe-le, puis réessaie).")
            return
        }
        guard FileManager.default.fileExists(atPath: Self.pluginCopy.path) else {
            installMessage = String(localized: "Le mod n'est pas dans cette copie de Polymestre.")
            return
        }
        installing = true
        installMessage = nil
        let path = Self.pluginCopy.path
        Task.detached(priority: .userInitiated) {
            let add = Self.run(claude, ["plugin", "marketplace", "add", path])
            let install = Self.run(claude, ["plugin", "install", "mesure@polymestre"])
            let ok = install.status == 0 || install.output.localizedCaseInsensitiveContains("already")
            await MainActor.run {
                let service = ClaudeMeasureService.shared
                service.installing = false
                service.installMessage = ok
                    ? String(localized: "Branché. Les nouvelles séances de Claude Code comptent ; dans une séance ouverte, tape /reload-plugins.")
                    : String(localized: "Échec : \((install.output.isEmpty ? add.output : install.output).prefix(300))")
            }
        }
    }

    nonisolated private static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
