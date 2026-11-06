import AVFoundation
import Foundation
import Observation

/// Écouter un podcast (celui de NotebookLM, importé) pendant qu'on révise : lecture, ±15 s,
/// vitesse, position. Un seul à la fois ; le fichier reste sur l'appareil (il ne passe pas par iCloud).
@MainActor
@Observable
final class PodcastPlayer {
    static let shared = PodcastPlayer()

    private(set) var title: String?
    private(set) var file: URL?
    private(set) var isPlaying = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    var rate: Float = 1 {
        didSet { if isPlaying { player?.rate = rate } }
    }

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var observer: Any?

    var hasEpisode: Bool { file != nil }

    func play(_ url: URL, title: String) {
        if file == url {
            if !isPlaying { resume() }
            return
        }
        stopObserving()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let item = AVPlayerItem(url: url)
        let next = AVPlayer(playerItem: item)
        player = next
        file = url
        self.title = title
        elapsed = 0
        duration = 0
        observer = next.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.elapsed = time.seconds.isFinite ? time.seconds : 0
                let total = next.currentItem?.duration.seconds ?? 0
                if total.isFinite, total > 0 { self.duration = total }
                if self.duration > 0, self.elapsed >= self.duration - 0.3 { self.isPlaying = false }
            }
        }
        resume()
    }

    func resume() {
        guard let player else { return }
        player.playImmediately(atRate: rate)
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func toggle() { isPlaying ? pause() : resume() }

    func skip(by seconds: TimeInterval) { seek(to: elapsed + seconds) }

    func seek(to seconds: TimeInterval) {
        let target = min(max(0, seconds), duration > 0 ? duration : seconds)
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        elapsed = target
    }

    func stop() {
        player?.pause()
        stopObserving()
        player = nil
        file = nil
        title = nil
        isPlaying = false
        elapsed = 0
        duration = 0
    }

    private func stopObserving() {
        if let observer, let player { player.removeTimeObserver(observer) }
        observer = nil
    }
}

/// Où sont gardés les podcasts importés : `Application Support/Polymestre/Podcasts/<cours>/`.
enum PodcastStore {
    static func folder(for course: Course) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = base.appending(path: "Polymestre/Podcasts/\(course.id.uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func url(for resource: StudyMap.Resource, in course: Course) -> URL? {
        guard let name = resource.fileName, let folder = folder(for: course) else { return nil }
        let file = folder.appending(path: name)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// Copie un fichier choisi dans le dossier du cours ; rend le nom gardé.
    static func importFile(_ source: URL, for course: Course) -> String? {
        guard let folder = folder(for: course) else { return nil }
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        var name = source.lastPathComponent
        var destination = folder.appending(path: name)
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            name = "\(source.deletingPathExtension().lastPathComponent) \(counter).\(source.pathExtension)"
            destination = folder.appending(path: name)
            counter += 1
        }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return name
        } catch {
            return nil
        }
    }

    static func remove(_ resource: StudyMap.Resource, from course: Course) {
        guard let url = url(for: resource, in: course) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Les sources de NotebookLM, écrites dans un dossier temporaire.
    static func writeSources(_ files: [NotebookExport.File], code: String) -> [URL] {
        let folder = FileManager.default.temporaryDirectory.appending(path: "NotebookLM-\(code)", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return files.compactMap { file in
            let url = folder.appending(path: file.name.replacingOccurrences(of: "/", with: "-"))
            do { try file.text.write(to: url, atomically: true, encoding: .utf8); return url } catch { return nil }
        }
    }
}
