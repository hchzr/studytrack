import SwiftUI
import SwiftData

/// Focus : le chrono, et le journal de ce qu'il a compté.
///
/// Trois segments (« Chrono », « Manuel », « Journal ») obligeaient à choisir un
/// mode avant d'agir, alors que la saisie manuelle est un geste rare et qu'elle
/// appartient au journal. Il reste deux vues : le chrono, qui est l'écran, et le
/// journal, qui en est la mémoire. Ajouter une session passée, ajuster le temps
/// ou régler le Pomodoro sont des actions, rangées dans le menu de la barre.
struct FocusView: View {
    /// Présenté en feuille par le dock : le bouton qui la ferme.
    var onClose: (() -> Void)? = nil

    @Environment(AppContainer.self) private var app

    @State private var mode: Mode = .timer
    @State private var showingManual = false
    @State private var showingPomodoroSettings = false
    @State private var showingShortcutEditor = false
    @State private var showingHistory = false
    /// Mode ajustement du temps compté, partagé avec le panneau du chrono.
    @State private var isAdjusting = false

    enum Mode: String, CaseIterable, Identifiable {
        case timer, journal
        var id: String { rawValue }
        var title: String { self == .timer ? "Chrono" : "Journal" }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                    Picker("Vue", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    switch mode {
                    case .timer:
                        FocusTimerPanel(isAdjusting: $isAdjusting,
                                        showingPomodoroSettings: $showingPomodoroSettings,
                                        showingShortcutEditor: $showingShortcutEditor)
                    case .journal:
                        FocusJournalPanel(onAddManual: { showingManual = true },
                                          onShowHistory: { showingHistory = true })
                    }
                }
                .padding(Layout.screenPadding)
                .adaptiveColumn()
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Focus")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Fermer", action: onClose)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showingManual = true
                        } label: {
                            Label("Ajouter une session passée", systemImage: "square.and.pencil")
                        }
                        Button {
                            mode = .timer
                            withAnimation(Motion.snappy) { isAdjusting = true }
                        } label: {
                            Label("Corriger le temps compté", systemImage: "slider.horizontal.below.rectangle")
                        }
                        .disabled(!app.focus.hasSession)
                        Divider()
                        Button {
                            showingPomodoroSettings = true
                        } label: {
                            Label("Réglages Pomodoro", systemImage: "timer")
                        }
                        Button {
                            showingShortcutEditor = true
                        } label: {
                            Label("Modifier les raccourcis", systemImage: "bolt")
                        }
                        Button {
                            showingHistory = true
                        } label: {
                            Label("Tout l'historique", systemImage: "clock.arrow.circlepath")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Plus d'actions")
                }
            }
            .sheet(isPresented: $showingManual) { ManualSessionSheet() }
            .sheet(isPresented: $showingPomodoroSettings) { PomodoroSettingsSheet() }
            .sheet(isPresented: $showingShortcutEditor) { FocusShortcutsEditor() }
            .sheet(isPresented: $showingHistory) { SessionHistoryView() }
            .task {
                applyFocusMode(app.router.focusMode)
                #if DEBUG
                if PreviewLaunch.isSet(PreviewLaunch.shortcutsFlag) { showingShortcutEditor = true }
                #endif
            }
            .onChange(of: app.router.focusMode) { _, newValue in applyFocusMode(newValue) }
        }
    }

    /// « Manuel » et « Journal » demandés depuis ailleurs (actions rapides).
    private func applyFocusMode(_ requested: AppRouter.FocusMode?) {
        guard let requested else { return }
        switch requested {
        case .timer: mode = .timer
        case .manual:
            mode = .journal
            showingManual = true
        case .journal: mode = .journal
        }
        app.router.focusMode = nil
    }
}
