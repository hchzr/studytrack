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
    static func config(settings: MacSettings, courses: [Course]) -> ClaudeChat.Config {
        guard settings.claudeProject else { return .isolated }
        let folder = folder(settings)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = file(settings: settings) ?? ClaudeProject.File()
        writeClaudeMD(in: folder, courses: courses)
        linkSkills(file.skills, into: folder)
        let studyTrack = settings.claudeStudyTrackMCP.hasPrefix("https://") ? settings.claudeStudyTrackMCP : nil
        let mcpFile = supportFolder.appendingPathComponent("claude-mcp.json")
        try? ClaudeProject.mcpConfig(file: file, studyTrackURL: studyTrack).write(to: mcpFile, atomically: true, encoding: .utf8)
        return ClaudeChat.Config(profile: .project, folder: folder, mcpConfigPath: mcpFile.path,
                                 allowedTools: ClaudeProject.allowedTools(file: file, studyTrack: studyTrack != nil),
                                 tools: ClaudeProject.tools(file: file),
                                 permissions: ClaudeProject.permissionSummary(file: file, studyTrack: studyTrack != nil),
                                 file: file)
    }

    /// Hors du dossier du projet : le fichier MCP porte l'adresse secrète du
    /// serveur de StudyTrack.
    private static var supportFolder: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StudyTrack", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func writeClaudeMD(in folder: URL, courses: [Course]) {
        let file = folder.appendingPathComponent("CLAUDE.md")
        let lines = courses.filter(\.isTracked).map { course -> ClaudeProject.CourseLine in
            let series = course.sortedSeries.first { $0.plannedWeek >= course.currentWeek && !$0.isComplete }
            let progress = series.map { "\($0.title.isEmpty ? "Série \($0.seriesNumber)" : $0.title) : \($0.doneCount)/\($0.requiredExercises.count) faits" }
            return .init(code: course.displayCode, name: course.name, week: course.currentWeek > 0 ? course.currentWeek : nil, progress: progress)
        }
        let date = Date().formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "fr_CH")))
        let context = ClaudeProject.context(courses: lines, week: courses.first(where: \.isTracked)?.currentWeek, date: date)
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
        for name in names {
            let target = skills.appendingPathComponent(name)
            if (try? manager.destinationOfSymbolicLink(atPath: target.path)) != nil || manager.fileExists(atPath: target.path) { continue }
            guard let source = buckets.map({ $0.appendingPathComponent(name) })
                .first(where: { manager.fileExists(atPath: $0.appendingPathComponent("SKILL.md").path) }) else { continue }
            try? manager.createDirectory(at: skills, withIntermediateDirectories: true)
            try? manager.createSymbolicLink(at: target, withDestinationURL: source)
        }
    }

    /// Les compétences du fichier présentes dans le projet.
    static func linkedSkills(settings: MacSettings) -> [String] {
        let folder = folder(settings)
        return (file(settings: settings)?.skills ?? []).filter {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent(".claude/skills/\($0)/SKILL.md").path)
        }
    }
}
