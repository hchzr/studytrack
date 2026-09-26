import SwiftUI

/// Le journal de l'app : ce qui a échoué, quand, et pourquoi.
///
/// Sans lui, un défaut signalé n'a **rien** à consulter. La seule réponse possible
/// était « réessaie et dis-moi ce qui se passe ».
struct DiagnosticsView: View {
    @State private var entries: [LogEntry] = []
    @State private var level: LogEntry.Level?
    @State private var liveCount = 0

    private var liveIcon: String {
        guard StudyActivityController.isEnabledBySystem else { return "xmark.circle.fill" }
        return liveCount > 0 ? "checkmark.circle.fill" : "questionmark.circle"
    }

    private var liveTint: Color {
        guard StudyActivityController.isEnabledBySystem else { return .red.accessibleInk }
        return liveCount > 0 ? .green.accessibleMark : .secondary
    }

    private var liveTitle: String {
        guard StudyActivityController.isEnabledBySystem else {
            return "Les activités en direct sont refusées pour StudyTrack (Réglages du système)."
        }
        if liveCount == 0 { return "Aucune activité en cours — l'îlot est vide, c'est normal." }
        return "\(liveCount) activité\(liveCount > 1 ? "s" : "") en cours."
    }
    @State private var showingClear = false

    private var shown: [LogEntry] { LogBuffer.filtered(entries, level: level) }

    var body: some View {
        List {
            Section {
                Picker("Niveau", selection: $level) {
                    Text("Tout").tag(LogEntry.Level?.none)
                    ForEach(LogEntry.Level.allCases, id: \.self) { value in
                        Text(value.label.capitalized).tag(LogEntry.Level?.some(value))
                    }
                }
                .pickerStyle(.segmented)
            }

            if shown.isEmpty {
                Section {
                    Text(entries.isEmpty
                         ? "Journal vide. Les erreurs de synchronisation, d'import et d'Anki viendront ici."
                         : "Aucune ligne à ce niveau.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("\(shown.count) ligne\(shown.count > 1 ? "s" : "")") {
                    ForEach(shown) { entry in
                        row(entry)
                    }
                }
            }

            Section {
                HStack(spacing: Layout.control) {
                    Image(systemName: liveIcon)
                        .foregroundStyle(liveTint)
                    VStack(alignment: .leading, spacing: Layout.tight) {
                        Text(liveTitle)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail = StudyActivityController.lastError {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
                Button {
                    StudyActivityController.startTest()
                    liveCount = StudyActivityController.liveCount
                    Haptics.tap()
                } label: {
                    Label("Lancer une activité d'essai", systemImage: "play.circle")
                }
                Button(role: .destructive) {
                    StudyActivityController.end()
                    liveCount = StudyActivityController.liveCount
                    Haptics.warning()
                } label: {
                    Label("Fermer toute activité", systemImage: "stop.circle")
                }
                .disabled(liveCount == 0)
            } header: {
                Text("Îlot et écran verrouillé")
            } footer: {
                Text("« Activité d'essai » doit faire apparaître un chrono dans l'îlot et sur l'écran verrouillé en quelques secondes. Si le compteur d'activités reste à zéro, le système refuse l'activité — regarde alors Réglages › StudyTrack › Activités en direct.")
            }

            Section {
                if let url = exportURL {
                    ShareLink(item: url) {
                        Label("Partager le journal", systemImage: "square.and.arrow.up")
                    }
                }
                Button(role: .destructive) {
                    showingClear = true
                } label: {
                    Label("Vider le journal", systemImage: "trash")
                }
                .disabled(entries.isEmpty)
            } footer: {
                Text("Le journal reste sur cet appareil. Il ne contient que des messages techniques — aucune donnée de cours ni identité.")
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Vider le journal ?", isPresented: $showingClear, titleVisibility: .visible) {
            Button("Vider", role: .destructive) {
                AppLog.clear()
                entries = []
            }
            Button("Annuler", role: .cancel) {}
        }
        .onAppear {
            entries = AppLog.load()
            liveCount = StudyActivityController.liveCount
        }
    }

    private func row(_ entry: LogEntry) -> some View {
        HStack(alignment: .top, spacing: Layout.control) {
            Image(systemName: entry.level.icon)
                .font(.footnote)
                .foregroundStyle(tint(entry.level))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.message)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Layout.snug) {
                    Text(DateUtils.shortDay.string(from: entry.date))
                    Text(DateUtils.time.string(from: entry.date))
                    Text("·")
                    Text(entry.category)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                if let detail = entry.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.level.label), \(entry.category), \(entry.message)")
    }

    private func tint(_ level: LogEntry.Level) -> Color {
        switch level {
        case .info: return .secondary
        case .warning: return .orange.accessibleInk
        case .error: return .red.accessibleInk
        }
    }

    /// Écrit le journal dans un fichier temporaire pour le partager.
    private var exportURL: URL? {
        guard !entries.isEmpty else { return nil }
        let text = LogBuffer.text(entries)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("studytrack-journal.txt")
        guard (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        return url
    }
}
