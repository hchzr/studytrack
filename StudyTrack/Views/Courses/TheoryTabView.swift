import SwiftUI
import SwiftData

/// Théorie : décomposition par vidéos, durée à regarder par semaine.
struct TheoryTabView: View {
    let course: Course

    @Environment(\.modelContext) private var context
    @State private var selectedVideo: TheoryItem?
    @State private var showingAdd = false

    private var week: Int { course.currentWeek }
    private var weekVideos: [TheoryItem] {
        course.sortedTheoryItems.filter { $0.plannedWeek == week }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            weekCard

            if course.theoryItems.isEmpty {
                EmptyCard(icon: "play.rectangle",
                          title: "Aucune théorie",
                          message: "Ajoute les vidéos de théorie (1.1, 1.2…) avec leur durée pour suivre ta progression.",
                          actionTitle: "Ajouter un élément de théorie") {
                    showingAdd = true
                }
            } else {
                ForEach(course.theorySections, id: \.self) { section in
                    sectionCard(section)
                }
            }
        }
        .sheet(item: $selectedVideo) { video in
            VideoDetailSheet(video: video)
        }
        .sheet(isPresented: $showingAdd) {
            AddVideoSheet(course: course)
        }
    }

    // MARK: Semaine

    /// La semaine en une ligne : ce qu'il reste, et une barre.
    ///
    /// La carte affichait la même information trois fois — un anneau à 0 %, une
    /// barre à 0 % et « 0/2 » — plus deux durées côte à côte. Il reste la seule
    /// chose qu'on vient chercher ici : combien de temps de vidéo il reste à
    /// regarder cette semaine, et où l'on en est.
    private var weekCard: some View {
        let total = weekVideos.reduce(0) { $0 + $1.durationSeconds }
        let remaining = weekVideos.filter { !$0.isWatched }.reduce(0) { $0 + $1.durationSeconds }
        let watched = weekVideos.filter(\.isWatched).count
        return VStack(alignment: .leading, spacing: Layout.block) {
            HStack(alignment: .firstTextBaseline) {
                Text("Cette semaine")
                    .font(.headline)
                Text(course.isTermRunning ? "S\(week)" : "hors semestre")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showingAdd = true
                } label: {
                    Label("Ajouter", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .accessibilityLabel("Ajouter un élément de théorie")
            }
            .padding(.horizontal, Layout.micro)

            if weekVideos.isEmpty {
                Text(course.isTermRunning
                     ? "Rien de planifié pour la semaine \(week)."
                     : "Le semestre n'est pas en cours : le plan hebdomadaire est en pause.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Layout.micro)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Card {
                    VStack(alignment: .leading, spacing: Layout.control) {
                        HStack(alignment: .firstTextBaseline) {
                            if remaining == 0 {
                                Label("Tout est vu", systemImage: "checkmark.circle.fill")
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(Color.green.accessibleInk)
                            } else {
                                Text(DateUtils.durationLabel(seconds: remaining))
                                    .font(.title3.weight(.bold).monospacedDigit())
                                Text("à regarder sur \(DateUtils.durationLabel(seconds: total))")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: Layout.inline)
                            Text("\(watched)/\(weekVideos.count)")
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                        }
                        ProgressBar(progress: CourseProgress.ratio(watched, max(weekVideos.count, 1)),
                                    color: TaskType.video.tint)
                    }
                }
            }
        }
    }

    // MARK: Section de théorie

    private func sectionCard(_ section: Int) -> some View {
        let videos = course.sortedTheoryItems.filter { $0.sectionNumber == section }
        let watched = videos.filter(\.isWatched).count
        return Card(title: "Section \(section)",
                    icon: "rectangle.stack.fill",
                    trailing: "\(watched)/\(videos.count)") {
            VStack(spacing: 0) {
                ForEach(videos) { video in
                    VideoRow(video: video,
                             isCurrentWeek: video.plannedWeek == week,
                             onToggleWatched: { toggleWatched(video) },
                             onOpen: { selectedVideo = video })
                    if video.id != videos.last?.id {
                        Divider().padding(.leading, 56)
                    }
                }
            }
        }
    }

    private func toggleWatched(_ video: TheoryItem) {
        if video.isWatched {
            video.watchedAt = nil
            video.summarizedAt = nil
        } else {
            video.watchedAt = Date()
        }
        // Pas de vibration ici : `CheckCircleButton` a déjà la sienne.
        try? context.save()
    }
}

/// Ligne de vidéo : coche, numéro, titre, durée. Le reste est dans la feuille.
struct VideoRow: View {
    let video: TheoryItem
    let isCurrentWeek: Bool
    var onToggleWatched: () -> Void
    var onOpen: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            CheckCircleButton(isOn: video.isWatched,
                              tint: TaskType.video.tint,
                              label: "Marquer \(video.displayNumber) vue",
                              action: onToggleWatched)

            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: Layout.tight) {
                    HStack(spacing: 6) {
                        Text(video.displayNumber)
                            .font(.subheadline.weight(.semibold))
                        if isCurrentWeek {
                            Pill(text: "cette semaine", color: TaskType.video.tint)
                        }
                    }
                    if !video.title.isEmpty {
                        Text(video.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    HStack(spacing: 10) {
                        if let watchedAt = video.watchedAt {
                            IconLabel(icon: "eye.fill",
                                      text: "Vu \(DateUtils.shortDay.string(from: watchedAt))",
                                      tint: .green)
                        }
                        if let summarizedAt = video.summarizedAt {
                            IconLabel(icon: "doc.text.fill",
                                      text: "Résumé \(DateUtils.shortDay.string(from: summarizedAt))",
                                      tint: .teal)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .trailing, spacing: 4) {
                // Une lecture ou un chapitre n'a pas de durée : ne pas écrire « 0 min ».
                if video.hasDuration {
                    Text(video.durationLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if video.isSummarized {
                    Image(systemName: "doc.text.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.teal.accessibleMark)
                }
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.leading, 8)
        }
        .padding(.vertical, 2)
    }
}

/// Détail d'une vidéo : dates, résumé, suppression.
struct VideoDetailSheet: View {
    @Bindable var video: TheoryItem

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var app

    @State private var summary = ""
    @State private var plannedWeek = 1
    @State private var durationMinutes = 0

    var body: some View {
        NavigationStack {
            Form {
                Section(video.kind.label) {
                    DetailRow(icon: "number", label: "Numéro", value: video.number, tint: video.kind.tint)
                    if !video.title.isEmpty {
                        DetailRow(icon: "text.alignleft", label: "Titre", value: video.title)
                    }
                    if video.hasDuration {
                        DetailRow(icon: "clock", label: "Durée", value: video.durationLabel)
                    }
                    if let course = video.course {
                        DetailRow(icon: "books.vertical", label: "Cours", value: course.code)
                    }
                }

                Section("Suivi") {
                    DetailRow(icon: "eye.fill",
                              label: "Vu le",
                              value: video.watchedAt.map { DateUtils.shortDay.string(from: $0) } ?? "—",
                              tint: .green)
                    DetailRow(icon: "doc.text.fill",
                              label: "Résumé le",
                              value: video.summarizedAt.map { DateUtils.shortDay.string(from: $0) } ?? "—",
                              tint: .teal)
                    Button {
                        if video.isWatched {
                            video.watchedAt = nil
                            video.summarizedAt = nil
                        } else {
                            video.watchedAt = Date()
                        }
                        Haptics.tap()
                        try? context.save()
                    } label: {
                        Label(video.isWatched ? "Annuler le visionnage" : "Marquer comme vue",
                              systemImage: video.isWatched ? "arrow.uturn.backward" : "checkmark.circle.fill")
                    }
                    .disabled(false)
                }

                Section {
                    // Enregistrée au changement : un bouton « Enregistrer la
                    // semaine » séparé se laissait oublier, et la valeur affichée
                    // n'était alors plus celle qui comptait.
                    Stepper("Semaine planifiée : \(plannedWeek)", value: $plannedWeek, in: 1...30)
                        .onChange(of: plannedWeek) { _, newValue in
                            guard video.plannedWeek != newValue else { return }
                            video.plannedWeek = newValue
                            try? context.save()
                        }
                    if video.kind.hasDuration {
                        Stepper("Durée : \(durationMinutes) min", value: $durationMinutes, in: 0...300, step: 5)
                            .onChange(of: durationMinutes) { _, newValue in
                                guard video.durationMinutes != newValue else { return }
                                video.durationSeconds = newValue * 60
                                try? context.save()
                            }
                    }
                    if let url = URL(string: video.urlString), !video.urlString.isEmpty {
                        Link(destination: url) {
                            Label("Ouvrir le support", systemImage: "safari")
                        }
                    }
                } header: {
                    Text("Planification")
                } footer: {
                    Text("La semaine détermine « à regarder cette semaine » et les pourcentages hebdomadaires.")
                }

                Section("Résumé") {
                    TextEditor(text: $summary)
                        .frame(minHeight: 140)
                }

                Section {
                    Button {
                        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                        video.summaryText = trimmed
                        if !trimmed.isEmpty || video.isSummarized {
                            video.summarizedAt = Date()
                        }
                        if video.watchedAt == nil { video.watchedAt = Date() }
                        Haptics.success()
                        try? context.save()
                        dismiss()
                    } label: {
                        Label("Enregistrer le résumé", systemImage: "checkmark.circle.fill")
                    }

                    Button {
                        app.router.startFocus(courseID: video.course?.id,
                                              courseCode: video.course?.code ?? "",
                                              taskType: .theory,
                                              label: "\(video.course?.code ?? "") · \(video.displayNumber)")
                        dismiss()
                    } label: {
                        Label("Démarrer un chrono sur cet élément", systemImage: "timer")
                    }

                    Button(role: .destructive) {
                        context.delete(video)
                        try? context.save()
                        dismiss()
                    } label: {
                        Label("Supprimer cet élément", systemImage: "trash")
                    }
                }
            }
            .navigationTitle(video.displayNumber)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
            .onAppear {
                summary = video.summaryText ?? ""
                plannedWeek = video.plannedWeek
                durationMinutes = video.durationMinutes
            }
        }
    }
}

/// Ajout rapide d'une vidéo depuis l'onglet Théorie.
struct AddVideoSheet: View {
    let course: Course

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var kind: TheoryKind = .video
    @State private var number = ""
    @State private var title = ""
    @State private var minutes = 45
    @State private var week = 1
    @State private var section = 1
    @State private var useAutoSection = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Support", selection: $kind) {
                        ForEach(TheoryKind.allCases) { value in
                            Label(value.label, systemImage: value.icon).tag(value)
                        }
                    }
                    TextField("Numéro (ex : 1.4)", text: $number)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Titre", text: $title)
                    if kind.hasDuration {
                        Stepper("Durée : \(minutes) min", value: $minutes, in: 1...300, step: 5)
                    }
                } header: {
                    Text("Support")
                } footer: {
                    Text(kind.hasDuration
                         ? "La durée entre dans le calcul du temps de théorie à faire cette semaine."
                         : "\(kind.label) n'a pas de durée : elle n'entre pas dans le calcul du temps de théorie.")
                }
                Section {
                    Stepper("Semaine : \(week)", value: $week, in: 1...30)
                    Toggle("Déduire la section du numéro", isOn: $useAutoSection)
                    if !useAutoSection {
                        Stepper("Section : \(section)", value: $section, in: 1...40)
                    }
                } header: {
                    Text("Planification")
                } footer: {
                    Text("La semaine sert au calcul « à regarder cette semaine ». Par défaut, la section est le préfixe du numéro (1.4 → section 1).")
                }
            }
            .navigationTitle("Nouvel élément de théorie")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ajouter") { add() }
                        .disabled(number.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { week = course.currentWeek }
        }
    }

    private func add() {
        let value = number.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        let resolvedSection = useAutoSection
            ? (Int(value.split(separator: ".").first ?? "1") ?? 1)
            : section
        let item = TheoryItem(course: course,
                              sectionNumber: resolvedSection,
                              number: value,
                              title: title,
                              kind: kind,
                              // Un support sans durée n'en invente pas une.
                              durationSeconds: kind.hasDuration ? minutes * 60 : 0,
                              plannedWeek: week,
                              sortOrder: course.theoryItems.count)
        context.insert(item)
        try? context.save()
        Haptics.success()
        dismiss()
    }
}
