import Foundation
import PDFKit
import SwiftData

/// Le serveur MCP local des fichiers (`Domain/LocalMCP.swift`), branché sur les
/// données du Mac : le catalogue de `LocalFileCatalog`, le dossier de notes, la
/// session Moodle de l'app et le dossier miroir (`LocalFilesMirror`).
///
/// Éteint par défaut. Allumé, il écoute sur 127.0.0.1 (aucune interrogation) ; le
/// projet Claude de l'app le déclare comme serveur `studytrack-files`.
@MainActor
final class MacLocalMCP {
    static let shared = MacLocalMCP()

    private var server: LocalMCPServer?
    private var container: ModelContainer?
    private(set) var lastError: String?

    /// L'adresse à donner à un client (jeton compris) ; `nil` si éteint.
    var url: URL? { server?.url }
    var isRunning: Bool { server?.isRunning == true }

    /// Où sont copiés les fichiers : dans le projet de Claude, qui peut donc les lire.
    static func mirrorRoot(_ settings: MacSettings) -> URL {
        #if DEBUG
        // `-localMCPRoot <dossier>` : un essai ne touche pas au vrai projet.
        if let index = CommandLine.arguments.firstIndex(of: "-localMCPRoot"), index + 1 < CommandLine.arguments.count {
            return URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        }
        #endif
        return ClaudeProjectSetup.folder(settings).appendingPathComponent("cours", isDirectory: true)
    }

    /// Le fichier où le pont de l'app Claude lit l'adresse du serveur (lisible par soi seul).
    private var infoURL: URL {
        #if DEBUG
        // `-localMCPInfo <fichier>` : un essai écrit ailleurs que dans les vrais réglages.
        if let index = CommandLine.arguments.firstIndex(of: "-localMCPInfo"), index + 1 < CommandLine.arguments.count {
            return URL(fileURLWithPath: CommandLine.arguments[index + 1])
        }
        #endif
        return ClaudeDesktopExtension.infoFile()
    }

    private func writeInfo(_ url: URL?) {
        let file = infoURL
        guard let url else { try? FileManager.default.removeItem(at: file); return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let body = (try? JSONSerialization.data(withJSONObject: ["url": url.absoluteString], options: [.sortedKeys])) ?? Data()
        try? body.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Démarre ou arrête le serveur selon le réglage. Appelée au lancement et
    /// quand le réglage change.
    func reapply(settings: MacSettings) async {
        guard let container else { return }
        await apply(settings: settings, container: container)
    }

    func apply(settings: MacSettings, container: ModelContainer) async {
        self.container = container
        var forced = false
        #if DEBUG
        forced = CommandLine.arguments.contains("-localMCP")
        #endif
        guard settings.localFilesServer || forced else {
            server?.stop()
            server = nil
            lastError = nil
            writeInfo(nil)
            return
        }
        // Un essai (`-localMCP`) n'écrit rien dans les vrais réglages.
        if settings.localFilesToken.isEmpty, !forced { settings.localFilesToken = LocalMCPRPC.makeToken() }
        var token = settings.localFilesToken.isEmpty ? LocalMCPRPC.makeToken() : settings.localFilesToken
        var wanted = UInt16(clamping: settings.localFilesPort)
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "-localMCPToken"), index + 1 < CommandLine.arguments.count { token = CommandLine.arguments[index + 1] }
        if let index = CommandLine.arguments.firstIndex(of: "-localMCPPort"), index + 1 < CommandLine.arguments.count { wanted = UInt16(CommandLine.arguments[index + 1]) ?? wanted }
        #endif
        if let current = server, current.isRunning, current.port == wanted { return }
        server?.stop()
        let provider = MacFilesProvider(settings: settings, container: container)
        let next = LocalMCPServer(token: token, provider: provider)
        // Le port habituel d'abord (l'adresse ne change pas d'un lancement à l'autre), un port libre sinon.
        var bound = await next.start(port: wanted)
        if bound == nil { bound = await next.start(port: 0) }
        guard let bound else {
            lastError = "Impossible d'ouvrir un port local."
            server = nil
            return
        }
        if !forced, bound != UInt16(clamping: settings.localFilesPort) { settings.localFilesPort = Int(bound) }
        server = next
        lastError = nil
        writeInfo(next.url)
    }
}

/// Les outils : ils lisent l'état de l'app sur le fil principal, rendent des chemins.
final class MacFilesProvider: LocalMCPProvider, @unchecked Sendable {
    private let settings: MacSettings
    private let container: ModelContainer

    init(settings: MacSettings, container: ModelContainer) {
        self.settings = settings
        self.container = container
    }

    let serverName = "studytrack-files"

    let instructions = """
    Les fichiers d'étude d'un·e étudiant·e de l'EPFL, sur son Mac : énoncés et corrigés de séries, anciens examens, transparents et documents des cours, fichiers ajoutés, cahiers du dossier de notes (copies, corrigés), notes de cours, fiche de révision, corrigés rédigés.
    - list_files (filtres : course, type, series, query) dit ce qui existe ; chaque ligne a un identifiant.
    - read_file(id) met le fichier sur le disque (téléchargé au besoin, aucune limite de taille) et rend son CHEMIN : ouvre-le avec Read (un PDF de plus de 10 pages : passe `pages`, ex. « 1-5 »). Un petit fichier texte est aussi rendu en texte.
    - fetch_all_files prépare tout un cours (ou tout) d'avance, par lots : rappelle-le tant qu'il reste des fichiers.
    - Le code d'un cours est celui de list_files (ex. MATH-101) ; l'état d'avancement (exercices, corrections) est dans le serveur « studytrack ».
    """

    var tools: [[String: Any]] {
        let course: [String: Any] = ["type": "string", "description": "Code du cours (ex. MATH-101) ou son nom"]
        let type: [String: Any] = ["type": "string", "enum": LocalFileCatalog.types,
                                   "description": "enonce, corrige (PDF de la série), examen, corrige-examen, support (transparents/notes d'un cours), document, ressource, cahier (dossier de notes), notes, fiche, corrige-texte, notes-examen"]
        let series: [String: Any] = ["type": "number", "description": "Numéro de série"]
        return [
            ["name": "list_files", "title": "Fichiers",
             "description": "Les fichiers d'étude : énoncés et corrigés PDF, anciens examens, supports de cours, ressources, cahiers de notes, notes, fiche, corrigés rédigés. Sans réseau : la liste seulement.",
             "inputSchema": ["type": "object", "properties": ["course": course, "type": type, "series": series,
                                                                  "query": ["type": "string", "description": "Mots du titre"],
                                                                  "limit": ["type": "number", "description": "300 par défaut"]]],
             "annotations": ["readOnlyHint": true]],
            ["name": "read_file", "title": "Lire un fichier",
             "description": "Met un fichier de list_files sur le disque (téléchargé si besoin) et rend son chemin, sa taille, son nombre de pages. À ouvrir avec Read. Avec inline (ou depuis l'app Claude) : le contenu lui-même — pages d'un PDF en images, texte en texte.",
             "inputSchema": ["type": "object",
                             "properties": ["id": ["type": "string", "description": "Identifiant donné par list_files"],
                                            "pages": ["type": "string", "description": "Pages d'un PDF, ex. « 1-5,8 » (inline : 5 par défaut, 8 au plus par appel)"],
                                            "inline": ["type": "boolean", "description": "Rendre le contenu plutôt qu'un chemin"]],
                             "required": ["id"]],
             "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true]],
            ["name": "fetch_all_files", "title": "Tout préparer",
             "description": "Télécharge d'avance les fichiers qui ne sont pas encore sur le disque (d'un cours, d'un type, ou tous), pendant 25 s au plus : rappelle-le tant que `restants` n'est pas 0.",
             "inputSchema": ["type": "object", "properties": ["course": course, "type": type, "series": series]],
             "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true]],
        ]
    }

    func call(_ name: String, arguments: [String: Any]) async -> [String: Any] {
        await Handlers.run(name, arguments: arguments, settings: settings, container: container)
    }

    @MainActor
    private enum Handlers {
        static func run(_ name: String, arguments: [String: Any], settings: MacSettings, container: ModelContainer) async -> [String: Any] {
            let courses = ((try? container.mainContext.fetch(FetchDescriptor<Course>())) ?? []).filter(\.isTracked)
            await NotesStore.shared.refresh()
            let notebooks = courses.flatMap { course in
                NotesStore.shared.documents(for: course, among: courses).compactMap { document in
                    NotesStore.shared.url(document).map { LocalFileCatalog.Notebook(courseID: course.id, document: document, url: $0) }
                }
            }
            let all = LocalFileCatalog.entries(courses: courses, notebooks: notebooks)
            let mirror = LocalFilesMirror(root: MacLocalMCP.mirrorRoot(settings))

            var course: Course?
            if let wanted = arguments["course"] as? String, !wanted.isEmpty {
                let key = LocalFileCatalog.fold(wanted)
                course = courses.first { LocalFileCatalog.fold($0.displayCode) == key || LocalFileCatalog.fold($0.code) == key }
                    ?? courses.first { LocalFileCatalog.fold($0.name).contains(key) }
                if course == nil {
                    return LocalMCPRPC.textResult("Cours « \(wanted) » introuvable. Cours : \(courses.map(\.displayCode).joined(separator: ", ")).", isError: true)
                }
            }
            let series = (arguments["series"] as? NSNumber)?.intValue
            let selected = LocalFileCatalog.filter(all, course: course, type: arguments["type"] as? String, series: series,
                                                   query: arguments["query"] as? String)
            switch name {
            case "list_files": return list(selected, mirror: mirror, limit: (arguments["limit"] as? NSNumber)?.intValue ?? 300)
            case "read_file":
                return await read(all, id: arguments["id"] as? String ?? "", mirror: mirror,
                                  inline: arguments["inline"] as? Bool ?? false, pages: arguments["pages"] as? String)
            case "fetch_all_files": return await fetchAll(selected, mirror: mirror)
            default: return LocalMCPRPC.textResult("Outil inconnu : \(name)", isError: true)
            }
        }

        static func list(_ entries: [LocalFileCatalog.Entry], mirror: LocalFilesMirror, limit: Int) -> [String: Any] {
            let shown = entries.prefix(max(1, limit)).map { entry -> [String: Any] in
                var line: [String: Any] = ["id": entry.id, "cours": entry.courseCode, "type": entry.type, "titre": entry.title]
                if let n = entry.seriesNumber { line["serie"] = n }
                if let w = entry.week { line["semaine"] = w }
                let file = mirror.existing(entry)
                line["telecharge"] = file != nil
                if let file { line["chemin"] = file.path }
                return line
            }
            var result: [String: Any] = ["total": entries.count, "dossier": mirror.root.path, "fichiers": shown]
            if shown.count < entries.count { result["avis"] = "\(entries.count - shown.count) de plus : précise course, type, series ou query." }
            return LocalMCPRPC.textResult(result)
        }

        static func read(_ all: [LocalFileCatalog.Entry], id: String, mirror: LocalFilesMirror, inline: Bool, pages: String?) async -> [String: Any] {
            guard let entry = all.first(where: { $0.id == id }) else {
                return LocalMCPRPC.textResult("Fichier inconnu : list_files donne les identifiants.", isError: true)
            }
            do {
                let file = try await mirror.ensure(entry)
                if inline { return inlineContent(entry, file: file, pages: pages) }
                let info = LocalFilesMirror.info(file)
                var result: [String: Any] = ["id": entry.id, "titre": entry.title, "chemin": file.path, "type_mime": info.mime,
                                             "taille": "\(max(1, info.bytes / 1024)) ko",
                                             "suite": "Ouvre `chemin` avec Read" + ((info.pages ?? 0) > 10 ? " (PDF de \(info.pages!) pages : passe `pages`, ex. « 1-5 »)." : ".")]
                if let pages = info.pages { result["pages"] = pages }
                if let text = info.text { result["contenu"] = text }
                return LocalMCPRPC.textResult(result)
            } catch {
                return LocalMCPRPC.textResult("« \(entry.title) » : \(error.localizedDescription)", isError: true)
            }
        }

        /// Le contenu lui-même, pour un client qui ne sait pas ouvrir un chemin (l'app Claude) :
        /// les pages d'un PDF en images (les formules restent lisibles), le texte en texte.
        static func inlineContent(_ entry: LocalFileCatalog.Entry, file: URL, pages: String?) -> [String: Any] {
            let ext = file.pathExtension.lowercased()
            let info = LocalFilesMirror.info(file)
            var content: [[String: Any]] = []
            func text(_ value: String) { content.append(["type": "text", "text": value]) }

            if ext == "pdf" {
                guard let document = PDFDocument(url: file), document.pageCount > 0 else {
                    return LocalMCPRPC.textResult("« \(entry.title) » : PDF illisible.", isError: true)
                }
                let total = document.pageCount
                let wanted = pages.flatMap { LocalFileCatalog.pageIndices($0, total: total) } ?? Array(0..<min(total, 5))
                let shown = Array(wanted.prefix(8))
                let last = (shown.max() ?? 0) + 1
                var header = "\(entry.title) — PDF de \(total) page\(total > 1 ? "s" : ""). Pages affichées : \(shown.map { String($0 + 1) }.joined(separator: ", "))."
                if wanted.count > shown.count { header += " (8 pages au plus par appel : demande la suite avec pages.)" }
                else if last < total && pages == nil { header += " Suite : pages « \(last + 1)-\(min(total, last + 8)) »." }
                text(header)
                for (index, data) in PDFPageRenderer.jpegPages(of: document, indices: shown) {
                    text("Page \(index + 1)")
                    content.append(["type": "image", "data": data.base64EncodedString(), "mimeType": "image/jpeg"])
                }
            } else if ["png", "jpg", "jpeg", "gif", "webp"].contains(ext), info.bytes <= 5_000_000, let data = try? Data(contentsOf: file) {
                text("\(entry.title) (image)")
                content.append(["type": "image", "data": data.base64EncodedString(), "mimeType": ext == "jpg" ? "image/jpeg" : "image/\(ext)"])
            } else if let readable = readableText(file: file, ext: ext) {
                let limit = 200_000
                text(readable.count > limit ? String(readable.prefix(limit)) + "\n\n[…tronqué : \(readable.count) caractères au total]" : readable)
            } else {
                text("« \(entry.title) » : format .\(ext) non lisible directement (\(max(1, info.bytes / 1024)) ko). Fichier : \(file.path)")
            }
            return ["content": content]
        }

        /// Le texte d'un fichier texte, ou d'un document Word/ODT/RTF (converti par `textutil`, déjà sur macOS).
        static func readableText(file: URL, ext: String) -> String? {
            if ["md", "txt", "tex", "csv", "json", "ipynb", "html", "py", "c", "h", "java", "ml", "scala", "rs"].contains(ext) {
                return try? String(contentsOf: file, encoding: .utf8)
            }
            guard ["doc", "docx", "odt", "rtf", "rtfd"].contains(ext) else { return nil }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
            process.arguments = ["-convert", "txt", "-stdout", file.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
        }

        static func fetchAll(_ entries: [LocalFileCatalog.Entry], mirror: LocalFilesMirror) async -> [String: Any] {
            let started = Date()
            var fetched = 0, already = 0
            var failures: [[String: String]] = []
            var remaining = 0
            for entry in entries {
                if case .text = entry.source { continue }
                // Une adresse déjà téléchargée n'est pas redemandée ; un fichier du Mac ou de la base se recopie s'il a changé.
                if case .remote = entry.source, mirror.existing(entry) != nil { already += 1; continue }
                if Date().timeIntervalSince(started) > 25 { remaining += 1; continue }
                do { _ = try await mirror.ensure(entry); fetched += 1 }
                catch { failures.append(["id": entry.id, "titre": entry.title, "raison": error.localizedDescription]) }
            }
            return LocalMCPRPC.textResult(["telecharges": fetched, "deja_la": already, "echecs": failures, "restants": remaining,
                                           "dossier": mirror.root.path])
        }
    }
}
