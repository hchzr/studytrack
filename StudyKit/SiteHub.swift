import CryptoKit
import Foundation
import Observation
import PDFKit

/// Les sites du cours, **les mêmes sur l'iPhone et le Mac** : les clients
/// (Moodle, Courseware, MediaSpace, Ed), ce qu'on en a déjà lu (pages de cours,
/// plans, fils), les PDF téléchargés, et la connexion. Les lecteurs natifs
/// (`StudyKit`) lisent ici ; le bureau du Mac et le mode étude de l'iPhone
/// aussi. Les adresses viennent du profil de l'école (`Institution`).
@MainActor
@Observable
final class SiteHub {
    static let shared = SiteHub()

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
                if Institution.current.owns(host: url.host), !retried.contains(address) {
                    retried.insert(address)
                    await SchoolConnect.shared.refresh(.moodle)
                    if SchoolConnect.shared.state(.moodle) == .connected {
                        documents[address] = nil
                        loadPDF(address)
                        return
                    }
                }
                documents[address] = Institution.current.owns(host: url.host) ? .needsLogin : .failed("Document introuvable.")
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
        await SchoolConnect.shared.ensure(.ed)
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
            Task { await SchoolConnect.shared.connect(.mediaspace); signInRevision += 1 }
            return
        }
        // Connecté·e à Microsoft par Moodle : les autres sites suivent, sans rien
        // afficher (`SchoolConnect`).
        moodleError = [:]
        for (address, load) in documents where load == .needsLogin { documents[address] = nil }
        Task {
            try? await moodle.prepare(force: true)
            signInRevision += 1
            await SchoolConnect.shared.connectAll(force: true)
            ed.reset()
            edCourses = nil
            edNeedsLogin = false
            edThreads = [:]
            await loadEdCourses()
            signInRevision += 1
        }
    }

}
