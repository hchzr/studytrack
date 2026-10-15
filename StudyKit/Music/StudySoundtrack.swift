import Foundation
import MusicKit
import Observation

/// La bande-son de la session : joue la playlist choisie au début, la couvre
/// d'un fondu pendant les pauses, l'éteint à la fin — sans jamais arrêter une
/// musique qu'on n'a pas lancée. Les décisions sont dans `SessionSoundtrack`
/// (pur, testé) ; ici, seulement les gestes sur le lecteur.
@MainActor
final class StudySoundtrack {
    static let shared = StudySoundtrack()

    var choice: SessionSoundtrack.Choice?
    var breakPolicy: SessionSoundtrack.BreakPolicy = .pause

    private var previous: SessionSoundtrack.Phase?
    /// La musique en route est celle que nous avons lancée.
    private var ownsPlayback = false
    /// Le volume d'avant un fondu ou une baisse (Mac seulement).
    private var savedVolume: Double?
    private var fade: Task<Void, Never>?
    private let music = StudyMusic.shared

    /// À chaque changement du chrono. `moment` : ce que fait la session.
    func update(phase: SessionSoundtrack.Phase, moment: DeskMoment) {
        let action = SessionSoundtrack.action(from: previous, to: phase, moment: moment, hasChoice: choice != nil,
                                              ownsPlayback: ownsPlayback, policy: breakPolicy)
        previous = phase
        switch action {
        case .none: break
        case .start: start()
        case .fadeOutAndPause: fadeOut { [weak self] in self?.pauseIfPlaying() }
        case .resumeAndFadeIn: fadeIn()
        case .lower: lower()
        case .restoreVolume: restore()
        case .fadeOutAndStop:
            ownsPlayback = false
            fadeOut { [weak self] in self?.pauseIfPlaying() }
        }
    }

    // MARK: Gestes

    private func start() {
        // Une musique déjà en route est celle de l'étudiant·e : on ne la remplace pas.
        guard !music.nowPlaying.isPlaying, let choice else { return }
        Task {
            guard let collection = await Self.collection(for: choice) else { return }
            music.play(collection, shuffled: choice.shuffled)
            ownsPlayback = true
        }
    }

    private func pauseIfPlaying() {
        if music.nowPlaying.isPlaying { music.togglePlayPause() }
    }

    /// Baisse à zéro en ~2 s, puis `done` ; le volume d'origine est rétabli (sans bruit) ensuite.
    private func fadeOut(then done: @escaping () -> Void) {
        fade?.cancel()
        guard let volume = music.volume else { done(); return }
        let original = savedVolume ?? volume
        savedVolume = original
        fade = Task { [weak self] in
            for level in SessionSoundtrack.fade(from: volume, to: 0, steps: 10) {
                guard !Task.isCancelled, let self else { return }
                self.music.setVolume(level)
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard !Task.isCancelled, let self else { return }
            done()
            // Le volume attend la reprise à zéro ; on le rétablit une fois en pause.
            try? await Task.sleep(for: .milliseconds(400))
            self.music.setVolume(original)
            self.savedVolume = nil
        }
    }

    private func fadeIn() {
        fade?.cancel()
        let target = savedVolume ?? music.volume ?? 1
        savedVolume = nil
        guard music.volume != nil else {
            if !music.nowPlaying.isPlaying { music.togglePlayPause() }
            return
        }
        fade = Task { [weak self] in
            guard let self else { return }
            self.music.setVolume(0)
            if !self.music.nowPlaying.isPlaying { self.music.togglePlayPause() }
            for level in SessionSoundtrack.fade(from: 0, to: target, steps: 10) {
                guard !Task.isCancelled else { return }
                self.music.setVolume(level)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func lower() {
        guard let volume = music.volume else { return }
        savedVolume = savedVolume ?? volume
        music.setVolume(volume * 0.3)
    }

    private func restore() {
        guard let saved = savedVolume else { return }
        savedVolume = nil
        music.setVolume(saved)
    }

    // MARK: Le choix

    /// Les playlists de la bibliothèque, les plus récemment écoutées d'abord.
    static func libraryPlaylists() async -> [SessionSoundtrack.Choice] {
        guard let response = try? await MusicLibraryRequest<Playlist>().response() else { return [] }
        return response.items
            .sorted { ($0.lastPlayedDate ?? .distantPast) > ($1.lastPlayedDate ?? .distantPast) }
            .prefix(40)
            .map { SessionSoundtrack.Choice(kind: .playlist, id: $0.id.rawValue, title: $0.name) }
    }

    static func collection(for choice: SessionSoundtrack.Choice) async -> MusicCollection? {
        let id = MusicItemID(choice.id)
        switch choice.kind {
        case .playlist:
            var library = MusicLibraryRequest<Playlist>()
            library.filter(matching: \.id, equalTo: id)
            if let playlist = try? await library.response().items.first { return .playlist(playlist) }
            let catalog = MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: id)
            return (try? await catalog.response().items.first).map { .playlist($0) }
        case .album:
            let catalog = MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: id)
            return (try? await catalog.response().items.first).map { .album($0) }
        }
    }
}
