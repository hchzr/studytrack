import AppKit
import Foundation
import Observation
import OSLog

/// Une conversation avec Claude, **par l'abonnement** : un processus `claude`
/// (Claude Code, déjà connecté au compte Claude) qui garde la conversation en
/// mémoire tant qu'elle dure. Les arguments, les messages et la lecture du flux
/// sont dans `ClaudeTutor` (pur, testé).
@MainActor
@Observable
final class ClaudeChat: Identifiable {
    struct Message: Identifiable, Equatable {
        enum Role { case student, claude }
        let id = UUID()
        var role: Role
        var text: String
        var attachments: [String] = []
        var images: [NSImage] = []
        var isStreaming = false
        var error: String?

        static func == (a: Message, b: Message) -> Bool {
            a.id == b.id && a.text == b.text && a.isStreaming == b.isStreaming && a.error == b.error
        }
    }

    let id = UUID()
    /// La cible du chrono à laquelle cette conversation se rapporte.
    let targetID: UUID?
    private(set) var messages: [Message] = []
    private(set) var isThinking = false
    private(set) var isAnswering = false
    /// Où en est la fenêtre de 5 h de l'abonnement (0 → 1).
    private(set) var usage: Double?
    var mode: ClaudeTutor.Mode = .tutor
    private var modeSent: ClaudeTutor.Mode?
    private var contextSent = false

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: FileHandle?
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private let log = Logger(subsystem: "com.hczr.studytrack.mac", category: "claude")

    init(targetID: UUID?) {
        self.targetID = targetID
    }

    /// Le chemin de `claude`, s'il est installé.
    static var executable: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ClaudeTutor.candidatePaths(home: home)
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
    }

    static var isAvailable: Bool { executable != nil }

    // MARK: Envoyer

    func send(_ text: String, attachments: [ClaudeTutor.Attachment] = [], images: [NSImage] = [],
              context: ClaudeTutor.Context) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty, !isAnswering else { return }
        do {
            try startIfNeeded()
        } catch {
            messages.append(Message(role: .claude, text: "", error: error.localizedDescription))
            return
        }
        var prompt = ""
        if !contextSent {
            prompt += ClaudeTutor.contextPreamble(context)
            contextSent = true
        }
        if modeSent != mode {
            if modeSent != nil {
                prompt += mode == .tutor
                    ? "(À partir de maintenant : mode tuteur — des indices, pas la solution.)\n\n"
                    : "(À partir de maintenant : mode explications — tu peux tout expliquer et donner des solutions.)\n\n"
            }
            modeSent = mode
        }
        prompt += trimmed.isEmpty ? "Regarde ce que je t'envoie." : trimmed
        messages.append(Message(role: .student, text: trimmed, attachments: attachments.map(\.name), images: images))
        messages.append(Message(role: .claude, text: "", isStreaming: true))
        isAnswering = true
        isThinking = true
        let line = ClaudeTutor.userLine(text: prompt, attachments: attachments) + "\n"
        input?.write(Data(line.utf8))
    }

    /// Arrête la réponse en cours (et la conversation : Claude Code n'a pas
    /// d'interruption en mode flux). La prochaine question repart à neuf.
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
            "Claude Code n'est pas installé sur ce Mac. Installe-le (claude.com/code), connecte-toi une fois avec ton compte Claude dans le Terminal (`claude`), puis réessaie : StudyTrack passe par ton abonnement."
        }
    }

    private func startIfNeeded() throws {
        if let process, process.isRunning { return }
        guard let executable = Self.executable else { throw Failure.notInstalled }
        let process = Process()
        process.executableURL = executable
        process.arguments = ClaudeTutor.arguments(systemPrompt: ClaudeTutor.systemPrompt(mode: mode))
        // Un dossier à lui : Claude Code ne lit ni le projet ni ses réglages.
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StudyTrack/claude", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        process.currentDirectoryURL = directory
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
            Task { @MainActor in self?.log.notice("claude stderr : \(text, privacy: .public)") }
        }
        process.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus
            Task { @MainActor in self?.ended(status: status) }
        }
        try process.run()
        self.process = process
        input = stdin.fileHandleForWriting
        contextSent = false
        modeSent = nil
        log.notice("claude lancé")
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let event = ClaudeTutor.parse(line: line) else { continue }
            switch event {
            case .thinking:
                isThinking = true
            case .text(let piece):
                isThinking = false
                if let index = messages.lastIndex(where: { $0.role == .claude }) { messages[index].text += piece }
            case .usage(let value):
                usage = value
            case .finished(let error):
                finishStreaming(error: error)
            }
        }
    }

    private func finishStreaming(error: String?) {
        isAnswering = false
        isThinking = false
        guard let index = messages.lastIndex(where: { $0.role == .claude && $0.isStreaming }) else { return }
        messages[index].isStreaming = false
        if let error {
            messages[index].error = error.lowercased().contains("login") || error.lowercased().contains("auth")
                ? "Claude Code n'est pas connecté. Ouvre le Terminal, tape `claude`, connecte-toi avec ton compte Claude, puis réessaie."
                : error
        }
    }

    private func ended(status: Int32) {
        process = nil
        input = nil
        if isAnswering {
            finishStreaming(error: status == 0 ? nil : "Claude s'est arrêté (code \(status)). Repose ta question.")
        }
    }
}
