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

    /// Le cours et la série côte à côte (⌘\\).
    var sideBySide = false

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
    /// Une pièce jointe préparée avec la question (ta copie GoodNotes).
    var pendingAttachment: ClaudeTutor.Attachment?
    /// Montrer ta copie (GoodNotes) à la place de l'énoncé.
    var showingCopy = false

    func ask(_ question: String, attachSeries: Bool = true) {
        pendingQuestion = question
        pendingAttachSeries = attachSeries
        pane = .claude
    }

    // MARK: Calcul

    var workbench = MathWorkbench.Session()
    var calcHistory: [(input: String, result: Result<MathWorkbench.Output, CalcError>)] = []

    // MARK: Documents

    /// Les PDF ouverts (séries, documents du cours), par adresse.
    enum Load: Equatable {
        case loading
        case ready(URL)
        case needsLogin
        case failed(String)
    }

    private(set) var documents: [String: Load] = [:]
    /// Les documents déjà retentés après une reconnexion silencieuse.
    @ObservationIgnored private var retried: Set<String> = []

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
                    throw URLError(.userAuthenticationRequired)
                }
                try? FileManager.default.removeItem(at: cached)
                try FileManager.default.copyItem(at: file, to: cached)
                documents[address] = .ready(cached)
            } catch {
                // Une page HTML à la place du PDF, sur un site EPFL : la session a
                // expiré. On se reconnecte sans rien afficher, puis on réessaie une fois.
                if url.host?.hasSuffix("epfl.ch") == true, !retried.contains(address) {
                    retried.insert(address)
                    await EPFLConnect.shared.connect(.moodle)
                    if EPFLConnect.shared.state(.moodle) == .connected {
                        documents[address] = nil
                        loadPDF(address)
                        return
                    }
                }
                documents[address] = url.host?.hasSuffix("epfl.ch") == true ? .needsLogin : .failed("Document introuvable.")
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
    var moodlePages: [Int: MoodleCoursePage] = [:]
    var moodleError: [Int: String] = [:]

    // MARK: Courseware et MediaSpace

    let courseware = CoursewareClient()
    let ed = EdClient()
    /// Les cours Ed de l'étudiant·e (`nil` : pas encore lus).
    var edCourses: [EdDiscussion.Course]?
    var edNeedsLogin = false
    var edThreads: [Int: [EdDiscussion.Thread]] = [:]
    var edLessons: [Int: [EdDiscussion.Lesson]] = [:]

    /// Lit les cours Ed une fois (et après une connexion).
    func loadEdCourses() async {
        guard edCourses == nil else { return }
        await EPFLConnect.shared.ensure(.ed)
        do {
            edCourses = try await ed.courses()
            edNeedsLogin = false
        } catch HiddenSiteSession.SiteError.notSignedIn {
            edNeedsLogin = true
        } catch {}
    }
    let mediaspace = MediaSpaceClient()
    var edxOutlines: [String: EdXOutline] = [:]

    // MARK: Connexion

    /// Le site où se connecter (la feuille de connexion, seule page web du bureau).
    var signIn: StudySite?
    /// Augmente à chaque connexion réussie : les lecteurs réessaient.
    private(set) var signInRevision = 0

    func signedIn(_ site: StudySite) {
        if site == .mediaspace {
            Task { await EPFLConnect.shared.connect(.mediaspace); signInRevision += 1 }
            return
        }
        // Connecté·e à Microsoft par Moodle : les autres sites suivent, sans rien
        // afficher (`EPFLConnect`).
        moodleError = [:]
        for (address, load) in documents where load == .needsLogin { documents[address] = nil }
        Task {
            try? await moodle.prepare(force: true)
            signInRevision += 1
            await EPFLConnect.shared.connectAll()
            ed.reset()
            edCourses = nil
            edNeedsLogin = false
            edThreads = [:]
            await loadEdCourses()
            signInRevision += 1
        }
    }

    func closeAll() {
        for chat in chats.values { chat.close() }
    }
}
