import AVFoundation
import AVKit
import SwiftUI
import WebKit

// MARK: - Figures interactives

/// Une figure JSXGraph du polycopié, comme sur le site : on la fait bouger.
///
/// L'image fixe d'abord (publiée à côté du script) ; « Manipuler » charge la
/// vraie figure — le script du site, dans une petite page (JSXGraph et KaTeX
/// aux mêmes versions que le site). Rien ne tourne tant qu'on ne l'a pas
/// demandé, et la page disparaît avec le document.
///
/// Le site dessine chaque figure dans `<div id="BOX-<nom du script>">` : le
/// script appelle `JXG.JSXGraph.initBoard("BOX-jsx_complexes_zaucarre", …)`.
struct BotafogoLiveFigure: View {
    let script: URL?
    let image: URL?
    var width: Double?
    var height: Double?

    #if DEBUG
    /// `-figuresLive` : les figures déjà animées (captures).
    @State private var live = CommandLine.arguments.contains("-figuresLive")
    #else
    @State private var live = false
    #endif
    @Environment(\.botafogoTint) private var tint

    /// Le rapport largeur / hauteur de la figure sur le site.
    private var aspect: CGFloat {
        guard let width, let height, width > 0, height > 0 else { return 2 }
        return CGFloat(width / height)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                if live, let script {
                    JSXGraphView(script: script)
                        .aspectRatio(aspect, contentMode: .fit)
                } else {
                    AsyncImage(url: image) { phase in
                        if case .success(let picture) = phase {
                            picture.resizable().scaledToFit()
                        } else {
                            Color.white.aspectRatio(aspect, contentMode: .fit)
                        }
                    }
                    .padding(10)
                }
                if script != nil {
                    Button { withAnimation(.snappy) { live.toggle() } } label: {
                        Label(live ? "Image" : "Manipuler", systemImage: live ? "photo" : "hand.draw")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .foregroundStyle(.white)
                            .background(tint.opacity(0.92), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .help(live ? "Revenir à l'image" : "Faire bouger la figure, comme sur le site")
                }
            }
            .frame(maxWidth: min(720, CGFloat(width ?? 520) * 1.6))
            .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Carnet.rule))
        }
        .frame(maxWidth: .infinity)
    }
}

/// La page d'une figure : JSXGraph, KaTeX pour les étiquettes, puis le script.
enum JSXGraphPage {
    static let jsxgraph = "https://cdn.jsdelivr.net/npm/jsxgraph@1.13.3/distrib"
    static let katex = "https://cdn.jsdelivr.net/npm/katex@0.16.11/dist"

    static func html(script: URL) -> String {
        let name = script.deletingPathExtension().lastPathComponent
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <link rel="stylesheet" href="\(jsxgraph)/jsxgraph.css">
        <link rel="stylesheet" href="\(katex)/katex.min.css">
        <script src="\(katex)/katex.min.js"></script>
        <script src="\(jsxgraph)/jsxgraphcore.js"></script>
        <style>html,body{margin:0;height:100%;background:#fff;overflow:hidden}
        .jxgbox{border:none!important;width:100%!important;height:100%!important;border-radius:0}.JXG_navigation{display:none!important}</style>
        </head><body>
        <div id="BOX-\(name)" class="jxgbox"></div>
        <script>JXG.Options.text.useKatex = true;</script>
        <script src="\(script.absoluteString)"></script>
        </body></html>
        """
    }
}

#if os(macOS)
private struct JSXGraphView: NSViewRepresentable {
    let script: URL
    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.setValue(false, forKey: "drawsBackground")
        view.loadHTMLString(JSXGraphPage.html(script: script), baseURL: script.deletingLastPathComponent())
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#else
private struct JSXGraphView: UIViewRepresentable {
    let script: URL
    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.isOpaque = false
        view.scrollView.isScrollEnabled = false
        view.loadHTMLString(JSXGraphPage.html(script: script), baseURL: script.deletingLastPathComponent())
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif

// MARK: - Animations

/// Une animation du polycopié : sa première image à sa place dans le texte ;
/// un clic la joue sur place, en boucle et sans le son, un autre l'arrête.
/// Rien ne se télécharge au-delà de la première image tant qu'on ne la lance pas.
struct BotafogoAnimation: View {
    let url: URL?
    let title: String

    @State private var poster: CGImage?
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    @State private var playing = false
    @State private var aspect: CGFloat = 16 / 9
    @Environment(\.botafogoTint) private var tint

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                ZStack {
                    Color.black
                    if let player {
                        PlayerLayerView(player: player)
                    } else if let poster {
                        Image(decorative: poster, scale: 1).resizable().scaledToFit()
                    }
                    if !playing {
                        Image(systemName: "play.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.black.opacity(0.85))
                            .frame(width: 46, height: 46)
                            .background(.white.opacity(0.92), in: Circle())
                            .shadow(radius: 6, y: 2)
                    }
                }
                .aspectRatio(aspect, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(url == nil)
            .help(playing ? "Arrêter" : "Lancer l'animation")
            Label(title, systemImage: "play.square.stack")
                .font(.caption)
                .foregroundStyle(Carnet.inkSecondary)
        }
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
        .task(id: url) { await loadPoster() }
        .onDisappear { player?.pause(); playing = false }
    }

    private func toggle() {
        guard let url else { return }
        if player == nil {
            let item = AVPlayerItem(url: url)
            let queue = AVQueuePlayer()
            queue.isMuted = true
            looper = AVPlayerLooper(player: queue, templateItem: item)
            player = queue
        }
        playing.toggle()
        if playing { player?.play() } else { player?.pause() }
    }

    private func loadPoster() async {
        guard poster == nil, let url else { return }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1240, height: 1240)
        if let (image, _) = try? await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)) {
            poster = image
            if image.height > 0 { aspect = CGFloat(image.width) / CGFloat(image.height) }
        }
    }
}

#if os(macOS)
private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        view.layer = layer
        view.wantsLayer = true
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}
#else
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
    }
    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        (view.layer as? AVPlayerLayer)?.player = player
        (view.layer as? AVPlayerLayer)?.videoGravity = .resizeAspect
        return view
    }
    func updateUIView(_ view: LayerView, context: Context) {}
}
#endif
