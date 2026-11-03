import AuthenticationServices
import Foundation
import Observation
import Security
import SwiftUI

/// Spotify Connect (API web de Spotify), sur l'iPhone et le Mac : ce qui joue sur n'importe
/// lequel de tes appareils Spotify (ce Mac, le téléphone, une enceinte), le piloter, le
/// déplacer, lancer une playlist. Connexion PKCE dans la feuille du système
/// (`studytrack://spotify-callback`, aucun secret dans l'app) ; le jeton de rafraîchissement
/// est au trousseau, sur cet appareil seulement. Le pilotage demande Spotify Premium.
/// Le même service que Windows (`windows/src/services/spotify.ts`).
@MainActor
@Observable
final class SpotifyConnect {
    static let shared = SpotifyConnect()

    /// L'app Spotify de StudyTrack (developer.spotify.com) ; un autre identifiant peut être collé
    /// dans le volet Musique. Public : avec PKCE, il n'y a pas de secret.
    static let builtInClientID = ""
    static let redirect = "studytrack://spotify-callback"
    private static let scopes = "user-read-playback-state user-modify-playback-state user-read-currently-playing playlist-read-private playlist-read-collaborative user-library-read"
    private static let refreshAccount = "spotify.refresh"

    struct Device: Identifiable, Equatable { var id: String; var name: String; var type: String; var isActive: Bool }
    struct Track: Equatable { var title: String; var artists: String; var album: String; var artwork: URL? }
    struct Playback: Equatable { var isPlaying: Bool; var device: Device?; var track: Track? }
    struct Playlist: Identifiable, Equatable { var id: String; var uri: String; var name: String; var image: URL?; var tracks: Int }

    private(set) var isConnected = false
    private(set) var playback: Playback?
    private(set) var devices: [Device] = []
    private(set) var playlists: [Playlist] = []
    var lastError: String?

    private var accessToken: String?
    private var accessExpiry = Date.distantPast

    var clientID: String {
        get { UserDefaults.standard.string(forKey: "spotify.clientID").flatMap { $0.isEmpty ? nil : $0 } ?? Self.builtInClientID }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "spotify.clientID") }
    }

    init() { isConnected = Self.keychainRead() != nil }

    // MARK: Connexion

    func signIn() async {
        lastError = nil
        guard !clientID.isEmpty else { lastError = String(localized: "Il manque l'identifiant de l'app Spotify."); return }
        let verifier = OAuthPKCE.makeVerifier()
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirect), .init(name: "scope", value: Self.scopes),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "code_challenge", value: OAuthPKCE.challenge(for: verifier)),
        ]
        do {
            let callback = try await SupabaseOAuthWebSession.shared.authenticate(url: components.url!)
            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let error = items.first(where: { $0.name == "error" })?.value {
                lastError = error == "access_denied" ? String(localized: "Connexion à Spotify refusée.") : error
                return
            }
            guard let code = items.first(where: { $0.name == "code" })?.value else { lastError = String(localized: "Spotify n'a pas rendu de code."); return }
            try await token(["grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirect,
                             "client_id": clientID, "code_verifier": verifier])
            isConnected = true
            await refresh(includingPlaylists: true)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func signOut() {
        Self.keychainWrite(nil)
        accessToken = nil
        isConnected = false
        playback = nil
        devices = []
        playlists = []
    }

    private struct Failure: LocalizedError { let errorDescription: String? }

    private func token(_ form: [String: String]) async throws {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = form.map { .init(name: $0.key, value: $0.value) }
        request.httpBody = body.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200, let access = json["access_token"] as? String else {
            throw Failure(errorDescription: (json["error_description"] as? String) ?? String(localized: "Spotify a refusé la connexion."))
        }
        accessToken = access
        accessExpiry = Date().addingTimeInterval(Double(json["expires_in"] as? Int ?? 3600) - 60)
        if let refresh = json["refresh_token"] as? String { Self.keychainWrite(refresh) }
    }

    private func bearer() async throws -> String {
        if let accessToken, accessExpiry > Date() { return accessToken }
        guard let refresh = Self.keychainRead() else { throw Failure(errorDescription: String(localized: "Connecte-toi à Spotify.")) }
        do {
            try await token(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID])
        } catch {
            signOut()
            throw error
        }
        return accessToken ?? ""
    }

    private func api(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any]? {
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1" + path)!)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("Bearer \(try await bearer())", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 204 || status == 202 || data.isEmpty { return nil }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (200..<300).contains(status) else {
            let reason = ((json?["error"] as? [String: Any])?["reason"] as? String) ?? ((json?["error"] as? [String: Any])?["message"] as? String) ?? ""
            if reason.contains("PREMIUM_REQUIRED") { throw Failure(errorDescription: String(localized: "Piloter Spotify demande un compte Premium.")) }
            if reason.contains("NO_ACTIVE_DEVICE") || status == 404 {
                throw Failure(errorDescription: String(localized: "Aucun appareil Spotify actif : ouvre Spotify sur un appareil."))
            }
            throw Failure(errorDescription: "Spotify : \(reason.isEmpty ? String(status) : reason)")
        }
        return json
    }

    // MARK: Lire et piloter

    private static func device(_ raw: [String: Any]) -> Device {
        Device(id: raw["id"] as? String ?? "", name: raw["name"] as? String ?? "", type: raw["type"] as? String ?? "",
               isActive: raw["is_active"] as? Bool ?? false)
    }

    /// Relit ce qui joue et les appareils (à l'ouverture du volet, après un geste).
    func refresh(includingPlaylists: Bool = false) async {
        guard isConnected else { return }
        do {
            if let raw = try await api("/me/player?additional_types=track,episode") {
                let item = raw["item"] as? [String: Any]
                let album = item?["album"] as? [String: Any]
                let images = (album?["images"] as? [[String: Any]]) ?? (item?["images"] as? [[String: Any]]) ?? []
                let artists = ((item?["artists"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }.joined(separator: ", ")
                playback = Playback(isPlaying: raw["is_playing"] as? Bool ?? false,
                                    device: (raw["device"] as? [String: Any]).map(Self.device),
                                    track: item.map { Track(title: $0["name"] as? String ?? "", artists: artists, album: album?["name"] as? String ?? "",
                                                            artwork: (images.first?["url"] as? String).flatMap(URL.init(string:))) })
            } else {
                playback = nil
            }
            devices = ((try await api("/me/player/devices"))?["devices"] as? [[String: Any]] ?? []).map(Self.device)
            if includingPlaylists || playlists.isEmpty {
                let items = (try await api("/me/playlists?limit=50"))?["items"] as? [[String: Any]] ?? []
                playlists = items.map { p in
                    Playlist(id: p["id"] as? String ?? "", uri: p["uri"] as? String ?? "", name: p["name"] as? String ?? "",
                             image: ((p["images"] as? [[String: Any]])?.first?["url"] as? String).flatMap(URL.init(string:)),
                             tracks: (p["tracks"] as? [String: Any])?["total"] as? Int ?? 0)
                }
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func perform(_ action: () async throws -> Void) async {
        do { try await action(); lastError = nil } catch { lastError = error.localizedDescription }
        try? await Task.sleep(for: .milliseconds(350))
        await refresh()
    }

    func togglePlay() async {
        let playing = playback?.isPlaying ?? false
        await perform { _ = try await api(playing ? "/me/player/pause" : "/me/player/play", method: "PUT") }
    }
    func next() async { await perform { _ = try await api("/me/player/next", method: "POST") } }
    func previous() async { await perform { _ = try await api("/me/player/previous", method: "POST") } }
    /// Déplace la lecture vers un appareil (Spotify Connect).
    func transfer(to device: Device) async { await perform { _ = try await api("/me/player", method: "PUT", body: ["device_ids": [device.id], "play": true]) } }
    func play(_ playlist: Playlist) async {
        let target = playback?.device?.id ?? devices.first(where: \.isActive)?.id
        await perform {
            _ = try await api("/me/player/play" + (target.map { "?device_id=\($0)" } ?? ""), method: "PUT", body: ["context_uri": playlist.uri])
        }
    }

    // MARK: Trousseau (cet appareil seulement)

    private static func keychainQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "StudyTrack", kSecAttrAccount as String: refreshAccount]
    }

    private static func keychainRead() -> String? {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func keychainWrite(_ value: String?) {
        SecItemDelete(keychainQuery() as CFDictionary)
        guard let value else { return }
        var query = keychainQuery()
        query[kSecValueData as String] = Data(value.utf8)
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
                if !spotify.isConnected { connect } else { player; devices; playlists }
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

    private var connect: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Spotify Connect").font(Carnet.serif(22)).foregroundStyle(StudyPalette.ink)
            Text("Pilote Spotify sur tous tes appareils (ce Mac, ton téléphone, une enceinte) sans quitter le mode étude : ce qui joue, morceau suivant, changer d'appareil, lancer une playlist. Le pilotage demande Spotify Premium.")
                .font(.callout).foregroundStyle(StudyPalette.inkSecondary)
            if spotify.clientID.isEmpty {
                HStack {
                    TextField("Identifiant de l'app Spotify (developer.spotify.com)", text: $clientField)
                        .textFieldStyle(.roundedBorder)
                    Button("Garder") { spotify.clientID = clientField }.disabled(clientField.isEmpty)
                }
            } else {
                Button { Task { await spotify.signIn() } } label: { Label("Se connecter à Spotify", systemImage: "music.note") }
                    .buttonStyle(InkButtonStyle())
            }
        }
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
