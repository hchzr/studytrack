import SwiftData
import SwiftUI

/// Ce qu'une session a compté, juste après l'avoir terminée : le temps, par
/// cible, et de quoi cocher tout de suite ce qui a été fait.
///
/// Terminer une session ramenait au chrono vide, avec un message de trois
/// secondes. Or c'est le moment où l'on sait ce qu'on vient de faire : cocher
/// l'exercice, le marquer juste ou à revoir, dire « en fait j'ai fait autre
/// chose ». Le Mac avait ce récapitulatif ; il arrive sur l'iPhone — et
/// « Annuler » retire les sessions enregistrées, pour le cas où l'on a terminé
/// trop tôt.
struct SessionRecapCard: View {
    let totalSeconds: Int
    let parts: [TimerEngine.RecordedPart]
    var endedAt: Date
    /// La cible d'une partie, pour écrire ce qu'on a travaillé.
    var headline: (UUID?, TaskType, UUID?) -> String
    var tint: (UUID?) -> Color
    /// Masquer le récapitulatif (il reste relisible dans le journal).
    var dismiss: () -> Void
    /// Annuler : les sessions enregistrées partent.
    var undo: () -> Void

    @Query(sort: \Course.code) private var courses: [Course]

    /// L'annulation n'est offerte qu'un moment : après, c'est une suppression
    /// du journal, et on ne la prend pas par réflexe.
    private var canUndo: Bool { Date().timeIntervalSince(endedAt) < 120 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ForEach(parts) { part in
                partRow(part)
                if part.id != parts.last?.id { Rectangle().fill(Carnet.rule).frame(height: 1) }
            }
            footer
        }
        .paperSheet()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Session enregistrée, \(DateUtils.durationLabel(seconds: totalSeconds))"))
        // La carte apparaît sous le doigt : VoiceOver ne la trouverait qu'en
        // explorant. On annonce l'essentiel, une fois.
        .onAppear {
            AccessibilityNotification.Announcement(
                String(localized: "Session enregistrée, \(DateUtils.durationLabel(seconds: totalSeconds))")
            ).post()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Carnet.correct)
                .accessibilityHidden(true)
            Text("Session enregistrée")
                .font(Carnet.serif(.headline))
                .foregroundStyle(Carnet.ink)
            Spacer(minLength: 8)
            Text(DateUtils.durationLabel(seconds: totalSeconds))
                .font(Carnet.serif(.headline).monospacedDigit())
                .foregroundStyle(Carnet.ink)
        }
    }

    @ViewBuilder
    private func partRow(_ part: TimerEngine.RecordedPart) -> some View {
        let course = courses.first { $0.id == part.courseID }
        let exercise = course?.allExercises.first { $0.id == part.targetID }
        let item = exercise == nil ? course?.theoryItems.first { $0.id == part.targetID } : nil
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(tint(part.courseID))
                    .frame(width: 3, height: 16)
                    .accessibilityHidden(true)
                Text(course?.displayCode ?? String(localized: "Libre"))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Carnet.ink)
                Text(headline(part.courseID, part.taskType, part.targetID))
                    .font(.callout)
                    .foregroundStyle(Carnet.inkSecondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(DateUtils.durationLabel(seconds: part.seconds))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(Carnet.inkSecondary)
            }
            // Ce qu'on vient de faire, dit tout de suite : l'exercice, ses
            // questions, le verdict. Sans ça, le temps est compté mais rien
            // n'avance dans le cours.
            if let exercise {
                ExerciseQuickMark(exercise: exercise)
                    .padding(.leading, 11)
            } else if let item {
                Toggle("Vu", isOn: Binding(get: { item.isWatched },
                                           set: { item.watchedAt = $0 ? (item.watchedAt ?? Date()) : nil }))
                    .studyCheckbox()
                    .padding(.leading, 11)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if canUndo {
                // Ce que l'annulation défait, dit avant de la toucher : on
                // sait ce qui disparaît du journal.
                Button(String(localized: "Annuler l'enregistrement"), action: undo)
                    .buttonStyle(.plain)
                    .foregroundStyle(Carnet.inkSecondary)
                    .accessibilityHint(String(localized: "Retire la session enregistrée du journal."))
            }
            Spacer(minLength: 8)
            Button("Terminé", action: dismiss)
                .buttonStyle(.paper)
        }
        .font(.subheadline)
        .padding(.top, 2)
    }
}
