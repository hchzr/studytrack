import SwiftUI
import WebKit
import AVKit

/// Reconnaît un lien de vidéo de cours.
enum VideoLinks {
    static func isVideo(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let ext = url.pathExtension.lowercased()
        if ["mp4", "m4v", "mov", "m3u8", "webm"].contains(ext) { return true }
        if host.hasSuffix("mediaspace.epfl.ch") { return url.path.contains("/media/") || url.path.contains("/playlist/") || url.path.contains("/embed/") }
        if host == ExpliqueImport.host { return url.path.contains("/v/") }
        return ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be", "vimeo.com", "tube.switch.ch"].contains(host)
            || host.hasSuffix("kaltura.com") || host.hasSuffix("cast.switch.ch")
    }
}

/// Une vidéo de cours, lue **dans l'app**.
///
/// La page de la vidéo (MediaSpace, Explique, YouTube…) est ouverte avec la
/// session des sites de cours ; dès qu'elle expose un flux lisible par iOS (le
/// HLS de Kaltura sur MediaSpace, un fichier MP4), on passe au lecteur natif —
/// vitesse de lecture, image dans l'image, plein écran. Sinon (Explique, dont le
/// lecteur assemble le flux lui-même, YouTube), la page reste : elle joue la
/// vidéo dans l'app, avec ses propres outils (l'assistant d'Explique, par exemple).
struct VideoPlayerView: View {
    let link: BrowsedLink

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var showsPage = false

    var body: some View {
        NavigationStack {
            Group {
                if let player, !showsPage {
                    NativePlayer(player: player)
                        .ignoresSafeArea(edges: .bottom)
                        .background(Color.black)
                } else {
                    VideoPageView(url: link.url) { stream, cookies in
                        guard player == nil, !showsPage else { return }
                        let asset = AVURLAsset(url: stream, options: ["AVURLAssetHTTPCookiesKey": cookies])
                        let item = AVPlayerItem(asset: asset)
                        let next = AVPlayer(playerItem: item)
                        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                        withAnimation(Motion.snappy) { player = next }
                        next.play()
                    }
                    .ignoresSafeArea(edges: .bottom)
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(link.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") {
                        player?.pause()
                        dismiss()
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if player != nil {
                        // Retour à la page (chapitres, assistant, transcription).
                        Button {
                            player?.pause()
                            showsPage.toggle()
                        } label: {
                            Image(systemName: showsPage ? "play.rectangle" : "safari")
                        }
                        .accessibilityLabel(showsPage ? "Lecteur" : "Page de la vidéo")
                    }
                    Link(destination: link.url) { Image(systemName: "arrow.up.right.square") }
                        .accessibilityLabel("Ouvrir dans Safari")
                }
            }
        }
        .onDisappear { player?.pause() }
    }
}

/// Le lecteur d'iOS.
private struct NativePlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.speeds = [AVPlaybackSpeed(rate: 1, localizedName: "1×"),
                             AVPlaybackSpeed(rate: 1.25, localizedName: "1,25×"),
                             AVPlaybackSpeed(rate: 1.5, localizedName: "1,5×"),
                             AVPlaybackSpeed(rate: 1.75, localizedName: "1,75×"),
                             AVPlaybackSpeed(rate: 2, localizedName: "2×")]
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}

/// La page de la vidéo, lecture en ligne permise ; signale un flux lisible.
private struct VideoPageView: UIViewRepresentable {
    let url: URL
    var onStream: (URL, [HTTPCookie]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onStream: onStream) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.backgroundColor = .black
        view.navigationDelegate = context.coordinator
        context.coordinator.webView = view
        view.load(URLRequest(url: SiteLinks.normalize(url)))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.polling?.cancel()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let onStream: (URL, [HTTPCookie]) -> Void
        weak var webView: WKWebView?
        var polling: Task<Void, Never>?

        init(onStream: @escaping (URL, [HTTPCookie]) -> Void) { self.onStream = onStream }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in self.poll() }
        }

        /// Cherche, quelques secondes, un `<video>` dont la source est un vrai
        /// flux (pas un `blob:` assemblé par la page). Le lecteur Kaltura en
        /// expose un sur iOS : le HLS natif.
        private func poll() {
            polling?.cancel()
            polling = Task { @MainActor [weak self] in
                for _ in 0..<20 {
                    guard let self, let webView = self.webView, !Task.isCancelled else { return }
                    let script = """
                    (function () {
                      const candidates = [];
                      document.querySelectorAll('video').forEach(v => {
                        candidates.push(v.currentSrc || v.src || '');
                        v.querySelectorAll('source').forEach(s => candidates.push(s.src || ''));
                      });
                      document.querySelectorAll('iframe').forEach(f => {
                        try { f.contentDocument.querySelectorAll('video').forEach(v => candidates.push(v.currentSrc || v.src || '')); } catch (e) {}
                      });
                      return candidates.find(s => /^https?:/.test(s)) || '';
                    })();
                    """
                    if let src = try? await webView.evaluateJavaScript(script) as? String,
                       let stream = URL(string: src), stream.scheme?.hasPrefix("http") == true {
                        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
                        self.onStream(stream, cookies)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(700))
                }
            }
        }
    }
}
