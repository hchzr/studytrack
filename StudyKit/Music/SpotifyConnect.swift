import AuthenticationServices
import Combine
import Foundation
import Observation
import Security
import SpotifyWebAPI
import SwiftUI

/// Spotify Connect, sur l'iPhone et le Mac, par la bibliothèque SpotifyAPI (Peter-Schorn) :
/// ce qui joue sur n'importe lequel de tes appareils Spotify (ce Mac, le téléphone, une
/// enceinte), le piloter, le déplacer, lancer une playlist. Connexion PKCE dans la feuille du
/// système (`studytrack://spotify-callback`, aucun secret dans l'app) ; la bibliothèque
/// rafraîchit les jetons, et son gestionnaire d'autorisation (Codable) est gardé au trousseau,
/// sur cet appareil seulement. Le pilotage demande Spotify Premium.
/// Le même service que Windows (`windows/src/services/spotify.ts`).
@MainActor
@Observable
final class SpotifyConnect {
    static let shared = SpotifyConnect()

    /// L'app Spotify de StudyTrack (developer.spotify.com) ; un autre identifiant peut être collé
    /// dans le volet Musique. Public : avec PKCE, il n'y a pas de secret.
    static let builtInClientID = ""
    static let redirect = URL(string: "studytrack://spotify-callback")!
    private static let scopes: Set<Scope> = [
        .userReadPlaybackState, .userModifyPlaybackState, .userReadCurrentlyPlaying,
        .playlistReadPrivate, .playlistReadCollaborative, .userLibraryRead,
    ]
    private static let keychainAccount = "spotify.authorization"

    struct Device: Identifiable, Equatable { var id: String; var name: String; var type: String; var isActive: Bool }
    struct Track: Equatable { var title: String; var artists: String; var album: String; var artwork: URL? }
    struct Playback: Equatable { var isPlaying: Bool; var device: Device?; var track: Track? }
    struct Playlist: Identifiable, Equatable { var id: String; var uri: String; var name: String; var image: URL?; var tracks: Int }

    private(set) var isConnected = false
    private(set) var playback: Playback?
    private(set) var devices: [Device] = []
    private(set) var playlists: [Playlist] = []
    var lastError: String?

    @ObservationIgnored private var api: SpotifyAPI<AuthorizationCodeFlowPKCEManager>
    @ObservationIgnored private var saving: AnyCancellable?

    var clientID: String {
        get { UserDefaults.standard.string(forKey: "spotify.clientID").flatMap { $0.isEmpty ? nil : $0 } ?? Self.builtInClientID }
        set {
            UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "spotify.clientID")
            api = Self.makeAPI(clientID: clientID)
            observe()
        }
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: "spotify.clientID").flatMap { $0.isEmpty ? nil : $0 } ?? Self.builtInClientID
        api = Self.makeAPI(clientID: stored)
        isConnected = api.authorizationManager.isAuthorized()
        observe()
    }

    /// La session gardée au trousseau si elle existe, sinon une neuve.
    private static func makeAPI(clientID: String) -> SpotifyAPI<AuthorizationCodeFlowPKCEManager> {
        if let data = keychainRead(), let manager = try? JSONDecoder().decode(AuthorizationCodeFlowPKCEManager.self, from: data),
           manager.clientId == clientID {
            return SpotifyAPI(authorizationManager: manager)
        }
        return SpotifyAPI(authorizationManager: AuthorizationCodeFlowPKCEManager(clientId: clientID))
    }

    /// Chaque nouveau jeton (connexion, rafraîchissement) repart au trousseau.
    private func observe() {
        saving = api.authorizationManagerDidChange.receive(on: RunLoop.main).sink { [weak self] in
            guard let self else { return }
            if let data = try? JSONEncoder().encode(api.authorizationManager) { Self.keychainWrite(data) }
            isConnected = api.authorizationManager.isAuthorized()
        }
    }

    // MARK: Connexion

    func signIn() async {
        lastError = nil
        guard !clientID.isEmpty else { lastError = String(localized: "Il manque l'identifiant de l'app Spotify."); return }
        let verifier = String.randomURLSafe(length: 128)
        let state = String.randomURLSafe(length: 32)
        guard let url = api.authorizationManager.makeAuthorizationURL(
            redirectURI: Self.redirect, codeChallenge: String.makeCodeChallenge(codeVerifier: verifier), state: state, scopes: Self.scopes
        ) else { lastError = String(localized: "Adresse de connexion Spotify impossible."); return }
        do {
            let callback = try await SupabaseOAuthWebSession.shared.authenticate(url: url)
            try await Self.wait(api.authorizationManager.requestAccessAndRefreshTokens(
                redirectURIWithQuery: callback, codeVerifier: verifier, state: state))
            isConnected = true
            await refresh(includingPlaylists: true)
        } catch {
            lastError = Self.message(error)
        }
    }

    func signOut() {
        api.authorizationManager.deauthorize()
        Self.keychainWrite(nil)
        isConnected = false
        playback = nil
        devices = []
        playlists = []
    }

    // MARK: Lire et piloter

    /// Relit ce qui joue et les appareils (à l'ouverture du volet, après un geste).
    func refresh(includingPlaylists: Bool = false) async {
        guard isConnected else { return }
        do {
            if let context = try await Self.value(api.currentPlayback()) ?? nil {
                playback = Playback(isPlaying: context.isPlaying, device: Self.device(context.device), track: Self.track(context.item))
            } else {
                playback = nil
            }
            devices = try await Self.value(api.availableDevices()).map(Self.device)
            if includingPlaylists || playlists.isEmpty {
                playlists = try await Self.value(api.currentUserPlaylists(limit: 50)).items.map { playlist in
                    Playlist(id: playlist.id, uri: playlist.uri, name: playlist.name,
                             image: playlist.images.first?.url, tracks: playlist.items.total)
                }
            }
            lastError = nil
        } catch {
            lastError = Self.message(error)
        }
    }

    private static func device(_ device: SpotifyWebAPI.Device) -> Device {
        Device(id: device.id ?? "", name: device.name, type: device.type.rawValue, isActive: device.isActive)
    }

    private static func track(_ item: PlaylistItem?) -> Track? {
        switch item {
        case .track(let track):
            return Track(title: track.name, artists: (track.artists ?? []).map(\.name).joined(separator: ", "),
                         album: track.album?.name ?? "", artwork: track.album?.images?.first?.url)
        case .episode(let episode):
            return Track(title: episode.name ?? "", artists: episode.show?.name ?? "", album: "", artwork: episode.images?.first?.url)
        case nil:
            return nil
        }
    }

    private func perform(_ action: () -> AnyPublisher<Void, Error>) async {
        do { try await Self.wait(action()); lastError = nil } catch { lastError = Self.message(error) }
        try? await Task.sleep(for: .milliseconds(350))
        await refresh()
    }

    func togglePlay() async {
        let playing = playback?.isPlaying ?? false
        await perform { playing ? api.pausePlayback() : api.resumePlayback() }
    }
    func next() async { await perform { api.skipToNext() } }
    func previous() async { await perform { api.skipToPrevious() } }
    /// Déplace la lecture vers un appareil (Spotify Connect).
    func transfer(to device: Device) async { await perform { api.transferPlayback(to: device.id, play: true) } }
    func play(_ playlist: Playlist) async {
        let target = playback?.device?.id ?? devices.first(where: \.isActive)?.id
        await perform { api.play(PlaybackRequest(context: .contextURI(playlist.uri), offset: nil), deviceId: target) }
    }

    // MARK: Combine → async

    /// La première valeur d'un éditeur de la bibliothèque.
    private static func value<T>(_ publisher: AnyPublisher<T, Error>) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            var cancellable: AnyCancellable?
            var resumed = false
            cancellable = publisher.first().sink(receiveCompletion: { completion in
                if case .failure(let error) = completion, !resumed { resumed = true; continuation.resume(throwing: error) }
                if case .finished = completion, !resumed {
                    resumed = true
                    continuation.resume(throwing: URLError(.zeroByteResource))
                }
                _ = cancellable
            }, receiveValue: { value in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: value)
            })
        }
    }

    /// Un geste sans valeur (pause, suivant…) : attendre qu'il finisse.
    private static func wait(_ publisher: AnyPublisher<Void, Error>) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var cancellable: AnyCancellable?
            var resumed = false
            cancellable = publisher.sink(receiveCompletion: { completion in
                guard !resumed else { return }
                resumed = true
                if case .failure(let error) = completion { continuation.resume(throwing: error) } else { continuation.resume() }
                _ = cancellable
            }, receiveValue: { _ in })
        }
    }

    private static func message(_ error: Error) -> String {
        if let spotify = error as? SpotifyPlayerError {
            switch spotify.reason {
            case .premiumRequired: return String(localized: "Piloter Spotify demande un compte Premium.")
            case .noActiveDevice: return String(localized: "Aucun appareil Spotify actif : ouvre Spotify sur un appareil.")
            default: return spotify.message
            }
        }
        if let spotify = error as? SpotifyError { return "Spotify : \(spotify.message)" }
        if let auth = error as? SpotifyAuthorizationError, auth.accessWasDenied { return String(localized: "Connexion à Spotify refusée.") }
        if let flow = error as? OAuthFlowError { return flow.text }
        return error.localizedDescription
    }

    // MARK: Trousseau (cet appareil seulement)

    private static func keychainQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "StudyTrack", kSecAttrAccount as String: keychainAccount]
    }

    private static func keychainRead() -> Data? {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func keychainWrite(_ data: Data?) {
        SecItemDelete(keychainQuery() as CFDictionary)
        guard let data else { return }
        var query = keychainQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }
}

/// Le volet Spotify Connect dans la musique du mode étude.
struct SpotifyConnectView: View {
    @State private var spotify = SpotifyConnect.shared
    @State private var clientField = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !spotify.isConnected {
                    SpotifyLocalView()
                    connect
                } else { player; devices; playlists }
                if let error = spotify.lastError {
                    Text(error).font(.callout).foregroundStyle(Carnet.wrong)
                }
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(StudyPalette.ground)
        .task { await spotify.refresh(includingPlaylists: true) }
        .task(id: spotify.isConnected) {
            // Relu toutes les 4 s tant que le volet est ouvert (ce qui joue change sur les autres appareils).
            while spotify.isConnected && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                await spotify.refresh()
            }
        }
    }

    @State private var showsConnect = false

    /// Spotify Connect, en option : réservé par Spotify aux comptes Premium, avec une app déclarée.
    private var connect: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.snappy(duration: 0.2)) { showsConnect.toggle() } } label: {
                Label("Autoriser Spotify Connect (Premium)", systemImage: showsConnect ? "chevron.down" : "chevron.right")
                    .font(.callout.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(StudyPalette.ink)
            if showsConnect {
                Text("Pour piloter Spotify sur tous tes appareils (ton téléphone, une enceinte), voir tes playlists et changer d'appareil. Spotify le réserve aux comptes Premium, avec une app déclarée sur developer.spotify.com.")
                    .font(.callout).foregroundStyle(StudyPalette.inkSecondary)
                if spotify.clientID.isEmpty {
                    HStack {
                        TextField("Client ID de l'app Spotify", text: $clientField)
                            .textFieldStyle(.roundedBorder)
                        Button("Garder") { spotify.clientID = clientField }.disabled(clientField.isEmpty)
                    }
                } else {
                    Button { Task { await spotify.signIn() } } label: { Label("Autoriser Spotify", systemImage: "music.note") }
                        .buttonStyle(InkButtonStyle())
                }
            }
        }
        .padding(14)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(StudyPalette.rule))
    }

    private var player: some View {
        HStack(alignment: .center, spacing: 18) {
            AsyncImage(url: spotify.playback?.track?.artwork) { image in image.resizable().scaledToFill() } placeholder: {
                RoundedRectangle(cornerRadius: 12).fill(StudyPalette.raised).overlay(Image(systemName: "music.note").font(.title))
            }
            .frame(width: 120, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(spotify.playback?.track?.title ?? String(localized: "Rien ne joue"))
                    .font(Carnet.serif(24)).foregroundStyle(StudyPalette.ink).lineLimit(2)
                Text(spotify.playback?.track.map { [$0.artists, $0.album].filter { !$0.isEmpty }.joined(separator: " · ") }
                     ?? String(localized: "Lance une playlist ci-dessous, ou ouvre Spotify sur un appareil."))
                    .foregroundStyle(StudyPalette.inkSecondary)
                HStack(spacing: 18) {
                    Button { Task { await spotify.previous() } } label: { Image(systemName: "backward.fill") }
                    Button { Task { await spotify.togglePlay() } } label: {
                        Image(systemName: spotify.playback?.isPlaying == true ? "pause.fill" : "play.fill").font(.title2)
                    }
                    Button { Task { await spotify.next() } } label: { Image(systemName: "forward.fill") }
                }
                .buttonStyle(.plain)
                .foregroundStyle(StudyPalette.ink)
                .padding(.top, 4)
            }
        }
    }

    private var devices: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Écouter sur").font(Carnet.serif(16)).foregroundStyle(StudyPalette.ink)
            if spotify.devices.isEmpty {
                Text("Aucun appareil : ouvre Spotify sur ce Mac ou ton téléphone.").font(.callout).foregroundStyle(StudyPalette.inkTertiary)
            }
            FlowRow(spacing: 8) {
                ForEach(spotify.devices) { device in
                    Button { Task { await spotify.transfer(to: device) } } label: {
                        Label(device.name, systemImage: device.type == "Smartphone" ? "iphone" : device.type == "Computer" ? "laptopcomputer" : "hifispeaker")
                    }
                    .buttonStyle(PaperButtonStyle())
                    .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(device.isActive ? StudyPalette.ink : .clear))
                }
            }
        }
    }

    private var playlists: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tes playlists").font(Carnet.serif(16)).foregroundStyle(StudyPalette.ink)
                Spacer()
                Button("Se déconnecter") { spotify.signOut() }.buttonStyle(.plain).font(.caption).foregroundStyle(StudyPalette.inkTertiary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 8)], spacing: 8) {
                ForEach(spotify.playlists) { playlist in
                    Button { Task { await spotify.play(playlist) } } label: {
                        HStack(spacing: 10) {
                            AsyncImage(url: playlist.image) { image in image.resizable().scaledToFill() } placeholder: { StudyPalette.raised }
                                .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.name).lineLimit(1).foregroundStyle(StudyPalette.ink)
                                Text("\(playlist.tracks) titres").font(.caption).foregroundStyle(StudyPalette.inkTertiary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "play.fill").font(.caption).foregroundStyle(StudyPalette.inkSecondary)
                        }
                        .padding(8)
                        .background(StudyPalette.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Des éléments posés en ligne, qui passent à la ligne quand la place manque.
private struct FlowRow: SwiftUI.Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { y += line + spacing; x = 0; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
