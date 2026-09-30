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

/// Ligne compacte : code, nom, résumé des trois pourcentages, anneau.
struct CourseProgressRow: View {
    let course: Course

    var body: some View {
        let progress = ProgressEngine.progress(for: course)
        return HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(hex: course.colorHex))
                .frame(width: 4, height: 40)

            VStack(alignment: .leading, spacing: Layout.tight) {
                HStack(spacing: 6) {
                    Text(course.displayCode).font(.subheadline.weight(.bold))
                    if !course.hasLectures {
                        Pill(text: "sans amphi", color: .secondary)
                    }
                }
                Text(course.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("Théorie \(pct(progress.theoryPercent)) · Exos \(pct(progress.exercisePercent)) · Corr. \(pct(progress.correctionPercent))")
                    .font(.caption)      // résumé de données : un cran au-dessus du plancher
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            ProgressRing(progress: progress.overallPercent,
                         color: Color(hex: course.colorHex),
                         size: 46,
                         lineWidth: 5)
        }
        .contentShape(Rectangle())
    }

    private func pct(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
