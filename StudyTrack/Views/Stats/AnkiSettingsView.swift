import SwiftUI
import SwiftData

/// Anki : envoyer ses exercices et sa théorie dans un paquet de révision.
///
/// L'app mesure le temps d'étude ; Anki fait tenir le vocabulaire et les
/// définitions. Le pont entre les deux passe par **AnkiConnect**, l'extension
/// d'Anki Desktop — donc Anki doit être ouvert, sur le même réseau, et l'extension
/// installée. L'écran le dit avant de laisser croire à une panne.
struct AnkiSettingsView: View {
    @Environment(AppContainer.self) private var app
    @Query(sort: \Course.code) private var courses: [Course]

    @State private var isTesting = false
    @State private var status: Status = .unknown
    @State private var decks: [String] = []
    @State private var selectedCourseID: UUID?
    @State private var isSending = false
    @State private var sendMessage: String?
    @State private var isSyncingReviews = false
    @State private var reviewMessage: String?
    @Environment(\.modelContext) private var context

    private enum Status: Equatable {
        case unknown
        case ok(Int)
        case failed(String)
    }

    private var tracked: [Course] { courses.filter(\.isTracked) }
    private var course: Course? { tracked.first { $0.id == selectedCourseID } ?? tracked.first }

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                TextField("Adresse (ex : 192.168.1.42:8765)", text: $settings.ankiEndpoint)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)

                HStack(alignment: .top, spacing: Layout.control) {
                    Image(systemName: statusIcon)
                        .foregroundStyle(statusTint)
                    VStack(alignment: .leading, spacing: Layout.tight) {
                        Text(statusTitle)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Layout.inline)
                    if isTesting { ProgressView() }
                }

                Button {
                    Task { await test() }
                } label: {
                    Label("Tester la connexion", systemImage: "antenna.radiowaves.left.and.right")
                }
                .disabled(isTesting || !settings.isAnkiConfigured)
            } header: {
                Text("AnkiConnect")
            } footer: {
                Text("Sur Anki Desktop : Outils › Modules complémentaires › **Obtenir des modules**, code **2055492159**, puis redémarre Anki. L'extension écoute sur le port 8765 de l'ordinateur — sur un iPhone, écris l'**adresse du Mac** sur le réseau local, pas `127.0.0.1`.")
            }

            Section {
                HStack {
                    Label("Temps de révision", systemImage: TaskType.flashcards.icon)
                    Spacer()
                    Text(settings.ankiLastSync.map { "relevé \(DateUtils.relativeLabel($0).lowercased()) à \(DateUtils.time.string(from: $0))" } ?? "jamais relevé")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task { await syncReviews() }
                } label: {
                    HStack {
                        Label("Relever maintenant", systemImage: "arrow.triangle.2.circlepath")
                        if isSyncingReviews { Spacer(); ProgressView() }
                    }
                }
                .disabled(!settings.isAnkiConfigured || isSyncingReviews)
                if let reviewMessage {
                    Text(reviewMessage).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Temps passé dans Anki")
            } footer: {
                Text("Automatique : à chaque ouverture de l'app (au plus toutes les dix minutes), les révisions faites depuis le dernier relevé deviennent des sessions étiquetées « Anki ». Un paquet qui porte le code ou le nom d'un cours y est rattaché ; les autres restent comptés sans cours.")
            }

            if !decks.isEmpty {
                Section {
                    Picker("Paquet", selection: $settings.ankiDeck) {
                        ForEach(decks, id: \.self) { deck in
                            Text(deck).tag(deck)
                        }
                        if !decks.contains(settings.ankiDeck) {
                            Text(settings.ankiDeck.isEmpty ? "StudyTrack" : settings.ankiDeck)
                                .tag(settings.ankiDeck)
                        }
                    }
                    TextField("Modèle de note", text: $settings.ankiModel)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Destination")
                } footer: {
                    Text("Le paquet est créé s'il n'existe pas. « Basic » est le modèle par défaut d'Anki ; il a deux champs, Recto et Verso.")
                }
            }

            Section {
                Picker("Cours", selection: $selectedCourseID) {
                    Text("Tous les cours suivis").tag(UUID?.none)
                    ForEach(tracked) { value in
                        Text("\(value.displayCode) — \(value.name)").tag(UUID?.some(value.id))
                    }
                }

                Button {
                    Task { await sendExercises() }
                } label: {
                    Label("Envoyer les exercices à refaire", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isSending || !canSend)
                .accessibilityHint("Crée une carte par exercice marqué « à refaire » ou fait mais non corrigé")

                Button {
                    Task { await sendTheory() }
                } label: {
                    Label("Envoyer la théorie non résumée", systemImage: "text.book.closed")
                }
                .disabled(isSending || !canSend)

                if isSending {
                    HStack(spacing: Layout.snug) {
                        ProgressView()
                        Text("Envoi…").font(.caption)
                    }
                }
                if let sendMessage {
                    Text(sendMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Envoyer")
            } footer: {
                Text("Une carte par élément, avec le cours et le numéro au recto — sans eux, « Montrer que… » ne veut plus rien dire dans six semaines. Les doublons sont ignorés par Anki.")
            }
        }
        .navigationTitle("Anki")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadDecks() }
    }

    private var canSend: Bool {
        app.settings.isAnkiConfigured
    }

    // MARK: État

    private var statusIcon: String {
        switch status {
        case .ok: return "checkmark.circle.fill"
        case .unknown: return "questionmark.circle"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var statusTint: Color {
        switch status {
        case .ok: return .green.accessibleMark
        case .unknown: return .secondary
        case .failed: return .orange.accessibleInk
        }
    }

    private var statusTitle: String {
        switch status {
        case .ok(let version):
            return "Anki répond (protocole \(version)) · \(decks.count) paquet\(decks.count > 1 ? "s" : "")"
        case .unknown:
            return app.settings.isAnkiConfigured
                ? "Connexion non testée. Anki doit être ouvert sur ton ordinateur."
                : "Renseigne l'adresse du Mac où tourne Anki."
        case .failed(let message):
            return message
        }
    }

    @MainActor
    private func syncReviews() async {
        isSyncingReviews = true
        defer { isSyncingReviews = false }
        do {
            let outcome = try await AnkiReviewSync.sync(context: context, settings: app.settings)
            reviewMessage = outcome.sessionsAdded == 0
                ? "Rien de nouveau depuis le dernier relevé."
                : "\(outcome.sessionsAdded) session\(outcome.sessionsAdded > 1 ? "s" : "") ajoutée\(outcome.sessionsAdded > 1 ? "s" : "") · \(DateUtils.durationLabel(seconds: outcome.seconds))."
            Haptics.success()
        } catch {
            reviewMessage = error.localizedDescription
        }
    }

    private func test() async {
        isTesting = true
        status = .unknown
        do {
            let connection = try await AnkiService.test(endpoint: app.settings.ankiEndpoint)
            decks = connection.decks
            status = .ok(connection.version)
            if app.settings.ankiDeck.isEmpty, let first = decks.first {
                app.settings.ankiDeck = first
            }
            Haptics.success()
        } catch {
            decks = []
            status = .failed(error.localizedDescription)
            Haptics.error()
        }
        isTesting = false
    }

    private func loadDecks() async {
        guard app.settings.isAnkiConfigured else { return }
        await test()
    }

    // MARK: Envoi

    private func scopedCourses() -> [Course] {
        course.map { [$0] } ?? tracked
    }

    private func sendExercises() async {
        let notes = scopedCourses().flatMap { course in
            course.allExercises
                .filter { $0.redoRequired || ($0.isDone && !$0.isCorrected) }
                .map { AnkiNoteFactory.exercise($0, deck: deckName, model: app.settings.ankiModel) }
        }
        await send(notes, label: "exercice")
    }

    private func sendTheory() async {
        let notes = scopedCourses().flatMap { course in
            course.theoryItems
                .filter { !$0.isSummarized }
                .map { AnkiNoteFactory.theory($0, deck: deckName, model: app.settings.ankiModel) }
        }
        await send(notes, label: "élément de théorie")
    }

    private var deckName: String {
        let trimmed = app.settings.ankiDeck.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "StudyTrack" : trimmed
    }

    private func send(_ notes: [AnkiNote], label: String) async {
        guard !notes.isEmpty else {
            sendMessage = "Rien à envoyer : aucun \(label) dans ce périmètre."
            return
        }
        isSending = true
        sendMessage = nil
        let result = await AnkiService.add(notes, endpoint: app.settings.ankiEndpoint)
        isSending = false

        var parts = ["\(result.added) carte\(result.added > 1 ? "s" : "") envoyée\(result.added > 1 ? "s" : "")"]
        if result.skipped > 0 { parts.append("\(result.skipped) ignorée\(result.skipped > 1 ? "s" : "")") }
        sendMessage = parts.joined(separator: " · ")
            + (result.firstError.map { "\n\($0)" } ?? "")
        if result.added > 0 { Haptics.success() } else { Haptics.warning() }
    }
}
