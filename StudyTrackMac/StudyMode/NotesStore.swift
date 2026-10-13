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

    /// Le dossier choisi dans les Réglages (vide : trouvé automatiquement).
    var chosenFolder: String {
        get { UserDefaults.standard.string(forKey: "mac.notesFolder") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "mac.notesFolder"); scannedAt = nil }
    }

    /// Les endroits où GoodNotes (et les autres) sauvegardent d'habitude.
    static func candidates() -> [URL] {
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
    }

    /// Relit le dossier (une fois toutes les deux minutes au plus).
    func refresh(force: Bool = false) async {
        if !force, let scannedAt, Date().timeIntervalSince(scannedAt) < 120 { return }
        let folder = chosenFolder.isEmpty ? Self.candidates().first : URL(fileURLWithPath: (chosenFolder as NSString).expandingTildeInPath)
        root = folder
        scannedAt = Date()
        guard let folder else { documents = []; return }
        documents = await Task.detached(priority: .utility) { Self.scan(folder) }.value
    }

    nonisolated static func scan(_ folder: URL) -> [NotesLibrary.Document] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var result: [NotesLibrary.Document] = []
        let base = folder.standardizedFileURL.path
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "pdf" {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            if let document = NotesLibrary.document(path: relative, modified: values?.contentModificationDate ?? .distantPast) {
                result.append(document)
            }
            if result.count > 5000 { break }
        }
        return result
    }

    func url(_ document: NotesLibrary.Document) -> URL? { root?.appendingPathComponent(document.path) }

    /// Les cahiers d'un cours.
    func documents(for course: Course, among courses: [Course]) -> [NotesLibrary.Document] {
        let keys = courses.map { NotesLibrary.CourseKey(code: $0.code, name: $0.name) }
        let mine = NotesLibrary.CourseKey(code: course.code, name: course.name)
        var cache: [String: Bool] = [:]
        return documents.filter { document in
            if let known = cache[document.notebook] { return known }
            let match = NotesLibrary.course(forNotebook: document.notebook, among: keys) == mine
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
