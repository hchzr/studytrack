import SwiftUI

// MARK: - Ligne « à faire »

/// Une ligne = une chose. Coche à gauche, ce qu'il y a à faire au centre, le
/// chrono à droite — sur le papier, sans cadre.
struct TodoRow: View {
    let todo: StudyTodo
    var isDone: Bool = false
    var onComplete: () -> Void
    var onOpen: () -> Void
    var onStart: () -> Void

    var body: some View {
        let tint = Carnet.tint(todo.colorHex)
        HStack(spacing: 0) {
            CheckCircleButton(isOn: isDone,
                              tint: tint,
                              label: "Marquer \(todo.title) terminé",
                              action: onComplete)
                .padding(.leading, 4)

            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(MathMarkup.plain(todo.title))
                        .font(.body)
                        .foregroundStyle(Carnet.ink)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(todo.courseCode)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(tint)
                        Text(todo.detail)
                            .font(.footnote)
                            .foregroundStyle(Carnet.inkSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let duration = todo.durationLabel {
                Text(duration)
                    .font(Carnet.mono(.caption))
                    .foregroundStyle(Carnet.inkSecondary)
            }

            Button(action: onStart) {
                Image(systemName: "play.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Carnet.ink)
                    .frame(width: 30, height: 30)
                    .background(Carnet.sheetRaised, in: Circle())
                    .frame(width: Layout.minTouch, height: Layout.minTouch)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Démarrer le chrono sur \(todo.title)")
            .padding(.trailing, 4)
        }
        .padding(.vertical, 5)
    }
}

// MARK: - Ligne de progression d'un cours

