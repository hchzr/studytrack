import AppKit
import CoreImage
import IOKit.ps
import Network
import SwiftUI

/// Le fond du bureau d'étude : le fond d'écran de l'utilisateur·rice, flouté
/// **une fois** (jamais en continu : le verre posé dessus suffit à la vie, et la
/// batterie compte), puis assombri par le papier de nuit. Un fond d'écran vidéo
/// ou introuvable : le papier seul, avec la lueur du cours.
@MainActor
@Observable
final class DeskGround {
    static let shared = DeskGround()

    private(set) var image: NSImage?
    private var loadedFor: URL?

    func load() {
        guard let screen = NSScreen.screens.first,
              let url = NSWorkspace.shared.desktopImageURL(for: screen), url != loadedFor else { return }
        loadedFor = url
        Task.detached(priority: .utility) {
            let blurred = Self.blurred(url)
            await MainActor.run { DeskGround.shared.image = blurred }
        }
    }

    /// Réduit à 640 px de large, floute, rend une image. Hors du fil principal.
    nonisolated private static func blurred(_ url: URL) -> NSImage? {
        guard url.pathExtension.lowercased() != "mov", let input = CIImage(contentsOf: url) else { return nil }
        let scale = 640 / max(input.extent.width, 1)
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let blur = small.clampedToExtent().applyingGaussianBlur(sigma: 14).cropped(to: small.extent)
        let context = CIContext()
        guard let cg = context.createCGImage(blur, from: blur.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: blur.extent.width, height: blur.extent.height))
    }
}

// MARK: - Apps ouvertes

/// Les apps permises qui tournent : un point sous leur icône dans la colonne
/// d'outils, comme dans le Dock qu'un blocage cache.
@MainActor
@Observable
final class RunningApps {
    static let shared = RunningApps()

    private(set) var running: Set<String> = []
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { RunningApps.shared.refresh() }
            })
        }
    }

    private func refresh() {
        running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }
}

// MARK: - Barre d'état

/// L'heure, la batterie et le réseau : ce que la barre des menus de macOS
/// montrait, et qu'un blocage cache. Mise à jour à la minute.
@MainActor
@Observable
final class DeskStatus {
    static let shared = DeskStatus()

    private(set) var battery: Double?
    private(set) var charging = false
    private(set) var online = true
    private var monitor: NWPathMonitor?
    private var timer: Timer?

    func start() {
        guard monitor == nil else { return }
        read()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            Task { @MainActor in DeskStatus.shared.online = path.status == .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "com.hczr.studytrack.status"))
        self.monitor = monitor
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { DeskStatus.shared.read() }
        }
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        timer?.invalidate()
        timer = nil
    }

    private func read() {
        let snapshot = PowerReader.read()
        battery = snapshot.level
        charging = snapshot.charging
    }
}

struct DeskStatusItems: View {
    @State private var status = DeskStatus.shared

    var body: some View {
        HStack(spacing: 10) {
            if !status.online {
                Image(systemName: "wifi.slash").help("Pas de réseau")
            }
            if let level = status.battery {
                HStack(spacing: 3) {
                    Image(systemName: status.charging ? "battery.100.bolt" : "battery.\(Int((level * 4).rounded()) * 25)")
                    Text("\(Int((level * 100).rounded())) %").monospacedDigit()
                }
                .help(status.charging ? "Sur secteur" : "Sur batterie")
            }
            TimelineView(.everyMinute) { context in
                Text(context.date, format: .dateTime.hour().minute()).monospacedDigit()
            }
        }
        .font(.callout)
        .foregroundStyle(StudyPalette.inkSecondary)
        .onAppear { status.start() }
    }
}
