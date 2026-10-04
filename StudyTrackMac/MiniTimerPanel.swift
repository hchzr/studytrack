import AppKit
import SwiftUI
import SwiftData

/// Le chrono flottant : une petite pilule au-dessus de toutes les fenêtres,
/// sur tous les bureaux, pendant une session. On la déplace où on veut (la
/// place est retenue) ; au survol, pause et terminer.
@MainActor
final class MiniTimerPanel {
    static let shared = MiniTimerPanel()

    private var panel: NSPanel?
    weak var timer: MacTimer?
    weak var settings: MacSettings?
    var container: ModelContainer?

    /// À appeler à chaque changement du chrono ou du réglage.
    func update() {
        guard let timer, let settings else { return }
        let wanted = settings.floatingTimer && timer.phase != .idle
        if wanted {
            show(timer: timer, settings: settings)
        } else {
            panel?.orderOut(nil)
        }
    }

    private func show(timer: MacTimer, settings: MacSettings) {
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 236, height: 52),
                                styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                                backing: .buffered, defer: false)
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.isMovableByWindowBackground = true
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            var root = AnyView(MiniTimerView()
                .environment(timer)
                .environment(settings))
            if let container { root = AnyView(root.modelContainer(container)) }
            let host = NSHostingView(rootView: root)
            host.frame = panel.contentRect(forFrameRect: panel.frame)
            panel.contentView = host
            panel.setFrameAutosaveName("StudyTrack.MiniTimer")
            if !panel.setFrameUsingName("StudyTrack.MiniTimer"), let screen = NSScreen.main {
                let frame = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: frame.maxX - 236 - 24, y: frame.maxY - 52 - 24))
            }
            self.panel = panel
        }
        panel?.orderFrontRegardless()
    }
}

/// La pilule : la pastille du cours, le temps, ce qu'on fait ; les gestes au survol.
struct MiniTimerView: View {
    @Environment(MacTimer.self) private var timer
    @Environment(MacSettings.self) private var settings
    @Query(sort: \Course.code) private var courses: [Course]
    @State private var hovering = false

    private var course: Course? { courses.first { $0.id == timer.courseID } }
    private var tint: Color { timer.phase == .onBreak ? MacStyle.breakTint : MacTargets.tint(course) }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                TimerRing(progress: timer.ringProgress, tint: tint, lineWidth: 3.5, draining: timer.phase == .onBreak)
                if timer.phase == .paused {
                    Image(systemName: "pause.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(tint)
                } else if timer.phase == .onBreak {
                    Image(systemName: "cup.and.saucer.fill").font(.system(size: 9)).foregroundStyle(tint)
                }
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text(timer.displayTime.clockLabel)
                    .font(MacStyle.clock(19, weight: .regular))
                    .contentTransition(.numericText())
                    .foregroundStyle(timer.phase == .paused ? .secondary : .primary)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if hovering {
                HStack(spacing: 4) {
                    Button { primary() } label: {
                        Image(systemName: timer.phase == .running ? "pause.fill" : "play.fill")
                    }
                    .help(timer.phase == .running ? "Pause" : "Reprendre")
                    Button { timer.finish() } label: { Image(systemName: "checkmark") }
                        .help("Terminer et enregistrer")
                }
                .buttonStyle(RoundButtonStyle(size: 26))
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, 12)
        .frame(width: 236, height: 52)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .contentShape(Capsule())
        .onHover { value in withAnimation(.easeOut(duration: 0.15)) { hovering = value } }
        .onTapGesture(count: 2) { primary() }
        .contextMenu {
            Button(timer.phase == .running ? "Pause" : "Reprendre") { primary() }
            Button("Terminer et enregistrer") { timer.finish() }
            Divider()
            Button("Masquer le chrono flottant") {
                settings.floatingTimer = false
                MiniTimerPanel.shared.update()
            }
        }
    }

    private var subtitle: String {
        let what = MacTargets.headline(course: course, taskType: timer.taskType, targetID: timer.targetID)
        if let status = timer.statusLabel { return "\(status) · \(what)" }
        guard let course else { return what }
        return "\(course.displayCode) · \(what)"
    }

    private func primary() {
        if timer.phase == .onBreak { timer.skipBreak() } else { timer.toggle() }
    }
}
