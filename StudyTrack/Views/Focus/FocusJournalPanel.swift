import SwiftUI
import SwiftData

/// Le journal du jour : combien, sur quoi, et chaque session.
///
/// Une seule passe sur les sessions : la version précédente les filtrait six
/// fois et reconstruisait la série à chaque battement du chrono.
struct FocusJournalPanel: View {
    var onAddManual: () -> Void
    var onShowHistory: () -> Void

    @Environment(AppContainer.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \StudySession.startedAt, order: .reverse) private var sessions: [StudySession]

    @State private var sessionToDelete: StudySession?

    var body: some View {
        let calendar = Calendar.current
        let today = sessions.filter { calendar.isDateInToday($0.startedAt) }
        let total = today.reduce(0) { $0 + $1.durationSeconds }
        let byType = Dictionary(grouping: today, by: \.taskType)

        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            HStack(spacing: Layout.block) {
                StatCard(icon: "clock.fill",
                         value: DateUtils.hoursLabel(seconds: total),
                         title: "aujourd'hui",
                         tint: Theme.accent)
                StatCard(icon: "list.bullet",
                         value: "\(today.count)",
                         title: today.count > 1 ? "sessions" : "session")
            }

            if today.isEmpty {
                EmptyCard(icon: "clock.badge.questionmark",
                          title: "Rien d'enregistré aujourd'hui",
                          message: "Lance le chrono, ou ajoute une session que tu as faite sans lui.",
                          actionTitle: "Ajouter une session passée",
                          action: onAddManual)
            } else {
                Card(title: "Répartition", icon: "chart.bar.fill") {
                    VStack(alignment: .leading, spacing: Layout.block) {
                        ForEach(TaskType.choices) { type in
                            if let items = byType[type], !items.isEmpty {
                                let seconds = items.reduce(0) { $0 + $1.durationSeconds }
                                LabeledProgress(title: type.label,
                                                progress: CourseProgress.ratio(seconds, max(total, 1)),
                                                color: type.tint,
                                                countLabel: DateUtils.hoursLabel(seconds: seconds))
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: Layout.control) {
                    SectionHeader(title: "Sessions du jour", trailing: "\(today.count)")
                    Card {
                        VStack(spacing: 0) {
                            ForEach(today) { session in
                                row(session)
                                if session.id != today.last?.id {
                                    Divider().padding(.leading, 44)
                                }
                            }
                        }
                    }
                }

                Button(action: onAddManual) {
                    Label("Ajouter une session passée", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Layout.snug)
                }
                .buttonStyle(.bordered)
            }

            Button(action: onShowHistory) {
                Label("Tout l'historique", systemImage: "clock.arrow.circlepath")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
        }
        .confirmationDialog("Supprimer cette session ?",
                            isPresented: Binding(get: { sessionToDelete != nil },
                                                 set: { if !$0 { sessionToDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) {
                if let session = sessionToDelete {
                    context.delete(session)
                    try? context.save()
                    WidgetSnapshotWriter.refresh(context: context, settings: app.settings)
                    Haptics.removed()
                }
                sessionToDelete = nil
            }
            Button("Annuler", role: .cancel) { sessionToDelete = nil }
        } message: {
            Text("Son temps sera retiré de tes statistiques.")
        }
    }

    private func row(_ session: StudySession) -> some View {
        HStack(spacing: Layout.block) {
            Image(systemName: session.taskType.icon)
                .font(.subheadline)
                .foregroundStyle(session.taskType.tint.badgeInk)
                .frame(width: 32, height: 32)
                .background(session.taskType.tint.badgeFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(session.course?.displayCode ?? "Sans cours")
                    .font(.subheadline.weight(.semibold))
                Text(subtitle(session))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Layout.inline)
            Text(session.durationLabel)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
            Menu {
                Button(role: .destructive) {
                    sessionToDelete = session
                } label: {
                    Label("Supprimer", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: Layout.minTouch)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Actions pour la session de \(DateUtils.time.string(from: session.startedAt))")
        }
        .padding(.vertical, Layout.tight)
        .contextMenu {
            Button(role: .destructive) {
                sessionToDelete = session
            } label: {
                Label("Supprimer", systemImage: "trash")
            }
        }
    }

    /// « 14:20 · Exercices · Exercice 3.2 » — la cible n'apparaît que si elle est connue.
    private func subtitle(_ session: StudySession) -> String {
        var parts = [DateUtils.time.string(from: session.startedAt), session.taskType.label]
        if let target = session.targetLabel { parts.append(target) }
        if session.isManual { parts.append("saisie") }
        return parts.joined(separator: " · ")
    }
}

/// Ajouter une session faite sans le chrono.
///
/// C'était un segment de Focus, au même rang que le chrono. C'est un geste rare
/// — on a oublié de lancer le chrono, on a travaillé à la bibliothèque — et il a
/// sa place dans une feuille, avec les durées usuelles à un toucher.
struct ManualSessionSheet: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Course.code) private var courses: [Course]

    @State private var courseID: UUID?
    @State private var taskType: TaskType = .exercise
    @State private var minutes = 45
    @State private var date = Date().addingTimeInterval(-45 * 60)
    @State private var note = ""

    private static let presets = [25, 45, 60, 90, 120]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Cours", selection: $courseID) {
                        Text("Sans cours").tag(UUID?.none)
                        ForEach(courses.filter(\.isTracked)) { course in
                            Text("\(course.displayCode) — \(course.name)").tag(UUID?.some(course.id))
                        }
                    }
                    Picker("Type", selection: $taskType) {
                        ForEach(TaskType.choices) { type in
                            Label(type.label, systemImage: type.icon).tag(type)
                        }
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: Layout.block) {
                        HStack {
                            Text("Durée")
                            Spacer()
                            Text(DateUtils.durationLabel(seconds: minutes * 60))
                                .font(.body.weight(.semibold).monospacedDigit())
                                .contentTransition(.numericText(value: Double(minutes)))
                        }
                        HStack(spacing: Layout.inline) {
                            ForEach(Self.presets, id: \.self) { preset in
                                Button {
                                    withAnimation(Motion.snappy) { minutes = preset }
                                    Haptics.tap()
                                } label: {
                                    Text(preset < 60 ? "\(preset)" : DateUtils.durationLabel(seconds: preset * 60))
                                        .font(.subheadline.weight(.medium).monospacedDigit())
                                        .frame(maxWidth: .infinity, minHeight: 34)
                                        .background(minutes == preset ? Theme.accent.badgeFill : Color(.tertiarySystemFill),
                                                    in: Capsule())
                                        .foregroundStyle(minutes == preset ? Theme.accent.badgeInk : Color.primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Stepper("Ajuster de 5 min", value: $minutes, in: 5...600, step: 5)
                    DatePicker("Commencée", selection: $date, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                }

                Section {
                    TextField("Note (optionnel)", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .navigationTitle("Session passée")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ajouter") { save() }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.large])
    }

    private func save() {
        let session = StudySession(course: courses.first { $0.id == courseID },
                                   taskType: taskType,
                                   startedAt: date,
                                   durationSeconds: minutes * 60,
                                   isManual: true,
                                   note: note)
        context.insert(session)
        try? context.save()
        WidgetSnapshotWriter.refresh(context: context, settings: app.settings)
        Haptics.success()
        dismiss()
    }
}

/// Les durées du cycle Pomodoro.
///
/// Un seul formulaire, présenté depuis le chrono et repris dans les réglages :
/// deux copies finiraient par diverger.
struct PomodoroSettingsForm: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Section {
            Stepper(value: $settings.pomodoroFocusMinutes, in: 5...120, step: 5) {
                LabeledContent("Bloc de travail", value: "\(settings.pomodoroFocusMinutes) min")
            }
            Stepper(value: $settings.pomodoroBreakMinutes, in: 1...30) {
                LabeledContent("Pause courte", value: "\(settings.pomodoroBreakMinutes) min")
            }
            Stepper(value: $settings.pomodoroLongBreakMinutes, in: 5...60, step: 5) {
                LabeledContent("Pause longue", value: "\(settings.pomodoroLongBreakMinutes) min")
            }
            Stepper(value: $settings.pomodoroLongBreakEvery, in: 2...8) {
                LabeledContent("Pause longue tous les", value: "\(settings.pomodoroLongBreakEvery) blocs")
            }
        } header: {
            Text("Cycle")
        } footer: {
            Text("Le chrono compte le travail seulement : pendant une pause, il s'arrête, et la pause décompte à part.")
        }

        Section {
            Toggle("Relancer le bloc après la pause", isOn: $settings.pomodoroAutoStartFocus)
            Toggle("Démarrer en Pomodoro", isOn: $settings.pomodoroDefault)
        } footer: {
            Text("Sans relance automatique, le bloc suivant attend que tu appuies : une pause qui déborde ne se transforme pas en faux travail.")
        }
    }
}

struct PomodoroSettingsSheet: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                PomodoroSettingsForm(settings: app.settings)
            }
            .navigationTitle("Pomodoro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        // Les nouvelles durées valent pour le bloc en cours : la
                        // fin de bloc et sa notification sont recalculées.
                        app.focus.settingsDidChange()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
