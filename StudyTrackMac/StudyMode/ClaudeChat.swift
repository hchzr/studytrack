import AppKit
import Foundation
import Observation
import OSLog

/// Une conversation avec Claude, **par l'abonnement** : un processus `claude`
/// (Claude Code, déjà connecté au compte Claude) par conversation.
///
/// Une conversation **par série** : son identifiant de session vient de la
/// série (`ClaudeTutor.sessionID`), Claude Code la garde sur le disque, et on
/// la reprend (`--resume`) — l'app peut être quittée, la conversation reste.
/// Changer d'exercice ne change pas de conversation : le nouvel exercice est
/// annoncé dans le message suivant. Les arguments, les messages et la lecture
/// du flux sont dans `ClaudeTutor` (pur, testé).
@MainActor
@Observable
final class ClaudeChat: Identifiable {
    struct Message: Identifiable, Equatable {
        enum Role { case student, claude }
        let id = UUID()
        var role: Role
        var text: String
        /// « Post-mortem », « Rapport » : une demande faite d'un bouton.
        var label: String?
        var attachments: [String] = []
        var images: [NSImage] = []
        var isStreaming = false
        var error: String?

        static func == (a: Message, b: Message) -> Bool {
            a.id == b.id && a.text == b.text && a.isStreaming == b.isStreaming && a.error == b.error
        }
    }

    /// Comment lancer Claude Code : isolé, ou dans le projet EPFL.
    struct Config: Equatable {
        var profile: ClaudeTutor.Profile = .isolated
        /// Le dossier de travail de `claude` (le projet, ou un dossier à lui).
        var folder: URL
        var mcpConfigPath: String?
        var allowedTools: [String] = []
        /// Ce qui est permis, en clair.
        var permissions: String

        static var isolated: Config {
            let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("StudyTrack/claude", isDirectory: true)
            return Config(folder: folder, permissions: "aucun outil")
        }
    }

    let id = UUID()
    /// La série de la conversation (`nil` : une conversation libre).
    let seriesID: UUID?
    let config: Config
    private(set) var sessionID: UUID
    private(set) var messages: [Message] = []
    private(set) var isThinking = false
    private(set) var isAnswering = false
    /// L'outil en cours (« Notion », « compétence »), pendant une réponse.
    private(set) var activeTool: String?
    /// Où en est la fenêtre de 5 h de l'abonnement (0 → 1).
    private(set) var usage: Double?
    /// Ce que Claude Code a annoncé au démarrage (compétences, MCP, permissions).
    private(set) var info: ClaudeTutor.SessionInfo?
    /// La taille du contexte de la dernière réponse, en jetons.
    private(set) var contextTokens: Int?
    var mode: ClaudeTutor.Mode = .tutor
    private var modeSent: ClaudeTutor.Mode?
    /// La série a été présentée à Claude (premier message, ou conversation reprise).
    private(set) var opened = false
    /// L'exercice dont Claude a reçu le contexte en dernier.
    private var exerciseSent: UUID?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: FileHandle?
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private var stderrText = ""
    /// La dernière ligne envoyée, et si une réponse a commencé : une session
    /// introuvable se relance une fois, avec la même ligne.
    @ObservationIgnored private var lastLine: String?
    @ObservationIgnored private var receivedAny = false
    @ObservationIgnored private var retried = false
    @ObservationIgnored private var forceResume: Bool?
    @ObservationIgnored private let log = Logger(subsystem: "com.hczr.studytrack.mac", category: "claude")

    init(seriesID: UUID?, config: Config) {
        self.seriesID = seriesID
        self.config = config
        sessionID = ClaudeTutor.sessionID(seriesID: seriesID ?? Self.freeSeries, profile: config.profile,
                                          generation: Self.generation(seriesID, config.profile))
        restore()
    }

    /// La « série » d'une conversation libre.
    private static let freeSeries = UUID(uuidString: "00000000-0000-0000-0000-00000000F4EE")!

    // MARK: Session gardée

    /// Une nouvelle conversation incrémente la génération : un autre identifiant.
    private static func generationKey(_ seriesID: UUID?, _ profile: ClaudeTutor.Profile) -> String {
        "mac.claude.generation.\((seriesID ?? freeSeries).uuidString).\(profile.rawValue)"
    }

    private static func generation(_ seriesID: UUID?, _ profile: ClaudeTutor.Profile) -> Int {
        UserDefaults.standard.integer(forKey: generationKey(seriesID, profile))
    }

    /// Le fichier où Claude Code garde la conversation.
    private var sessionFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(ClaudeTutor.sessionFolderName(workingDirectory: config.folder.path), isDirectory: true)
            .appendingPathComponent(sessionID.uuidString.lowercased() + ".jsonl")
    }

    private var hasSession: Bool { FileManager.default.fileExists(atPath: sessionFile.path) }

    /// Réaffiche une conversation déjà commencée.
    private func restore() {
        guard let data = try? Data(contentsOf: sessionFile) else { return }
        messages = ClaudeTutor.history(jsonl: String(decoding: data, as: UTF8.self)).map {
            Message(role: $0.fromStudent ? .student : .claude, text: $0.text)
        }
        opened = !messages.isEmpty
    }

    /// Repartir de zéro sur cette série (l'ancienne reste sur le disque).
    func startOver() {
        close()
        let key = Self.generationKey(seriesID, config.profile)
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: key) + 1, forKey: key)
        sessionID = ClaudeTutor.sessionID(seriesID: seriesID ?? Self.freeSeries, profile: config.profile,
                                          generation: Self.generation(seriesID, config.profile))
        messages = []
        opened = false
        exerciseSent = nil
        modeSent = nil
        info = nil
        contextTokens = nil
    }

    /// Le chemin de `claude`, s'il est installé.
    static var executable: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ClaudeTutor.candidatePaths(home: home)
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
    }

    static var isAvailable: Bool { executable != nil }

    /// `-mac.claudeModel haiku` (débogage) : un essai qui coûte peu ; sinon le
    /// modèle par défaut de l'abonnement.
    private static var debugModel: String? {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "mac.claudeModel")
        #else
        return nil
        #endif
    }

    // MARK: Envoyer

    /// Ce qu'il faut pour présenter la série et l'exercice en cours.
    struct Situation {
        var series: ClaudeTutor.SeriesContext?
        var exerciseID: UUID?
        var exercise: ClaudeTutor.Context
        /// La compétence à lancer au premier message (projet EPFL).
        var skill: String?
    }

    func send(_ text: String, label: String? = nil, attachments: [ClaudeTutor.Attachment] = [], images: [NSImage] = [],
              situation: Situation) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty, !isAnswering else { return }
        do {
            try startIfNeeded()
        } catch {
            messages.append(Message(role: .claude, text: "", error: error.localizedDescription))
            return
        }
        var prompt = ""
        if !opened, let series = situation.series {
            prompt += ClaudeTutor.openingMessage(series: series, exercise: situation.exerciseID == nil ? nil : situation.exercise,
                                                 skill: situation.skill)
            exerciseSent = situation.exerciseID
        } else if !opened {
            prompt += ClaudeTutor.contextPreamble(situation.exercise)
            exerciseSent = situation.exerciseID
        } else if let exerciseID = situation.exerciseID, exerciseID != exerciseSent {
            prompt += ClaudeTutor.exerciseSwitch(situation.exercise)
            exerciseSent = exerciseID
        }
        opened = true
        if modeSent != mode {
            if modeSent != nil || config.profile == .project {
                prompt += mode == .tutor
                    ? "(Mode tuteur : des indices, pas la solution.)\n\n"
                    : "(Mode explications : tu peux tout expliquer et donner des solutions.)\n\n"
            }
            modeSent = mode
        }
        if prompt.hasPrefix("/") {
            // La compétence d'abord, la question ensuite.
            prompt += "\n\n" + (trimmed.isEmpty ? "Regarde ce que je t'envoie." : trimmed)
        } else {
            prompt += trimmed.isEmpty ? "Regarde ce que je t'envoie." : trimmed
        }
        messages.append(Message(role: .student, text: trimmed, label: label, attachments: attachments.map(\.name), images: images))
        messages.append(Message(role: .claude, text: "", isStreaming: true))
        isAnswering = true
        isThinking = true
        let line = ClaudeTutor.userLine(text: prompt, attachments: attachments) + "\n"
        lastLine = line
        receivedAny = false
        retried = false
        input?.write(Data(line.utf8))
    }

    /// Arrête la réponse en cours (Claude Code n'a pas d'interruption en mode
    /// flux : le processus s'arrête, la conversation reprendra au message suivant).
    func stop() {
        process?.terminate()
        finishStreaming(error: nil)
    }

    func close() {
        process?.terminate()
        process = nil
        input = nil
    }

    // MARK: Processus

    enum Failure: LocalizedError {
        case notInstalled
        var errorDescription: String? {
            "Claude Code n'est pas installé. Installe-le (claude.com/code), puis tape `claude` une fois dans le Terminal."
        }
    }

    private func startIfNeeded() throws {
        if let process, process.isRunning { return }
        guard let executable = Self.executable else { throw Failure.notInstalled }
        let process = Process()
        process.executableURL = executable
        let resume = forceResume ?? hasSession
        forceResume = nil
        process.arguments = ClaudeTutor.arguments(.init(profile: config.profile, sessionID: sessionID.uuidString.lowercased(),
                                                        resume: resume, systemPrompt: ClaudeTutor.systemPrompt(mode: mode),
                                                        mcpConfigPath: config.mcpConfigPath, allowedTools: config.allowedTools,
                                                        model: Self.debugModel))
        try? FileManager.default.createDirectory(at: config.folder, withIntermediateDirectories: true)
        process.currentDirectoryURL = config.folder
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        // Jamais de clé d'API : l'abonnement, même si le shell en exporte une.
        environment.removeValue(forKey: "ANTHROPIC_API_KEY")
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.receive(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard !text.isEmpty else { return }
            Task { @MainActor in
                self?.stderrText += text
                self?.log.notice("claude stderr : \(text, privacy: .public)")
            }
        }
        process.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus
            Task { @MainActor in self?.ended(status: status) }
        }
        stderrText = ""
        try process.run()
        self.process = process
        input = stdin.fileHandleForWriting
        // Une conversation reprise connaît déjà la consigne, pas le mode courant.
        modeSent = resume ? nil : mode
        log.notice("claude lancé (\(self.config.profile.rawValue, privacy: .public), \(resume ? "reprise" : "nouvelle", privacy: .public))")
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let event = ClaudeTutor.parse(line: line) else { continue }
            receivedAny = true
            switch event {
            case .started(let info):
                self.info = info
            case .thinking:
                isThinking = true
            case .tool(let name):
                activeTool = ClaudeTutor.toolLabel(name)
                if let index = messages.lastIndex(where: { $0.role == .claude && $0.isStreaming }), !messages[index].text.isEmpty,
                   !messages[index].text.hasSuffix("\n\n") {
                    messages[index].text += "\n\n"
                }
            case .text(let piece):
                isThinking = false
                activeTool = nil
                if let index = messages.lastIndex(where: { $0.role == .claude }) { messages[index].text += piece }
            case .usage(let value):
                usage = value
            case .finished(let error, let tokens):
                if let tokens { contextTokens = tokens }
                finishStreaming(error: error)
            }
        }
    }

    private func finishStreaming(error: String?) {
        isAnswering = false
        isThinking = false
        activeTool = nil
        guard let index = messages.lastIndex(where: { $0.role == .claude && $0.isStreaming }) else { return }
        messages[index].isStreaming = false
        if let error {
            messages[index].error = error.lowercased().contains("login") || error.lowercased().contains("auth")
                ? "Claude Code n'est pas connecté. Tape `claude` dans le Terminal pour te connecter."
                : error
        }
    }

    private func ended(status: Int32) {
        process = nil
        input = nil
        // La session a disparu, ou existe déjà : on relance une fois, même message.
        if isAnswering, !receivedAny, !retried, let line = lastLine,
           let recovery = ClaudeTutor.sessionRecovery(stderr: stderrText) {
            retried = true
            forceResume = recovery == .resume
            log.notice("claude relancé (\(recovery == .resume ? "reprise" : "nouvelle", privacy: .public))")
            do {
                try startIfNeeded()
                input?.write(Data(line.utf8))
                return
            } catch {}
        }
        if isAnswering {
            let detail = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            finishStreaming(error: status == 0 ? nil : (detail.isEmpty ? "Claude s'est arrêté (code \(status))." : detail))
        }
    }
}
