import AppKit
import CryptoKit
import Foundation
import Observation
import PDFKit
import SwiftUI

/// Le bureau du mode étude : un seul endroit pour tout ce qui sert à
/// travailler — la série, le cours (StudyTrack, Moodle, Botafogo), Claude, la
/// calculatrice, et le navigateur en dernier recours.
@MainActor
@Observable
final class StudyDesk {
    enum Pane: String, CaseIterable, Identifiable {
        case desk, exercise, course, claude, calc, web
        var id: String { rawValue }

        var title: String {
            switch self {
            case .desk: return "Bureau"
            case .exercise: return "Série"
            case .course: return "Cours"
            case .claude: return "Claude"
            case .calc: return "Calcul"
            case .web: return "Web"
            }
        }

        var icon: String {
            switch self {
            case .desk: return "moon.stars"
            case .exercise: return "doc.text"
            case .course: return "books.vertical"
            case .claude: return "sparkle"
            case .calc: return "function"
            case .web: return "globe"
            }
        }

        var shortcut: KeyEquivalent {
            switch self {
            case .desk: return "1"
            case .exercise: return "2"
            case .course: return "3"
            case .claude: return "4"
            case .calc: return "5"
            case .web: return "6"
            }
        }
    }

    var pane: Pane = .desk {
        didSet {
            #if DEBUG
            if CommandLine.arguments.contains("-tracePane") { FileHandle.standardError.write(Data("PANE \(oldValue) → \(pane)\n\(Thread.callStackSymbols.prefix(12).joined(separator: "\n"))\n".utf8)) }
            #endif
        }
    }

    // MARK: Claude

    /// Une conversation par série : on retrouve la sienne en y revenant, et
    /// Claude Code la garde d'un lancement de l'app à l'autre. Une conversation
    /// libre (`nil`) quand la session ne vise pas d'exercice.
    private(set) var chats: [UUID?: ClaudeChat] = [:]

    func chat(series seriesID: UUID?, config: ClaudeChat.Config) -> ClaudeChat {
        // Le réglage « projet EPFL » a changé : une autre conversation.
        if let chat = chats[seriesID], chat.config == config { return chat }
        chats[seriesID]?.close()
        let chat = ClaudeChat(seriesID: seriesID, config: config)
        chats[seriesID] = chat
        return chat
    }

    /// Une question préparée ailleurs (« Demander à Claude » sur un exercice).
    var pendingQuestion: String?
    var pendingAttachSeries = false

    func ask(_ question: String, attachSeries: Bool = true) {
        pendingQuestion = question
        pendingAttachSeries = attachSeries
        pane = .claude
    }

    // MARK: Calcul

    var calc = MathEngine.Environment()
    var calcHistory: [(input: String, output: String, isError: Bool)] = []

    // MARK: Documents

    /// Les PDF ouverts (séries, documents du cours), par adresse.
    enum Load: Equatable {
        case loading
        case ready(URL)
        case needsLogin
        case failed(String)
    }

    private(set) var documents: [String: Load] = [:]

    func document(_ address: String) -> Load? { documents[address] }

    /// Télécharge un PDF dans la session de Moodle (gardé en cache) : la
    /// connexion faite une fois dans le navigateur du mode étude sert ici.
    func loadPDF(_ address: String) {
        // Un fichier déjà sur le Mac (un PDF glissé, l'essai de débogage).
        if let url = URL(string: address), url.isFileURL, PDFDocument(url: url) != nil {
            documents[address] = .ready(url)
            return
        }
        guard let url = URL(string: address), url.scheme?.hasPrefix("http") == true else {
            documents[address] = .failed("Pas de document.")
            return
        }
        if case .ready? = documents[address] { return }
        if case .loading? = documents[address] { return }
        let cached = Self.cacheURL(for: address)
        if FileManager.default.fileExists(atPath: cached.path), PDFDocument(url: cached) != nil {
            documents[address] = .ready(cached)
            return
        }
        documents[address] = .loading
        Task { @MainActor in
            do {
                let file = try await AuthenticatedDownloader.download(url)
                guard PDFDocument(url: file) != nil else {
                    // Une page de connexion à la place du PDF.
                    documents[address] = .needsLogin
                    return
                }
                try? FileManager.default.removeItem(at: cached)
                try FileManager.default.copyItem(at: file, to: cached)
                documents[address] = .ready(cached)
            } catch {
                let text = error.localizedDescription.lowercased()
                documents[address] = text.contains("connect") || text.contains("login") ? .needsLogin : .failed(error.localizedDescription)
            }
        }
    }

    func retry(_ address: String) {
        documents[address] = nil
        try? FileManager.default.removeItem(at: Self.cacheURL(for: address))
        loadPDF(address)
    }

    static func cacheURL(for address: String) -> URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StudyTrack/pdf", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data(address.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".pdf")
    }

    /// Un PDF ouvert hors série (un document du cours, un fichier Moodle).
    var openedDocument: (title: String, address: String)?

    // MARK: Moodle et Botafogo

    let moodle = MoodleClient()
    var moodleOutlines: [Int: MoodleCourseSnapshot] = [:]
    var moodleError: [Int: String] = [:]

    // MARK: Courseware et MediaSpace

    let courseware = CoursewareClient()
    let mediaspace = MediaSpaceClient()
    var edxOutlines: [String: EdXOutline] = [:]

    // MARK: Connexion

    /// Le site où se connecter (la feuille de connexion, seule page web du bureau).
    var signIn: StudySite?
    /// Augmente à chaque connexion réussie : les lecteurs réessaient.
    private(set) var signInRevision = 0

    func signedIn(_ site: StudySite) {
        if site == .moodle {
            moodleError = [:]
            Task { try? await moodle.prepare(force: true); signInRevision += 1 }
        } else {
            signInRevision += 1
        }
        // Les PDF qui attendaient la connexion.
        for (address, load) in documents where load == .needsLogin { documents[address] = nil }
    }

    func closeAll() {
        for chat in chats.values { chat.close() }
    }
}
