import SwiftUI
import SwiftData

/// Focus : le chrono, et le bilan de ce qu'il a compté.
///
/// Le journal du chrono (le temps du jour, ses sessions) doublait le Bilan :
/// deux écrans pour le même temps, sans lien entre eux. Les sessions vivent
/// maintenant dans le Bilan, sous le graphique du temps, et le bouton de la
/// barre y mène. Ajouter une session passée, ajuster le temps ou régler le
/// Pomodoro sont des actions, rangées dans le menu de la barre.
struct FocusView: View {
    /// Présenté en feuille par le dock : le bouton qui la ferme.
    var onClose: (() -> Void)? = nil

    @Environment(AppContainer.self) private var app

    @State private var showingStats = false
    @State private var showingManual = false
    @State private var showingPomodoroSettings = false
    @State private var showingShortcutEditor = false
    /// Mode ajustement du temps compté, partagé avec le panneau du chrono.
    @State private var isAdjusting = false

    var body: some View {
        NavigationStack {
            ScrollView {
                FocusTimerPanel(isAdjusting: $isAdjusting,
                                showingPomodoroSettings: $showingPomodoroSettings,
                                showingShortcutEditor: $showingShortcutEditor)
                    .padding(.horizontal, Carnet.screenPadding)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                    .adaptiveColumn()
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Carnet.ground.ignoresSafeArea())
            .carnetBackground()
            .navigationTitle("Chrono")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showingStats) {
                StatsView()
            }
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(action: onClose) { Image(systemName: "chevron.down") }
                            .accessibilityLabel("Fermer le chrono")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showingStats = true } label: { Image(systemName: "chart.bar.xaxis") }
                        .accessibilityLabel("Bilan et sessions")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showingManual = true
                        } label: {
                            Label("Ajouter une session passée", systemImage: "square.and.pencil")
                        }
                        Button {
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
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Plus d'actions")
                }
            }
            .sheet(isPresented: $showingManual) { ManualSessionSheet() }
            .sheet(isPresented: $showingPomodoroSettings) { PomodoroSettingsSheet() }
            .sheet(isPresented: $showingShortcutEditor) { FocusShortcutsEditor() }
            .task {
                applyFocusMode(app.router.focusMode)
                #if DEBUG
                if PreviewLaunch.isSet(PreviewLaunch.shortcutsFlag) { showingShortcutEditor = true }
                #endif
            }
            .onChange(of: app.router.focusMode) { _, newValue in applyFocusMode(newValue) }
        }
    }

    /// « Manuel » et « Journal » (le bilan) demandés depuis ailleurs (actions rapides).
    private func applyFocusMode(_ requested: AppRouter.FocusMode?) {
        guard let requested else { return }
        switch requested {
        case .timer: showingStats = false
        case .manual: showingManual = true
        case .journal: showingStats = true
        }
        app.router.focusMode = nil
    }
}
