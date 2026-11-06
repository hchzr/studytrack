import Foundation

/// Prépare le « projet EPFL » de Claude Code avant une conversation : le
/// dossier, la partie StudyTrack du `CLAUDE.md`, les compétences, le fichier
/// des serveurs MCP. Le texte et les choix sont dans `ClaudeProject` (pur).
@MainActor
enum ClaudeProjectSetup {

    /// Le fichier de configuration du projet (la façon de travailler de
    /// l'étudiant·e) : compétences, serveurs MCP, outils, modèles, boutons.
    static func fileURL(settings: MacSettings) -> URL {
        folder(settings).appendingPathComponent("studytrack.json")
    }

    static func folder(_ settings: MacSettings) -> URL {
        URL(fileURLWithPath: (settings.claudeProjectFolder as NSString).expandingTildeInPath, isDirectory: true)
    }

    static func file(settings: MacSettings) -> ClaudeProject.File? {
        (try? Data(contentsOf: fileURL(settings: settings))).flatMap(ClaudeProject.File.decode)
    }

    /// La configuration à utiliser : le projet si le réglage est allumé, sinon
    /// le mode isolé.
    static func config(settings: MacSettings, courses: [Course]) async -> ClaudeChat.Config {
        guard settings.claudeProject else {
            var isolated = ClaudeChat.Config.isolated
            isolated.review = settings.reviewFeatures(nil)
            return isolated
        }
        let servers = await accountServers()
        let folder = folder(settings)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = file(settings: settings) ?? ClaudeProject.File()
        writeClaudeMD(in: folder, courses: courses, settings: settings)
        linkSkills(file.skills, into: folder)
        let studyTrack = settings.claudeStudyTrackMCP.hasPrefix("https://") ? settings.claudeStudyTrackMCP : nil
        let mcpFile = supportFolder.appendingPathComponent("claude-mcp.json")
        let localFiles = MacLocalMCP.shared.url?.absoluteString
        try? ClaudeProject.mcpConfig(file: file, studyTrackURL: studyTrack, localFilesURL: localFiles).write(to: mcpFile, atomically: true, encoding: .utf8)
        return ClaudeChat.Config(profile: .project, folder: folder, mcpConfigPath: mcpFile.path,
                                 allowedTools: ClaudeProject.allowedTools(file: file, studyTrack: studyTrack != nil,
                                                                          connectors: servers.connectors, localFiles: localFiles != nil),
                                 tools: ClaudeProject.tools(file: file),
                                 deniedServers: servers.local.filter { file.mcpServers[$0] == nil },
                                 permissions: ClaudeProject.permissionSummary(file: file, studyTrack: studyTrack != nil,
                                                                              connectors: servers.connectors, localFiles: localFiles != nil),
                                 file: file, review: settings.reviewFeatures(file))
    }

    // MARK: Connecteurs du compte

    private static let serversKey = "mac.claude.accountServers"
    private static var refreshedThisLaunch = false

    /// Les connecteurs du compte Claude (et les serveurs locaux à écarter),
    /// lus par `claude mcp list` : gardés d'un lancement à l'autre, relus une
    /// fois par lancement (la commande vérifie chaque serveur : quelques
    /// secondes). Changer de compte Claude est ainsi suivi sans réglage.
    static func accountServers() async -> (connectors: [String], local: [String]) {
        let cached = UserDefaults.standard.string(forKey: serversKey).map(ClaudeProject.servers(mcpList:))
        if let cached {
            // Déjà connus : tout de suite, et relus en arrière-plan pour la
            // prochaine fois (la commande prend quelques secondes).
            if !refreshedThisLaunch {
                refreshedThisLaunch = true
                Task.detached(priority: .utility) {
                    if let output = await runClaude(["mcp", "list"]) { UserDefaults.standard.set(output, forKey: serversKey) }
                }
            }
            return cached
        }
        refreshedThisLaunch = true
        guard let output = await runClaude(["mcp", "list"]) else { return ([], []) }
        UserDefaults.standard.set(output, forKey: serversKey)
        return ClaudeProject.servers(mcpList: output)
    }

    private static func runClaude(_ arguments: [String]) async -> String? {
        guard let executable = ClaudeChat.executable else { return nil }
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
            var environment = ProcessInfo.processInfo.environment
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            environment["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            environment.removeValue(forKey: "ANTHROPIC_API_KEY")
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
            do { try process.run() } catch { continuation.resume(returning: nil) }
        }
    }

    /// Hors du dossier du projet : le fichier MCP porte l'adresse secrète du
    /// serveur de StudyTrack.
    private static var supportFolder: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StudyTrack", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func writeClaudeMD(in folder: URL, courses: [Course], settings: MacSettings) {
        let file = folder.appendingPathComponent("CLAUDE.md")
        let lines = courses.filter(\.isTracked).map { course -> ClaudeProject.CourseLine in
            let series = course.sortedSeries.first { $0.plannedWeek >= course.currentWeek && !$0.isComplete }
            let progress = series.map { "\($0.title.isEmpty ? "Série \($0.seriesNumber)" : $0.title) : \($0.doneCount)/\($0.requiredExercises.count) faits" }
            return .init(code: course.displayCode, name: course.name, week: course.currentWeek > 0 ? course.currentWeek : nil, progress: progress)
        }
        let date = Date().formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "fr_CH")))
        let project = Self.file(settings: settings)
        let ladder = project?.redo ?? RedoLadder.Config()
        let redo = SeriesReview.redoQueue(courses.filter(\.isTracked)).prefix(15).map { exercise in
            ClaudeProject.RedoLine(code: exercise.series?.course?.displayCode ?? "", exercise: exercise.displayNumber,
                                   step: (exercise.redoPass).flatMap { ladder.steps.indices.contains($0) ? ladder.steps[$0].label : nil } ?? "",
                                   due: exercise.redoDueAt?.formatted(.dateTime.day().month(.wide).locale(Locale(identifier: "fr_CH"))),
                                   why: exercise.redoWhy)
        }
        let context = ClaudeProject.context(courses: lines, week: courses.first(where: \.isTracked)?.currentWeek, date: date,
                                            redo: Array(redo), features: settings.reviewFeatures(project))
        let existing = try? String(contentsOf: file, encoding: .utf8)
        let updated = ClaudeProject.claudeMD(existing: existing, context: context)
        if updated != existing { try? updated.write(to: file, atomically: true, encoding: .utf8) }
    }

    /// Les compétences de claude.ai (`epfl-serie`, `epfl-memoire`) sont
    /// synchronisées par Claude dans `~/.claude/skills/synced/<organisation>/`,
    /// mais Claude Code ne charge que celles du compte où il est connecté. On
    /// les relie au projet (`.claude/skills/<nom>`, un lien : elles restent à
    /// jour) ; un dossier qui existe déjà n'est jamais remplacé.
    private static func linkSkills(_ names: [String], into folder: URL) {
        let manager = FileManager.default
        let skills = folder.appendingPathComponent(".claude/skills", isDirectory: true)
        let synced = manager.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills/synced", isDirectory: true)
        let buckets = (try? manager.contentsOfDirectory(at: synced, includingPropertiesForKeys: nil)) ?? []
        // Le compte où Claude Code est connecté a ses compétences à lui : on ne
        // relie que celles qu'il n'a pas (sinon elles seraient en double), et
        // l'on retire un lien posé avant un changement de compte.
        let own = currentOrganization().flatMap { org in buckets.first { $0.lastPathComponent.hasPrefix(org) } }
        for name in names {
            let target = skills.appendingPathComponent(name)
            let linked = (try? manager.destinationOfSymbolicLink(atPath: target.path)) != nil
            if let own, manager.fileExists(atPath: own.appendingPathComponent("\(name)/SKILL.md").path) {
                if linked { try? manager.removeItem(at: target) }
                continue
            }
            if linked || manager.fileExists(atPath: target.path) { continue }
            guard let source = buckets.map({ $0.appendingPathComponent(name) })
                .first(where: { manager.fileExists(atPath: $0.appendingPathComponent("SKILL.md").path) }) else { continue }
            try? manager.createDirectory(at: skills, withIntermediateDirectories: true)
            try? manager.createSymbolicLink(at: target, withDestinationURL: source)
        }
    }

    /// L'organisation claude.ai du compte de Claude Code (`~/.claude.json`).
    private static func currentOrganization() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = object["oauthAccount"] as? [String: Any] else { return nil }
        return account["organizationUuid"] as? String
    }

    /// Les compétences du fichier présentes dans le projet.
    static func linkedSkills(settings: MacSettings) -> [String] {
        let folder = folder(settings)
        return (file(settings: settings)?.skills ?? []).filter {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent(".claude/skills/\($0)/SKILL.md").path)
        }
    }
}
