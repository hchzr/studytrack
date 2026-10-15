import CryptoKit
import Foundation

/// Un seul lecteur pour le Mac et l'iPhone : ce qui joue sur l'un se voit et
/// se pilote depuis l'autre, et la musique passe de l'un à l'autre à la même
/// seconde.
///
/// Les messages voyagent par le lien du chrono (`TimerLink`, le relais du
/// compte, chiffrés de la même clé) : rien à appairer, ~70 ms. Chaque
/// appareil publie **son** état quand il change (un morceau, une pause — pas
/// la position, qui se déduit de l'instant de lecture) ; une commande vise un
/// appareil. Le relais garde le dernier état de chacun : un appareil qui
/// s'ouvre voit tout de suite ce qui joue ailleurs.
///
/// Pur, testé dans `validate.sh`.
enum MusicLink {

    enum Platform: String, Codable, Equatable {
        case mac, iphone, ipad

        var label: String {
            switch self {
            case .mac: return "Mac"
            case .iphone: return "iPhone"
            case .ipad: return "iPad"
            }
        }

        var icon: String {
            switch self {
            case .mac: return "laptopcomputer"
            case .iphone: return "iphone"
            case .ipad: return "ipad"
            }
        }
    }

    struct Item: Codable, Equatable {
        var title: String?
        var artist: String?
        var album: String?
        var duration: TimeInterval = 0
    }

    /// Ce qui joue sur un appareil.
    struct State: Codable, Equatable {
        var device: String
        var platform: Platform
        var title: String?
        var artist: String?
        var album: String?
        var duration: TimeInterval = 0
        var elapsed: TimeInterval = 0
        var readAt: Date
        var isPlaying = false
        var shuffle = false
        /// `off`, `all`, `one`.
        var repeatMode = "off"
        var volume: Double?
        var artworkURL: String?
        var upNext: [Item] = []
        var updatedAt: Date

        var hasTrack: Bool { title != nil }

        func elapsed(at date: Date) -> TimeInterval {
            guard isPlaying else { return elapsed }
            return min(duration > 0 ? duration : .infinity, max(0, elapsed + date.timeIntervalSince(readAt)))
        }

        /// Joue-t-il encore, vraisemblablement ? Un état « en lecture » publié
        /// il y a longtemps (l'appareil s'est éteint sans le dire) ne compte plus
        /// au-delà de la fin du morceau, plus une marge.
        func isLive(at date: Date) -> Bool {
            guard isPlaying else { return false }
            let horizon = duration > 0 ? max(0, duration - elapsed) + 120 : 3600
            return date.timeIntervalSince(readAt) < horizon
        }
    }

    enum Action: Codable, Equatable {
        case toggle, play, pause, next, previous
        case seek(TimeInterval)
        case volume(Double)
        case shuffle(Bool)
        case repeatMode(String)
        /// Jouer ces morceaux du catalogue (identifiants Apple Music), à partir de `index`.
        case playCatalog([String], index: Int, shuffled: Bool)
        /// À suivre (`next`) ou à la fin de la file.
        case enqueue([String], next: Bool)
        /// Reprendre ici ce morceau, à cette seconde (la musique change d'appareil).
        case handoff(Item, elapsed: TimeInterval, playing: Bool)
        /// Publie ton état (un appareil qui s'ouvre le demande).
        case announce
    }

    struct Command: Codable, Equatable {
        var id = UUID()
        var from: String
        /// L'appareil visé (`nil` : tous les autres).
        var to: String?
        var action: Action
        var sentAt: Date
    }

    enum Message: Codable, Equatable {
        case state(State)
        case command(Command)
    }

    // MARK: Chiffrement (la clé du lien du chrono)

    static func seal(_ message: Message, key: SymmetricKey) -> String? {
        guard let data = try? JSONEncoder().encode(message),
              let box = try? AES.GCM.seal(data, using: key), let combined = box.combined else { return nil }
        return combined.base64EncodedString()
    }

    static func open(_ text: String, key: SymmetricKey) -> Message? {
        guard let data = Data(base64Encoded: text), let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return try? JSONDecoder().decode(Message.self, from: plain)
    }

    // MARK: Quel lecteur montrer

    enum Route: Equatable {
        case local
        case remote(String)
    }

    /// Le lecteur à montrer : celui qui joue. Ici d'abord ; sinon un autre
    /// appareil qui joue encore ; sinon le choix fait à la main ; sinon ce qui
    /// a un morceau (ici d'abord).
    static func route(localPlaying: Bool, localHasTrack: Bool, remotes: [State], pinned: String?, now: Date) -> Route {
        if localPlaying { return .local }
        if let playing = remotes.filter({ $0.isLive(at: now) }).max(by: { $0.updatedAt < $1.updatedAt }) {
            return .remote(playing.device)
        }
        if let pinned, remotes.contains(where: { $0.device == pinned && $0.hasTrack }) { return .remote(pinned) }
        if localHasTrack { return .local }
        if let other = remotes.filter(\.hasTrack).max(by: { $0.updatedAt < $1.updatedAt }) { return .remote(other.device) }
        return .local
    }

    /// Faut-il republier ? Pas pour une position qui avance d'elle-même : un
    /// autre morceau, une pause, un saut, la file, le volume.
    static func changed(_ old: State?, _ new: State) -> Bool {
        guard let old else { return true }
        if old.title != new.title || old.artist != new.artist || old.isPlaying != new.isPlaying || old.shuffle != new.shuffle
            || old.repeatMode != new.repeatMode || old.upNext != new.upNext || old.artworkURL != new.artworkURL {
            return true
        }
        if let a = old.volume, let b = new.volume, abs(a - b) > 0.02 { return true }
        if (old.volume == nil) != (new.volume == nil) { return true }
        // Un saut dans le morceau : la position attendue et la lue divergent.
        return abs(old.elapsed(at: new.readAt) - new.elapsed) > 3
    }
}
