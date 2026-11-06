import SwiftUI
import UIKit

/// Claude sur l'iPhone, comme au Mac et sur Windows : l'app Claude (ton abonnement) quand elle
/// est installée — la question et le contexte copiés, l'app ouverte —, sinon le tuteur gratuit
/// dans l'app (`FreeTutor`), sur la même consigne serveur.
enum PhoneClaude {
    /// L'app Claude répond-elle à `claude://` ? (`LSApplicationQueriesSchemes` dans Info.plist.)
    static var hasClaudeApp: Bool {
        URL(string: "claude://").map { UIApplication.shared.canOpenURL($0) } ?? false
    }

    /// Le tuteur gratuit existe-t-il dans cette version (serveur configuré) ?
    static var hasFreeTutor: Bool { SupabaseConfig.isConfigured }
}

/// Une question à poser : présentée en feuille, envoyée à l'ouverture.
struct TutorQuestion: Identifiable {
    let id = UUID()
    let text: String
}

/// La conversation avec le tuteur gratuit, pour l'exercice en cours.
struct PhoneTutorChat: View {
    let course: Course?
    let exercise: Exercise?
    let first: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private struct Line: Identifiable {
        let id = UUID()
        let student: Bool
        var text: String
        var error = false
    }

    @State private var lines: [Line] = []
    /// Ce que le serveur reçoit : le contexte de l'exercice dans le premier message.
    @State private var history: [(role: String, content: String)] = []
    @State private var draft = ""
    @State private var answering = false
    @FocusState private var typing: Bool

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(lines) { line in bubble(line) }
                    if answering {
                        ProgressView().padding(.leading, 4)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: lines.count) { _, _ in
                withAnimation { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    var body: some View {
        NavigationStack {
            transcript
            .safeAreaInset(edge: .bottom) { composer }
            .background(Carnet.ground)
            .navigationTitle(exercise?.displayNumber ?? "Claude")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        quickHint()
                    } label: { Image(systemName: "lightbulb") }
                    .accessibilityLabel("Un indice")
                    .disabled(answering)
                }
            }
        }
        .task { if lines.isEmpty { send(first) } }
    }

    private func bubble(_ line: Line) -> some View {
        HStack {
            if line.student { Spacer(minLength: 40) }
            Text(markdown(line.text))
                .font(.body)
                .foregroundStyle(line.error ? Carnet.wrong : Carnet.ink)
                .textSelection(.enabled)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(line.student ? Carnet.ink.opacity(0.08) : Carnet.sheet,
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            if !line.student { Spacer(minLength: 24) }
        }
    }

    private var composer: some View {
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ta question", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($typing)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                Button {
                    let text = draft
                    draft = ""
                    send(text)
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 34))
                }
                .disabled(answering || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Envoyer")
            }
            Text("Le tuteur gratuit répond").font(.caption2).foregroundStyle(Carnet.inkTertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    private func quickHint() { send(ClaudeTutor.QuickAction.hint.prompt) }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !answering else { return }
        // Le premier message porte l'exercice (le même préambule que le Mac).
        let content = history.isEmpty ? StudyPhoneClaude.prompt(trimmed, exercise: exercise, course: course) : trimmed
        history.append((role: "user", content: content))
        lines.append(Line(student: true, text: trimmed))
        answering = true
        let sent = history
        Task { @MainActor in
            do {
                let answer = try await FreeTutor.ask(messages: sent)
                history.append((role: "assistant", content: answer.text))
                answering = false
                // Le bloc ```polymestre (l'indice noté) est pour l'app, pas pour la conversation.
                lines.append(Line(student: false, text: SeriesReview.withoutBlocks(answer.text)))
                Haptics.tap()
            } catch {
                history.removeLast()
                answering = false
                lines.append(Line(student: false, text: error.localizedDescription, error: true))
            }
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
