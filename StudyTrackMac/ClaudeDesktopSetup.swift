import AppKit
import Foundation

/// « Ajouter à l'app Claude » : fabrique l'extension (`ClaudeDesktopExtension`),
/// en fait un `.mcpb` et l'ouvre — l'app Claude propose de l'installer.
@MainActor
enum ClaudeDesktopSetup {

    enum Failure: LocalizedError {
        case zip
        var errorDescription: String? { "l'extension n'a pas pu être fabriquée." }
    }

    static var packageURL: URL {
        ClaudeDesktopExtension.infoFile().deletingLastPathComponent().appendingPathComponent("StudyTrack.mcpb")
    }

    /// Fabrique le `.mcpb` (un zip : manifeste + pont) et rend son adresse.
    static func build() throws -> URL {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("studytrack-mcpb-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        for (path, data) in ClaudeDesktopExtension.files(appID: Bundle.main.bundleIdentifier ?? "com.hczr.studytrack.mac") {
            let file = work.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        let output = packageURL
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: output)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = work
        zip.arguments = ["-q", "-r", "-X", output.path, "manifest.json", "server"]
        zip.standardOutput = Pipe()
        zip.standardError = Pipe()
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0, FileManager.default.fileExists(atPath: output.path) else { throw Failure.zip }
        return output
    }

    /// L'extension est-elle déjà dans l'app Claude ? (dossier « Claude Extensions », manifeste du même nom)
    static var isInstalled: Bool {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/Claude Extensions", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.contains { name in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name).appendingPathComponent("manifest.json")),
                  let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return manifest["name"] as? String == ClaudeDesktopExtension.name
        }
    }

    /// L'app Claude est-elle sur ce Mac ? (celle qui ouvre les `.mcpb`)
    static var claudeAppFound: Bool {
        NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: "/tmp/x.mcpb")) != nil
    }

    /// Allume le serveur local, fabrique l'extension et l'ouvre dans l'app Claude.
    static func install(settings: MacSettings) async throws {
        if !settings.localFilesServer { settings.localFilesServer = true }
        await MacLocalMCP.shared.reapply(settings: settings)
        let package = try build()
        if !NSWorkspace.shared.open(package) { NSWorkspace.shared.activateFileViewerSelecting([package]) }
    }
}
