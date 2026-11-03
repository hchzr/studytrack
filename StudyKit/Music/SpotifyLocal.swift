import Foundation
import Observation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Spotify **sans compte développeur ni Premium** : l'app Spotify de l'appareil.
///   • Mac : l'app Spotify se pilote par AppleScript (son dictionnaire officiel) — le morceau en
///     cours, lecture, pause, précédent, suivant, et lancer une playlist depuis son lien. Marche
///     avec un compte gratuit. macOS demande une fois l'autorisation (Confidentialité › Automatisation).
///   • iPhone : seulement ouvrir une playlist dans l'app Spotify (iOS ne laisse pas piloter une autre app).
@MainActor
@Observable
final class SpotifyLocal {
    static let shared = SpotifyLocal()

    struct Track: Equatable { var title: String; var artist: String; var artwork: URL? }

    private(set) var isPlaying = false
    private(set) var track: Track?
    private(set) var isRunning = false
    var lastError: String?

    /// Les liens lancés, gardés pour les relancer d'un geste.
    private(set) var saved: [String] = UserDefaults.standard.stringArray(forKey: "spotify.savedLinks") ?? []

    static var bundleID: String { "com.spotify.client" }

    var isInstalled: Bool {
        #if os(macOS)
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) != nil
        #else
        UIApplication.shared.canOpenURL(URL(string: "spotify:")!)
        #endif
    }

    /// `https://open.spotify.com/playlist/…` ou `spotify:playlist:…` → l'URI de l'app.
    nonisolated static func uri(from text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.range(of: #"^spotify:(playlist|album|artist|track|show|episode):[A-Za-z0-9]+$"#, options: .regularExpression) != nil {
            return value
        }
        guard let match = value.range(of: #"open\.spotify\.com/(intl-[a-z-]+/)?(playlist|album|artist|track|show|episode)/[A-Za-z0-9]+"#,
                                      options: .regularExpression) else { return nil }
        let parts = value[match].split(separator: "/").filter { !$0.hasPrefix("intl-") }
        guard parts.count >= 3 else { return nil }
        return "spotify:\(parts[1]):\(parts[2])"
    }

    /// Lance une playlist (ou un album) : dans l'app Spotify du Mac directement, ailleurs en l'ouvrant.
    func play(link: String) {
        guard let uri = Self.uri(from: link) else { lastError = String(localized: "Colle un lien Spotify (playlist, album…)."); return }
        lastError = nil
        saved = [uri] + saved.filter { $0 != uri }
        saved = Array(saved.prefix(8))
        UserDefaults.standard.set(saved, forKey: "spotify.savedLinks")
        #if os(macOS)
        if run("play track \"\(uri)\"") == nil, let url = URL(string: uri) { NSWorkspace.shared.open(url) }
        refresh()
        #else
        if let url = URL(string: uri) { UIApplication.shared.open(url) }
        #endif
    }

    #if os(macOS)
    /// Relit le morceau en cours (sans lancer Spotify s'il est fermé).
    func refresh() {
        isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
        guard isRunning else { track = nil; isPlaying = false; return }
        guard let raw = run("""
            set s to (player state as string)
            if s is "stopped" then return s
            return s & "\u{1F}" & (name of current track) & "\u{1F}" & (artist of current track) & "\u{1F}" & (artwork url of current track)
            """) else { return }
        let parts = raw.components(separatedBy: "\u{1F}")
        isPlaying = parts.first == "playing"
        track = parts.count >= 4 ? Track(title: parts[1], artist: parts[2], artwork: URL(string: parts[3])) : nil
    }

    func togglePlay() { _ = run("playpause"); refresh() }
    func next() { _ = run("next track"); refresh() }
    func previous() { _ = run("previous track"); refresh() }
    func openApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    /// Une commande au dictionnaire de Spotify ; `nil` si elle échoue (refus d'autorisation compris).
    @discardableResult
    private func run(_ body: String) -> String? {
        var error: NSDictionary?
        let source = "tell application id \"\(Self.bundleID)\"\n\(body)\nend tell"
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            lastError = code == -1743
                ? String(localized: "Autorise StudyTrack à piloter Spotify : Réglages Système › Confidentialité › Automatisation.")
                : nil
            return nil
        }
        return result?.stringValue ?? ""
    }
    #else
    func refresh() {}
    #endif
}

/// Le volet Spotify : l'app Spotify de l'appareil.
struct SpotifyLocalView: View {
    @State private var local = SpotifyLocal.shared
    @State private var link = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            #if os(macOS)
            HStack(alignment: .center, spacing: 18) {
                AsyncImage(url: local.track?.artwork) { image in image.resizable().scaledToFill() } placeholder: {
                    RoundedRectangle(cornerRadius: 12).fill(StudyPalette.raised).overlay(Image(systemName: "music.note").font(.title))
                }
                .frame(width: 110, height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    Text(local.track?.title ?? String(localized: local.isRunning ? "Rien ne joue" : "Spotify est fermé"))
                        .font(Carnet.serif(22)).foregroundStyle(StudyPalette.ink).lineLimit(2)
                    if let artist = local.track?.artist { Text(artist).foregroundStyle(StudyPalette.inkSecondary) }
                    if local.isRunning {
                        HStack(spacing: 18) {
                            Button { local.previous() } label: { Image(systemName: "backward.fill") }
                            Button { local.togglePlay() } label: { Image(systemName: local.isPlaying ? "pause.fill" : "play.fill").font(.title2) }
                            Button { local.next() } label: { Image(systemName: "forward.fill") }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(StudyPalette.ink)
                        .padding(.top, 4)
                    } else if local.isInstalled {
                        Button("Ouvrir Spotify") { local.openApp() }.buttonStyle(PaperButtonStyle())
                    } else {
                        Text("Installe l'app Spotify pour la piloter d'ici.").font(.callout).foregroundStyle(StudyPalette.inkSecondary)
                    }
                }
            }
            #endif
            VStack(alignment: .leading, spacing: 8) {
                Text("Lancer dans Spotify").font(Carnet.serif(16)).foregroundStyle(StudyPalette.ink)
                HStack {
                    TextField("Lien d'une playlist ou d'un album (Partager › Copier le lien)", text: $link)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { local.play(link: link); link = "" }
                    Button("Écouter") { local.play(link: link); link = "" }
                        .buttonStyle(InkButtonStyle())
                        .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !local.saved.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(local.saved.enumerated()), id: \.element) { index, uri in
                            Button("\(uri.split(separator: ":").dropFirst().first.map(String.init)?.capitalized ?? "Lien") \(index + 1)") {
                                local.play(link: uri)
                            }
                            .buttonStyle(PaperButtonStyle())
                            .help(uri)
                        }
                    }
                }
            }
            if let error = local.lastError {
                Text(error).font(.callout).foregroundStyle(Carnet.wrong)
            }
        }
        .task {
            #if os(macOS)
            // Relu toutes les 4 s tant que le volet est ouvert (sans lancer Spotify).
            while !Task.isCancelled {
                local.refresh()
                try? await Task.sleep(for: .seconds(4))
            }
            #endif
        }
    }
}
