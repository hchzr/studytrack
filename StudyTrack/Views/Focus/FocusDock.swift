import SwiftUI
import SwiftData

/// Le chrono, toujours à portée, au-dessus de la barre d'onglets.
///
/// Focus était un onglet : démarrer une session obligeait à quitter l'écran où
/// l'on était, et une session en cours ne se voyait que sur « Aujourd'hui ».
/// Le dock remplace l'onglet :
///   • **au repos**, il propose la prochaine chose à faire (`NextActionEngine`)
///     en un toucher, et ouvre Focus pour tout le reste ;
///   • **pendant une session**, c'est un mini-lecteur : temps qui défile, pause,
///     arrêt — et un toucher rouvre Focus.
struct FocusDock: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Course.code) private var courses: [Course]
    @State private var timer: FocusTimerState?

    private var activeTimer: FocusTimerState? {
        guard let timer, timer.isRunning || timer.isRestorable() else { return nil }
        return timer
    }

    var body: some View {
        Group {
            if let activeTimer {
                player(activeTimer)
            } else {
                starter
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear { timer = FocusTimerStore.load() }
        .onReceive(NotificationCenter.default.publisher(for: FocusTimerStore.didSave)) { _ in
            timer = FocusTimerStore.load()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { timer = FocusTimerStore.load() }
        }
        .onChange(of: app.router.showingFocus) { _, _ in timer = FocusTimerStore.load() }
    }

    // MARK: Au repos

    private var starter: some View {
        let next = NextActionEngine.actions(for: courses, limit: 1).first
        return HStack(spacing: Layout.inline) {
            Button {
                if let next {
                    app.router.startFocus(courseID: next.courseID, courseCode: next.courseCode,
                                          taskType: next.taskType, label: next.focusLabel)
                } else {
                    app.router.openFocus()
                }
                Haptics.tap()
            } label: {
                HStack(spacing: Layout.control) {
                    Image(systemName: "play.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(next.map { Color(hex: $0.colorHex) } ?? Theme.accent, in: Circle())
                    VStack(alignment: .leading, spacing: 0) {
                        Text(next.map { "\($0.courseCode) · \($0.title)" } ?? "Démarrer une session")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(next?.reasonLabel ?? "Chrono libre")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(next.map { "Démarrer le chrono : \($0.courseCode), \($0.title)" } ?? "Démarrer une session")

            Button {
                app.router.openFocus()
            } label: {
                Image(systemName: "timer")
                    .font(.body.weight(.semibold))
                    .frame(width: Layout.minTouch, height: Layout.minTouch)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accentInk)
            .accessibilityLabel("Ouvrir Focus : chrono, saisie, journal")
        }
        .padding(.horizontal, Layout.block)
    }

    // MARK: Pendant une session

    private func player(_ state: FocusTimerState) -> some View {
        let course = courses.first { $0.id == state.courseID }
        let tint = course.map { Color(hex: $0.colorHex) } ?? Theme.accent
        return HStack(spacing: Layout.inline) {
            Button {
                app.router.openFocus()
            } label: {
                HStack(spacing: Layout.control) {
                    Circle()
                        .fill(tint)
                        .frame(width: 10, height: 10)
                        .opacity(state.isRunning ? 1 : 0.4)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(label(state, course: course))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(state.isRunning ? "En cours" : "En pause")
                            .font(.caption)
                            .foregroundStyle(state.isRunning ? .secondary : Color.orange.accessibleInk)
                    }
                    Spacer(minLength: 0)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Self.clock(state.elapsed(at: context.date)))
                            .font(.subheadline.weight(.bold).monospacedDigit())
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(label(state, course: course)), \(state.isRunning ? "en cours" : "en pause"). Ouvrir Focus")

            Button {
                FocusTimerCommandHandler.handle(state.isRunning ? .pause : .resume, container: app)
                Haptics.tap()
            } label: {
                Image(systemName: state.isRunning ? "pause.fill" : "play.fill")
                    .font(.body.weight(.semibold))
                    .frame(width: Layout.minTouch, height: Layout.minTouch)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state.isRunning ? "Mettre en pause" : "Reprendre")

            Button {
                FocusTimerCommandHandler.handle(.finish, container: app)
                Haptics.success()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.body.weight(.semibold))
                    .frame(width: Layout.minTouch, height: Layout.minTouch)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Arrêter et enregistrer la session")
        }
        .padding(.leading, Layout.block)
        .padding(.trailing, Layout.tight)
    }

    /// « 12:05 », « 1:02:09 ».
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    private func label(_ state: FocusTimerState, course: Course?) -> String {
        if !state.contextLabel.isEmpty { return state.contextLabel }
        return [course?.displayCode ?? "Session libre", state.taskType.label].joined(separator: " · ")
    }
}

/// Place le dock : accessoire de la barre d'onglets sur iOS 26 (il se replie
/// avec elle au défilement), bandeau au-dessus de la barre avant.
struct FocusDockPlacement: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.tabViewBottomAccessory { FocusDock() }
        } else {
            content
        }
    }
}

/// Avant iOS 26 : le dock posé au bas de chaque onglet, sur un fond de barre.
struct LegacyFocusDockInset: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else {
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                FocusDock()
                    .padding(.vertical, Layout.snug)
                    .background(.bar)
                    .overlay(alignment: .top) { Divider() }
            }
        }
    }
}
