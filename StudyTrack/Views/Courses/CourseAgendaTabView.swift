import SwiftUI
import SwiftData

/// Agenda d'un cours : évaluations, séances, tâches.
struct CourseAgendaTabView: View {
    let course: Course

    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var app

    /// Toutes les sessions planifiées ; la carte filtre sur ce cours.
    @Query(sort: \PlannedSession.startsAt) private var plannedSessions: [PlannedSession]
    @State private var showingPlan = false
    @State private var showingAddExam = false
    @State private var editingExam: Exam?
    @State private var editingPastExam: PastExam?
    @State private var creatingPastExam = false
    @State private var sessionToDelete: PlannedSession?

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            examsCard
            pastExamsCard
            plannedCard
            sessionsCard
            tasksCard
        }
        .sheet(isPresented: $showingPlan) {
            PlanSessionSheet(course: course)
        }
        .sheet(isPresented: $showingAddExam) {
            ExamFormSheet(course: course)
        }
        .sheet(item: $editingExam) { exam in
            ExamFormSheet(course: course, exam: exam)
        }
        .sheet(item: $editingPastExam) { past in
            PastExamFormSheet(course: course, exam: past)
        }
        .sheet(isPresented: $creatingPastExam) {
            PastExamFormSheet(course: course, exam: nil)
        }
        .confirmationDialog("Supprimer cette session ?",
                            isPresented: Binding(get: { sessionToDelete != nil },
                                                 set: { if !$0 { sessionToDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) {
                if let session = sessionToDelete { delete(session) }
                sessionToDelete = nil
            }
            Button("Annuler", role: .cancel) { sessionToDelete = nil }
        } message: {
            Text("La session est aussi retirée du calendrier système et son rappel annulé.")
        }
    }

    /// Sessions d'étude personnelles, avec écriture dans le calendrier système.
    private var plannedCard: some View {
        let mine = plannedSessions.filter { $0.course?.id == course.id }
        return Card(title: "Sessions d'étude",
                    icon: "calendar.badge.plus",
                    trailing: mine.isEmpty ? nil : "\(mine.count)") {
            VStack(alignment: .leading, spacing: 12) {
                if mine.isEmpty {
                    Text("Aucune session planifiée pour ce cours.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(mine) { session in
                            HStack(spacing: 10) {
                                Image(systemName: "timer")
                                    .foregroundStyle(Theme.accent.accessibleMark)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.title)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    Text("\(DateUtils.shortDay.string(from: session.startsAt)) · \(DateUtils.time.string(from: session.startsAt)) · \(session.durationLabel)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                if !session.externalCalendarEventID.isEmpty {
                                    Image(systemName: "calendar")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .accessibilityLabel("Présente dans le calendrier système")
                                }
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button(role: .destructive) {
                                    sessionToDelete = session
                                } label: {
                                    Label("Supprimer", systemImage: "trash")
                                }
                            }
                        }
                    }
                }

                Button {
                    showingPlan = true
                } label: {
                    Label("Planifier une session", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// Supprime la session **et** son événement de calendrier **et** son rappel,
    /// pour ne rien laisser d'orphelin ni dans l'agenda ni dans les notifications.
    private func delete(_ session: PlannedSession) {
        PlannedSessionActions.delete(session, context: context, app: app)
    }

    /// Les sujets passés : ce qu'on travaille pour réviser.
    private var pastExamsCard: some View {
        Card(title: "Annales", icon: "archivebox.fill",
             trailing: course.pastExams.isEmpty ? nil : progress.label) {
            VStack(alignment: .leading, spacing: Layout.block) {
                if course.pastExams.isEmpty {
                    Text("Aucun sujet passé. Ajoute les annales de ton cours : ce sont les meilleurs exercices de révision.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    if let first = progress.pendingYears.first {
                        Label("À travailler en priorité : \(first)",
                              systemImage: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(Color.orange.accessibleInk)
                    }

                    VStack(spacing: 0) {
                        ForEach(course.sortedPastExams) { past in
                            Button {
                                editingPastExam = past
                            } label: {
                                pastExamRow(past)
                            }
                            .buttonStyle(.plain)
                            if past.id != course.sortedPastExams.last?.id {
                                Divider()
                            }
                        }
                    }
                }

                Button {
                    creatingPastExam = true
                } label: {
                    Label("Ajouter une annale", systemImage: "plus.circle")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func pastExamRow(_ past: PastExam) -> some View {
        HStack(spacing: Layout.control) {
            Image(systemName: past.kind.icon)
                .foregroundStyle(past.kind.color.accessibleMark)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(past.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(past.statusLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Layout.inline)
            ConfidenceDot(level: past.confidence)
            if past.url != nil {
                Image(systemName: "arrow.up.right.square")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, Layout.snug)
        .contentShape(Rectangle())
    }

    private var progress: PastExamProgress.Summary {
        PastExamProgress.summary(course.pastExams.map { (year: $0.year, worked: $0.isWorked) })
    }

    private var examsCard: some View {
        Card(title: "Évaluations", icon: "graduationcap.fill",
             trailing: course.exams.isEmpty ? nil : "\(course.exams.count)") {
            VStack(alignment: .leading, spacing: 12) {
            if course.sortedExams.isEmpty {
                Text("Aucune évaluation enregistrée. Ajoute le midterm et l'examen final pour les voir dans l'agenda et recevoir un rappel.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Le plan se cale sur la **prochaine** échéance : c'est elle qui
                // décide de ce qu'il faut avoir fini, et quand.
                if let next = course.nextExam {
                    NavigationLink {
                        RevisionPlanView(course: course)
                    } label: {
                        HStack(spacing: Layout.control) {
                            Image(systemName: "target")
                                .foregroundStyle(Theme.accent.accessibleMark)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Plan de révision")
                                    .font(.subheadline.weight(.medium))
                                Text("Jusqu'à \(next.title) · \(DateUtils.countdownLabel(to: next.date))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: Layout.inline)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.vertical, Layout.snug)
                }

                VStack(spacing: 0) {
                    ForEach(course.sortedExams) { exam in
                        Button {
                            editingExam = exam
                        } label: {
                        HStack(spacing: 12) {
                            Image(systemName: exam.kind.icon)
                                .foregroundStyle(exam.kind.color.accessibleMark)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(exam.title).font(.subheadline.weight(.medium))
                                // Une seule chaîne : deux textes séparés par un
                                // espacement donnaient « octobre  · SG1 ».
                                Text([DateUtils.fullDayLabel(exam.date), exam.location]
                                        .filter { !$0.isEmpty }
                                        .joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: Layout.tight) {
                                Text(DateUtils.countdownLabel(to: exam.date))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(exam.isPast ? Color.secondary : exam.kind.color.accessibleInk)
                                if let weight = exam.weightLabel {
                                    Text(weight).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Modifier l'évaluation")
                    }
                }
            }

            Button {
                showingAddExam = true
            } label: {
                Label("Ajouter une évaluation", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderless)
            }
        }
    }

    private var sessionsCard: some View {
        let events = course.linkedEvents.sorted { $0.startsAt < $1.startsAt }
        let lectures = events.filter(\.isLecture)
        return Card(title: "Séances de cours", icon: "building.columns.fill",
                    trailing: "\(lectures.filter(\.isAttended).count)/\(lectures.count) suivies") {
            VStack(alignment: .leading, spacing: 12) {
                if events.isEmpty {
                    Text("Aucune séance. Importe ton horaire (.ics) depuis l'onglet Agenda ou le profil.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Marque ta présence en amphi : ces heures entrent dans le temps réel comparé à la charge EPFL.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(spacing: 0) {
                        ForEach(events.prefix(12)) { event in
                            HStack(spacing: 10) {
                                Image(systemName: event.kind.icon)
                                    .foregroundStyle(event.kind.color.accessibleMark)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.title)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    Text("\(DateUtils.shortDay.string(from: event.startsAt)) · \(DateUtils.time.string(from: event.startsAt)) · \(event.durationLabel)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                if event.isLecture {
                                    CheckCircleButton(isOn: event.isAttended,
                                                      tint: .blue,
                                                      label: "Marquer la présence à \(event.title)") {
                                        event.isAttended.toggle()
                                        try? context.save()
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    if events.count > 12 {
                        Text("+ \(events.count - 12) autres séances")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var tasksCard: some View {
        Card(title: "Tâches liées", icon: "checklist",
             trailing: "\(course.linkedTasks.filter { !$0.isDone }.count) ouvertes") {
            let tasks = course.linkedTasks.sorted {
                ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture)
            }
            if tasks.isEmpty {
                Text("Aucune tâche liée à ce cours. Ouvre l'onglet Tâches pour en synchroniser.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(tasks) { task in
                        HStack(spacing: 10) {
                            CheckCircleButton(isOn: task.isDone,
                                              tint: .teal,
                                              label: "Terminer \(task.title)") {
                                task.isDone.toggle()
                                task.updatedAt = Date()
                                try? context.save()
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.title)
                                    .font(.subheadline)
                                    .strikethrough(task.isDone)
                                    .lineLimit(2)
                                HStack(spacing: 6) {
                                    Image(systemName: task.provider.icon).font(.caption2)
                                    Text(task.provider.label)
                                    if let due = task.dueDate {
                                        Text("· \(DateUtils.shortDay.string(from: due))")
                                    }
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            if task.isOverdue {
                                Pill(text: "en retard", color: .red)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }
}
