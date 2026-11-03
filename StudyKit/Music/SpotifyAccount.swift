import SwiftUI
import WebKit

/// Ton compte Spotify, piloté comme Music : ce qui joue (sur n'importe quel appareil du compte),
/// lecture, pause, précédent, suivant, position, aléatoire, répétition, volume, l'appareil qui
/// joue, à suivre, et tes playlists. Gratuit ou Premium, sans compte développeur.
///
/// **Comment** (d'après SpotAPI, Aran404/SpotAPI) : la vraie page de connexion de Spotify dans une
/// fenêtre de l'app (StudyTrack ne voit jamais ton mot de passe : seule la session reste, dans le
/// stockage web de l'app), puis le protocole du lecteur web — `SpotifyWire`. Le « dealer » de
/// Spotify pousse chaque changement : rien n'est redemandé en boucle, et tout s'arrête quand le
/// volet se ferme. **Non officiel** : si Spotify change ce protocole, l'app le dit, et le pilotage
/// local (l'app Spotify du Mac, les liens) reste là.
@MainActor @Observable
final class SpotifyAccount {
    static let shared = SpotifyAccount()

    enum State: Equatable { case unknown, checking, signedOut, ready, failed(String) }

    private(set) var state: State = .unknown
    private(set) var now = SpotifyWire.Now()
    private(set) var playlists: [SpotifyWire.Playlist] = []
    var lastError: String?

    private var token: SpotifyWire.WebToken?
    private var clientToken: String?
    private var clientVersion = SpotifyWire.fallbackClientVersion
    private var cookies = ""
    private let deviceID = SpotifyWire.randomHex(40)
    private var socket: URLSessionWebSocketTask?
    private var listening: Task<Void, Never>?
    private var watchers = 0
    private var details: [String: (artist: String, album: String, artwork: URL?)] = [:]

    static var store: WKWebsiteDataStore { .default() }
    private let session = URLSession(configuration: .ephemeral)

    var isReady: Bool { state == .ready }

    // MARK: Session

    /// Vérifie la session Spotify et prépare les jetons (sans rien écouter encore).
    func refresh() async {
        if state != .ready { state = .checking }
        let all = await Self.store.httpCookieStore.allCookies().filter { $0.domain.hasSuffix("spotify.com") }
        guard SpotifyWire.isSignedIn(cookieNames: all.map(\.name)) else { state = .signedOut; return }
        cookies = all.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        do {
            try await authenticate()
            state = .ready
        } catch let failure as Failure where failure == .signedOut {
            state = .signedOut
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func signOut() async {
        stopListening()
        let records = await Self.store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await Self.store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records.filter { $0.displayName.contains("spotify") })
        token = nil; clientToken = nil; cookies = ""
        now = .init(); playlists = []
        state = .signedOut
    }

    enum Failure: LocalizedError, Equatable {
        case signedOut, changed(String), noDevice, refused(Int)
        var errorDescription: String? {
            switch self {
            case .signedOut: return String(localized: "La session Spotify a expiré : reconnecte-toi.")
            case .changed(let step): return String(localized: "Spotify a répondu autrement que prévu (\(step)) : son lecteur web a peut-être changé. Le pilotage local reste possible.")
            case .noDevice: return String(localized: "Aucun appareil Spotify n'est ouvert. Ouvre Spotify sur ton ordinateur ou ton téléphone.")
            case .refused(let code): return String(localized: "Spotify a refusé la commande (code \(code)).")
            }
        }
    }

    private func authenticate() async throws {
        if let token, token.expires.timeIntervalSinceNow > 60, clientToken != nil { return }
        // 1. La page du lecteur : sa version (pour le jeton client).
        var page = URLRequest(url: SpotifyWire.site, timeoutInterval: 20)
        page.setValue(SpotifyWire.agent, forHTTPHeaderField: "User-Agent")
        page.setValue(cookies, forHTTPHeaderField: "Cookie")
        if let (data, _) = try? await session.data(for: page), let html = String(data: data, encoding: .utf8),
           let version = SpotifyWire.clientVersion(inPage: html) {
            clientVersion = version
        }
        // 2. Le jeton du lecteur web (TOTP).
        let secret = await Self.secret()
        var request = URLRequest(url: SpotifyWire.tokenURL(totp: SpotifyWire.totp(secret: secret.bytes, at: Date()), version: secret.version), timeoutInterval: 20)
        request.setValue(SpotifyWire.agent, forHTTPHeaderField: "User-Agent")
        request.setValue(cookies, forHTTPHeaderField: "Cookie")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let web = SpotifyWire.webToken(from: data) else {
            throw Failure.changed("jeton")
        }
        guard !web.anonymous else { throw Failure.signedOut }
        token = web
        // 3. Le jeton client.
        var client = URLRequest(url: SpotifyWire.clientTokenURL, timeoutInterval: 20)
        client.httpMethod = "POST"
        client.setValue("application/json", forHTTPHeaderField: "Content-Type")
        client.setValue("application/json", forHTTPHeaderField: "Accept")
        client.setValue(SpotifyWire.agent, forHTTPHeaderField: "User-Agent")
        client.httpBody = try JSONSerialization.data(withJSONObject: SpotifyWire.clientTokenBody(clientVersion: clientVersion, clientID: web.clientID, deviceID: deviceID))
        let (granted, _) = try await session.data(for: client)
        clientToken = SpotifyWire.clientToken(from: granted)
        if clientToken == nil { throw Failure.changed("jeton client") }
    }

    /// La clé du TOTP : celle du dépôt communautaire (quart d'heure de cache), sinon celle embarquée.
    private static var cachedSecret: (value: (version: Int, bytes: [UInt8]), until: Date)?
    private static func secret() async -> (version: Int, bytes: [UInt8]) {
        if let cached = cachedSecret, cached.until > Date() { return cached.value }
        var value = SpotifyWire.fallbackSecret
        if let (data, _) = try? await URLSession.shared.data(from: SpotifyWire.secretsURL), let latest = SpotifyWire.latestSecret(from: data) {
            value = latest
        }
        cachedSecret = (value, Date().addingTimeInterval(15 * 60))
        return value
    }

    private func authorized(_ url: URL, method: String = "GET", body: [String: Any]? = nil, connection: String? = nil) async throws -> (Data, Int) {
        try await authenticate()
        guard let token, let clientToken else { throw Failure.signedOut }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(clientToken, forHTTPHeaderField: "Client-Token")
        request.setValue(clientVersion, forHTTPHeaderField: "Spotify-App-Version")
        request.setValue(SpotifyWire.agent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://open.spotify.com", forHTTPHeaderField: "Origin")
        if let connection { request.setValue(connection, forHTTPHeaderField: "x-spotify-connection-id") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { self.token = nil }
        return (data, status)
    }

    // MARK: Écouter (seulement volet ouvert)

    /// Le volet s'ouvre : on écoute le dealer. Il se ferme : on coupe (rien ne tourne en fond).
    func startWatching() {
        watchers += 1
        guard watchers == 1 else { return }
        listening = Task { [weak self] in await self?.listen() }
    }

    func stopWatching() {
        watchers = max(0, watchers - 1)
        if watchers == 0 { stopListening() }
    }

    private func stopListening() {
        listening?.cancel(); listening = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
    }

    private func listen() async {
        var attempt = 0
        while !Task.isCancelled {
            if state != .ready { await refresh() }
            guard state == .ready, let token else { return }
            var request = URLRequest(url: SpotifyWire.dealerURL(token: token.accessToken))
            request.setValue("https://open.spotify.com", forHTTPHeaderField: "Origin")
            request.setValue(SpotifyWire.agent, forHTTPHeaderField: "User-Agent")
            let socket = session.webSocketTask(with: request)
            self.socket = socket
            socket.resume()
            let ping = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    try? await socket.send(.string(#"{"type":"ping"}"#))
                }
            }
            defer { ping.cancel() }
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    let data: Data
                    switch message {
                    case .data(let d): data = d
                    case .string(let s): data = Data(s.utf8)
                    @unknown default: continue
                    }
                    if let connection = SpotifyWire.connectionID(fromDealer: data) {
                        try await observe(connection: connection)
                        attempt = 0
                        Task { await loadPlaylists() }
                    }
                    for payload in SpotifyWire.clusterPayloads(fromDealer: data) {
                        if let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] { apply(object) }
                    }
                }
            } catch {
                if Task.isCancelled { return }
            }
            // Coupé (réseau, jeton expiré) : on revient, de plus en plus lentement.
            attempt += 1
            self.token = nil
            try? await Task.sleep(for: .seconds(min(60, 2 << min(attempt, 5))))
        }
    }

    private func observe(connection: String) async throws {
        let (data, status) = try await authorized(SpotifyWire.observerURL(deviceID: deviceID), method: "PUT", body: SpotifyWire.observerBody, connection: connection)
        guard (200..<300).contains(status), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.changed("connect-state \(status)")
        }
        apply(object)
    }

    private func apply(_ cluster: [String: Any]) {
        var next = SpotifyWire.now(fromCluster: cluster)
        // Un état partiel (sans appareils) garde ceux qu'on connaît.
        if next.devices.isEmpty { next.devices = now.devices }
        if let id = next.track?.id, let known = details[id] { fill(&next, known) }
        now = next
        if let track = next.track, track.artist.isEmpty || track.artwork == nil, let id = track.id, details[id] == nil {
            Task { await loadDetails(id: id) }
        }
    }

    private func fill(_ now: inout SpotifyWire.Now, _ known: (artist: String, album: String, artwork: URL?)) {
        if now.track?.artist.isEmpty == true { now.track?.artist = known.artist }
        if now.track?.album.isEmpty == true { now.track?.album = known.album }
        if now.track?.artwork == nil { now.track?.artwork = known.artwork }
    }

    private func loadDetails(id: String) async {
        guard let (data, status) = try? await authorized(SpotifyWire.trackURL(id: id)), status == 200,
              let found = SpotifyWire.trackDetails(from: data) else { return }
        details[id] = found
        if now.track?.id == id { fill(&now, found) }
    }

    func loadPlaylists() async {
        guard let (data, status) = try? await authorized(SpotifyWire.playlistsURL), status == 200 else { return }
        playlists = SpotifyWire.playlists(from: data)
    }

    // MARK: Gestes

    private var target: String? {
        now.activeDevice ?? now.devices.first { $0.canPlay }?.id
    }

    private func send(_ command: SpotifyWire.Command) {
        Task {
            do {
                guard let target else { throw Failure.noDevice }
                var (_, status) = try await authorized(SpotifyWire.commandURL(from: deviceID, to: target), method: "POST", body: SpotifyWire.commandBody(command))
                // Comme SpotAPI : depuis l'appareil d'origine si l'observateur est refusé.
                if !(200..<300).contains(status) {
                    (_, status) = try await authorized(SpotifyWire.commandURL(from: now.originDevice ?? "local", to: target), method: "POST", body: SpotifyWire.commandBody(command))
                }
                guard (200..<300).contains(status) else { throw Failure.refused(status) }
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func togglePlayPause() {
        let playing = now.isPlaying
        now.isPlaying.toggle()
        if !playing { now.measuredAt = Date() } else { now.position = now.elapsed(at: Date()) }
        send(playing ? .pause : .resume)
    }
    func next() { send(.next) }
    func previous() { send(.previous) }
    func seek(to seconds: TimeInterval) {
        now.position = seconds; now.measuredAt = Date()
        send(.seek(milliseconds: Int(seconds * 1000)))
    }
    func setShuffle(_ on: Bool) { now.shuffle = on; send(.shuffle(on)) }
    /// Désactivé → toute la liste → ce morceau → désactivé.
    func cycleRepeat() {
        let (context, track): (Bool, Bool) = now.repeatTrack ? (false, false) : (now.repeatContext ? (true, true) : (true, false))
        now.repeatContext = context; now.repeatTrack = track
        send(.repeatMode(context: context, track: track))
    }
    func play(uri: String) { send(.play(context: uri)) }

    func setVolume(_ fraction: Double) {
        guard let target else { return }
        if let index = now.devices.firstIndex(where: { $0.id == target }) { now.devices[index].volume = fraction }
        Task { _ = try? await authorized(SpotifyWire.volumeURL(from: deviceID, to: target), method: "PUT", body: SpotifyWire.volumeBody(fraction)) }
    }

    /// Fait passer la lecture sur un autre appareil (même morceau, même seconde).
    func move(to device: String) {
        guard let from = now.activeDevice ?? now.originDevice, from != device else { return }
        Task {
            do {
                let (_, status) = try await authorized(SpotifyWire.transferURL(from: from, to: device), method: "POST", body: SpotifyWire.transferBody(resume: now.isPlaying))
                guard (200..<300).contains(status) else { throw Failure.refused(status) }
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }
}

// MARK: - Connexion

/// La vraie page de connexion de Spotify ; se ferme seule une fois la session ouverte.
struct SpotifySignInSheet: View {
    var done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Connexion à Spotify").font(.headline).foregroundStyle(Carnet.ink)
                Spacer()
                Button("Fermer") { done() }.buttonStyle(.paper)
            }
            .padding(12)
            Divider()
            SpotifyLoginWebView(finished: done)
        }
        .background(Carnet.ground)
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 640, idealHeight: 720)
        #endif
    }
}

private final class SpotifyLoginCoordinator: NSObject, WKNavigationDelegate {
    let finished: () -> Void
    init(finished: @escaping () -> Void) { self.finished = finished }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView.url?.host == "open.spotify.com" else { return }
        Task { @MainActor in
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            if SpotifyWire.isSignedIn(cookieNames: cookies.filter { $0.domain.hasSuffix("spotify.com") }.map(\.name)) { self.finished() }
        }
    }
}

#if os(macOS)
private struct SpotifyLoginWebView: NSViewRepresentable {
    var finished: () -> Void
    func makeCoordinator() -> SpotifyLoginCoordinator { SpotifyLoginCoordinator(finished: finished) }
    func makeNSView(context: Context) -> WKWebView { makeSpotifyLogin(context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#else
private struct SpotifyLoginWebView: UIViewRepresentable {
    var finished: () -> Void
    func makeCoordinator() -> SpotifyLoginCoordinator { SpotifyLoginCoordinator(finished: finished) }
    func makeUIView(context: Context) -> WKWebView { makeSpotifyLogin(context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif

@MainActor private func makeSpotifyLogin(_ coordinator: SpotifyLoginCoordinator) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = SpotifyAccount.store
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = coordinator
    view.customUserAgent = SpotifyWire.agent
    view.load(URLRequest(url: SpotifyWire.login))
    return view
}
