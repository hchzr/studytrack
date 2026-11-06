import AppKit

/// Les captures de vérification (`-snapshot`) : l'app tourne sans **rien**
/// montrer — ni icône dans le Dock, ni barre des menus, ni pilule du chrono,
/// ni raccourci global, ni fenêtre à l'écran. La seule fenêtre est celle du
/// mode étude, transparente et hors de l'écran, d'où l'image est tirée.
/// Toujours éteint en Release.
enum HeadlessCapture {
    #if DEBUG
    static let active = CommandLine.arguments.contains("-snapshot")
    #else
    static let active = false
    #endif

    /// Au plus tôt (`applicationWillFinishLaunching`), avant que le Dock ne
    /// montre l'app ; puis on range toute fenêtre qui voudrait apparaître.
    @MainActor
    static func begin() {
        guard active else { return }
        NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            while true {
                if NSApp.activationPolicy() != .prohibited { NSApp.setActivationPolicy(.prohibited) }
                for window in NSApp.windows where window.isVisible && !(window is StudyWindow) {
                    window.orderOut(nil)
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
}
