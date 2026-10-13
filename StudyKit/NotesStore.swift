import Foundation
import Observation
import PDFKit

/// Les notes de l'étudiant·e sur le Mac : le dossier où son app de notes
/// sauvegarde ses cahiers en PDF (GoodNotes → Google Drive, iCloud Drive,
/// Dropbox…), trouvé tout seul ou choisi dans les Réglages. Les cahiers sont
/// rangés par cours et par semaine (`NotesLibrary`, pur).
@MainActor
@Observable
final class NotesStore {
    static let shared = NotesStore()

    private(set) var root: URL?
    private(set) var documents: [NotesLibrary.Document] = []
    private(set) var scannedAt: Date?

    /// Ta façon de nommer et les cahiers rangés à la main.
    var rules: NotesLibrary.Rules = {
        guard let data = UserDefaults.standard.data(forKey: "notes.rules"),
              let rules = try? JSONDecoder().decode(NotesLibrary.Rules.self, from: data) else { return .standard }
        return rules
    }() {
        didSet {
            if let data = try? JSONEncoder().encode(rules) { UserDefaults.standard.set(data, forKey: "notes.rules") }
            scannedAt = nil
        }
    }

    /// Les cahiers trouvés (pour les ranger à la main).
    var notebooks: [String] { Array(Set(documents.map(\.notebook))).filter { !$0.isEmpty }.sorted() }

    /// Le dossier choisi dans les Réglages (vide : trouvé automatiquement).
    var chosenFolder: String {
        get { UserDefaults.standard.string(forKey: "mac.notesFolder") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "mac.notesFolder"); scannedAt = nil }
    }

    /// Les endroits où GoodNotes (et les autres) sauvegardent d'habitude (Mac).
    static func candidates() -> [URL] {
        #if os(iOS)
        return []
        #else
        let home = FileManager.default.homeDirectoryForCurrentUser
        var result: [URL] = []
        let cloud = home.appendingPathComponent("Library/CloudStorage")
        for provider in (try? FileManager.default.contentsOfDirectory(at: cloud, includingPropertiesForKeys: nil)) ?? [] {
            let drive = provider.lastPathComponent.hasPrefix("GoogleDrive") ? provider.appendingPathComponent("My Drive") : provider
            for name in ["GoodNotes", "Goodnotes", "Notability", "Apps/GoodNotes 5", "Apps/Goodnotes"] {
                result.append(drive.appendingPathComponent(name))
            }
        }
        for name in ["GoodNotes", "Goodnotes", "Notability"] {
            result.append(home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/\(name)"))
            result.append(home.appendingPathComponent("Dropbox/Apps/\(name)"))
        }
        return result.filter { FileManager.default.fileExists(atPath: $0.path) }
        #endif
    }

    // MARK: Dossier choisi (iPhone : un dossier de Fichiers, gardé en signet)

    private static let bookmarkKey = "notes.folderBookmark"

    /// Retient un dossier choisi (Fichiers sur l'iPhone, Finder sur le Mac).
    func choose(_ url: URL) {
        #if os(iOS)
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        }
        #endif
        chosenFolder = url.path
    }

    private func bookmarkedFolder() -> URL? {
        #if os(iOS)
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return nil }
        var stale = false
        let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        _ = url?.startAccessingSecurityScopedResource()
        return url
        #else
        return nil
        #endif
    }

    /// Relit le dossier (une fois toutes les deux minutes au plus).
    func refresh(force: Bool = false) async {
        if !force, let scannedAt, Date().timeIntervalSince(scannedAt) < 120 { return }
        let folder = bookmarkedFolder()
            ?? (chosenFolder.isEmpty ? Self.candidates().first : URL(fileURLWithPath: (chosenFolder as NSString).expandingTildeInPath))
        root = folder
        scannedAt = Date()
        guard let folder else { documents = []; return }
        let rules = rules
        documents = await Task.detached(priority: .utility) { Self.scan(folder, rules: rules) }.value
    }

    nonisolated static func scan(_ folder: URL, rules: NotesLibrary.Rules = .standard) -> [NotesLibrary.Document] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var result: [NotesLibrary.Document] = []
        let base = folder.standardizedFileURL.path
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "pdf" {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            if let document = NotesLibrary.document(path: relative, modified: values?.contentModificationDate ?? .distantPast, rules: rules) {
                result.append(document)
            }
            if result.count > 5000 { break }
        }
        return result
    }

    func url(_ document: NotesLibrary.Document) -> URL? { root?.appendingPathComponent(document.path) }

    /// Le cours deviné (ou choisi) pour un cahier.
    func course(forNotebook notebook: String, among courses: [Course]) -> Course? {
        let keys = courses.map { NotesLibrary.CourseKey(code: $0.code, name: $0.name) }
        guard let key = NotesLibrary.course(forNotebook: notebook, among: keys, rules: rules) else { return nil }
        return courses.first { $0.code == key.code }
    }

    /// Les cahiers d'un cours.
    func documents(for course: Course, among courses: [Course]) -> [NotesLibrary.Document] {
        let keys = courses.map { NotesLibrary.CourseKey(code: $0.code, name: $0.name) }
        let mine = NotesLibrary.CourseKey(code: course.code, name: course.name)
        var cache: [String: Bool] = [:]
        return documents.filter { document in
            if let known = cache[document.notebook] { return known }
            let match = NotesLibrary.course(forNotebook: document.notebook, among: keys, rules: rules) == mine
            cache[document.notebook] = match
            return match
        }
    }

    /// La copie de l'étudiant·e pour une série.
    func copy(for series: ExerciseSeries, course: Course, among courses: [Course]) -> NotesLibrary.Document? {
        NotesLibrary.copy(seriesNumber: series.seriesNumber, week: series.plannedWeek > 0 ? series.plannedWeek : nil,
                          in: documents(for: course, among: courses))
    }

    /// Le PDF à montrer à Claude : entier s'il est court, sinon ses dernières
    /// pages (le travail le plus récent), pour rester léger.
    func attachmentData(_ document: NotesLibrary.Document, lastPages: Int = 12) -> Data? {
        guard let url = url(document), let pdf = PDFDocument(url: url) else { return nil }
        guard pdf.pageCount > lastPages else { return try? Data(contentsOf: url) }
        let trimmed = PDFDocument()
        for (offset, index) in ((pdf.pageCount - lastPages)..<pdf.pageCount).enumerated() {
            if let page = pdf.page(at: index) { trimmed.insert(page, at: offset) }
        }
        return trimmed.dataRepresentation()
    }
}
