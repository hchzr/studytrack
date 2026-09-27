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
    @Query(sort: \Course.code) private var courses: [Course]

    private var focus: FocusController { app.focus }

    var body: some View {
        Group {
            if focus.hasSession, let state = focus.state {
                player(state)
            } else {
                starter
            }
        }
        .frame(maxWidth: .infinity)
        .animation(Motion.snappy, value: focus.hasSession)
    }

    // MARK: Au repos

    private var starter: some View {
        let next = NextActionEngine.actions(for: courses, limit: 1).first
        let tint = next.map { Color(hex: $0.colorHex) } ?? Theme.accent
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
                        .foregroundStyle(Theme.knockedOutInk)
                        .offset(x: 1)
                        .frame(width: 34, height: 34)
                        .background(tint.accessibleMark, in: Circle())
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
            .buttonStyle(PressableStyle(scale: 0.98))
            .accessibilityLabel(next.map { "Démarrer le chrono : \($0.courseCode), \($0.title)" } ?? "Démarrer une session")

            Button {
                app.router.openFocus()
                Haptics.tap()
            } label: {
                Image(systemName: "timer")
                    .font(.body.weight(.semibold))
                    .frame(width: Layout.minTouch, height: Layout.minTouch)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .foregroundStyle(Theme.accentInk)
            .accessibilityLabel("Ouvrir Focus : chrono et journal")
        }
        .padding(.horizontal, Layout.block)
    }

    // MARK: Pendant une session

    private func player(_ state: FocusTimerState) -> some View {
        let course = courses.first { $0.id == state.courseID }
        let tint = course.map { Color(hex: $0.colorHex) } ?? Theme.accent
        return TimelineView(.periodic(from: .now, by: 1)) { context in
            let phase = focus.phase(at: context.date)
            HStack(spacing: Layout.inline) {
                Button {
                    app.router.openFocus()
                } label: {
                    HStack(spacing: Layout.control) {
                        statusMark(phase: phase, tint: tint)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(label(state, course: course))
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(statusText(phase))
                                .font(.caption)
                                .foregroundStyle(phase == .paused ? Color.orange.accessibleInk : .secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Text(clock(phase: phase, state: state, now: context.date))
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(phase.isBreak ? Color.teal.accessibleInk : .primary)
                            .contentTransition(.numericText())
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(label(state, course: course)), \(statusText(phase)). Ouvrir Focus")

                primaryButton(phase: phase)

                Button {
                    focus.finish()
                    Haptics.success()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .frame(width: Layout.minTouch, height: Layout.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Terminer et enregistrer la session")
            }
        }
        .padding(.leading, Layout.block)
        .padding(.trailing, Layout.tight)
    }

    @ViewBuilder
    private func primaryButton(phase: FocusPhase) -> some View {
        let (icon, label): (String, String) = {
            switch phase {
            case .working: return ("pause.fill", "Mettre en pause")
            case .onBreak: return ("forward.fill", "Terminer la pause")
            default: return ("play.fill", "Reprendre")
            }
        }()
        Button {
            switch phase {
            case .working: focus.pause()
            case .onBreak: focus.skipBreak()
            default: focus.resume()
            }
            Haptics.tap()
        } label: {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: Layout.minTouch, height: Layout.minTouch)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
    }

    /// Le point d'état : plein quand on travaille, une tasse en pause Pomodoro.
    @ViewBuilder
    private func statusMark(phase: FocusPhase, tint: Color) -> some View {
        if phase.isBreak {
            Image(systemName: "cup.and.saucer.fill")
                .font(.caption)
                .foregroundStyle(Color.teal.accessibleMark)
                .frame(width: 16)
        } else {
            Circle()
                .fill(tint.accessibleMark)
                .frame(width: 10, height: 10)
                .opacity(phase == .working ? 1 : 0.35)
                .frame(width: 16)
        }
    }

    private func statusText(_ phase: FocusPhase) -> String {
        switch phase {
        case .working: return focus.isPomodoro ? "Bloc \(focus.pomodoroStatus().blockNumber) en cours" : "En cours"
        case .paused: return "En pause"
        case .onBreak(let kind, _, _): return kind.label
        case .readyForBlock(let block): return "Bloc \(block) prêt"
        case .idle: return "Prêt"
        }
    }

    /// Le temps travaillé — ou, pendant une pause, ce qu'il en reste.
    private func clock(phase: FocusPhase, state: FocusTimerState, now: Date) -> String {
        if case .onBreak(_, _, let end) = phase {
            return TimerText.clock(max(0, end.timeIntervalSince(now)).rounded(.up))
        }
        return TimerText.clock(state.elapsed(at: now))
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
