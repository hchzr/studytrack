import SwiftUI

/// L'énoncé d'un exercice, tel qu'il est imprimé : la bande du PDF de la série
/// qui lui correspond (formules et figures comprises), sinon le texte lu à
/// l'import, sinon un lien vers l'énoncé d'origine.
///
/// Sert au chrono (« exercice par exercice ») et à la fiche d'un exercice.
struct ExerciseStatementView: View {
    let exercise: Exercise
    /// Ouvre l'énoncé d'origine quand rien ne peut être montré ici.
    var onOpenLink: ((BrowsedLink) -> Void)? = nil

    private enum Phase: Equatable {
        case loading
        case images([UIImage])
        case unavailable
    }

    @State private var phase: Phase = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch phase {
            case .loading:
                if !exercise.statement.isEmpty {
                    statementText
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Lecture de l'énoncé…")
                            .font(.footnote)
                            .foregroundStyle(Carnet.inkSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 60)
                }
            case .images(let images):
                VStack(spacing: 0) {
                    ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                        Image(uiImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                    }
                }
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Carnet.rule, lineWidth: 1))
                .accessibilityElement()
                .accessibilityLabel(exercise.statement.isEmpty
                                    ? "Énoncé de l'\(exercise.displayNumber.lowercased()), tel qu'imprimé"
                                    : exercise.statement)
            case .unavailable:
                if !exercise.statement.isEmpty {
                    statementText
                } else {
                    Text("Pas d'énoncé lisible ici pour cet exercice.")
                        .font(.footnote)
                        .foregroundStyle(Carnet.inkSecondary)
                }
                if let link = ExerciseLinks.links(for: exercise).first, let onOpenLink {
                    Button { onOpenLink(link) } label: {
                        Label(link.title, systemImage: link.icon)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Carnet.ink)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task(id: exercise.id) { await load() }
    }

    private var statementText: some View {
        MathText(exercise.statement, font: .system(.body, design: .serif))
            .foregroundStyle(Carnet.ink)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func load() async {
        phase = .loading
        guard let series = exercise.series, SeriesPDFStore.shared.hasDocument(for: series) else {
            phase = .unavailable
            return
        }
        do {
            let images = try await SeriesPDFStore.shared.statementImages(for: exercise, width: 420)
            phase = images.isEmpty ? .unavailable : .images(images)
        } catch {
            phase = .unavailable
        }
    }
}
