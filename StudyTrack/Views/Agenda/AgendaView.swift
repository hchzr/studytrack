import SwiftUI
import SwiftData

/// Entrée unifiée de l'agenda (évaluations + calendrier + sessions + tâches).
struct AgendaEntry: Identifiable {
    let id: String
    let date: Date
    let endDate: Date?
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let kind: AgendaItemKind
    /// L'objet d'origine, pour les actions de ligne (supprimer, présence…).
    var plannedSession: PlannedSession? = nil
    var task: LinkedTask? = nil
    var event: LinkedCalendarEvent? = nil
    var exam: Exam? = nil

    /// Une tâche a une échéance, pas une heure : elle se range en tête de journée.
    /// Une évaluation datée à minuit pile n'a pas d'heure connue non plus.
    var isAllDay: Bool {
        if kind == .task { return true }
        if kind == .exam {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            return parts.hour == 0 && parts.minute == 0
        }
        return false
    }
}

/// Ce que l'agenda montre. Chaque famille se masque d'un tap.
struct AgendaFilter: Equatable {
    var lectures = true
    var exams = true
    var sessions = true
    var tasks = true

    var isEverything: Bool { lectures && exams && sessions && tasks }

    func allows(_ entry: AgendaEntry) -> Bool {
        switch entry.kind {
        case .calendar: return lectures
        case .exam: return exams
        case .planned: return sessions
        case .task: return tasks
        }
    }
}

/// Onglet Agenda : une semaine à balayer, la journée choisie en détail, et ce
/// qui vient ensuite.
///
/// La version précédente était une liste plate « des 30 prochains jours » : ni
/// hier, ni la semaine d'un coup d'œil, ni le moyen de sauter à mardi. La bande de
/// semaine règle les trois — et une pastille sous chaque jour dit s'il y a quelque
/// chose avant même de le toucher.
struct AgendaView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var app

    @Query(sort: \Course.code) private var courses: [Course]
    @Query(sort: \Exam.date) private var exams: [Exam]
    @Query(sort: \PlannedSession.startsAt) private var plannedSessions: [PlannedSession]
    @Query(sort: \LinkedTask.dueDate) private var tasks: [LinkedTask]
    @Query(sort: \LinkedCalendarEvent.startsAt) private var events: [LinkedCalendarEvent]

    @State private var selectedDay = DateUtils.startOfDay(Date())
    @State private var weekStart = DateUtils.startOfWeek(Date())
    @State private var filter = AgendaFilter()
    @State private var showingPlan = false
    @State private var syncMessage: String?
    @State private var isSyncing = false
    @State private var sessionToDelete: PlannedSession?
    @State private var editingExam: Exam?

    private let calendar = Calendar.current

    // MARK: Données

    /// Toutes les entrées de la fenêtre utile : de la semaine affichée à 120 jours.
    private var allEntries: [AgendaEntry] {
        let start = min(weekStart, DateUtils.startOfDay(Date()))
        let end = DateUtils.addDays(120, to: max(weekStart, Date()))
        var result: [AgendaEntry] = []

        for exam in exams where exam.date >= start && exam.date <= end {
            result.append(AgendaEntry(
                id: "exam-\(exam.id)",
                date: exam.date,
                endDate: nil,
                title: exam.title,
                subtitle: [exam.course?.displayCode, exam.location.isEmpty ? nil : exam.location, exam.weightLabel]
                    .compactMap { $0 }.joined(separator: " · "),
                icon: exam.kind.icon,
                color: exam.kind.color,
                kind: .exam,
                exam: exam))
        }

        for session in plannedSessions where session.startsAt >= start && session.startsAt <= end {
            result.append(AgendaEntry(
                id: "planned-\(session.id)",
                date: session.startsAt,
                endDate: session.endsAt,
                title: session.title,
                subtitle: [session.course?.displayCode,
                           session.location.isEmpty ? nil : session.location,
                           session.isGroupSession ? session.groupName : nil]
                    .compactMap { $0 }.joined(separator: " · "),
                icon: "timer",
                color: .indigo,
                kind: .planned,
                plannedSession: session))
        }

        for event in events where event.startsAt >= start && event.startsAt <= end {
            result.append(AgendaEntry(
                id: "event-\(event.id)",
                date: event.startsAt,
                endDate: event.endsAt,
                title: event.title,
                subtitle: eventSubtitle(event),
                icon: event.kind.icon,
                color: event.course.map { Color(hex: $0.colorHex) } ?? event.kind.color,
                kind: .calendar,
                event: event))
        }

        for task in tasks {
            guard let due = task.dueDate, !task.isDone, due >= start, due <= end else { continue }
            result.append(AgendaEntry(
                id: "task-\(task.id)",
                date: due,
                endDate: nil,
                title: task.title,
                subtitle: [task.course?.displayCode ?? task.provider.label, task.isOverdue ? "en retard" : nil]
                    .compactMap { $0 }.joined(separator: " · "),
                icon: "checklist",
                color: task.isOverdue ? .red : .teal,
                kind: .task,
                task: task))
        }

        return result
            .filter { filter.allows($0) }
            .sorted { lhs, rhs in
                if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
                return lhs.date < rhs.date
            }
    }

    private var weekDays: [Date] {
        (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
    }

    private func entries(on day: Date) -> [AgendaEntry] {
        allEntries.filter { calendar.isDate($0.date, inSameDayAs: day) }
    }

    /// Ce qui suit la journée choisie : les 8 prochaines entrées, hors ce jour.
    private var upcoming: [AgendaEntry] {
        let dayEnd = DateUtils.addDays(1, to: selectedDay)
        return Array(allEntries.filter { $0.date >= dayEnd }.prefix(8))
    }

    private func eventSubtitle(_ event: LinkedCalendarEvent) -> String {
        var parts: [String] = []
        if let course = event.course { parts.append(course.displayCode) }
        if !event.location.isEmpty { parts.append(event.location) }
        if event.isLecture, event.isAttended { parts.append("présence cochée") }
        return parts.isEmpty ? event.kind.label : parts.joined(separator: " · ")
    }

    // MARK: Corps

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Layout.sectionGap) {
                    weekStrip
                    if let syncMessage {
                        Label(syncMessage, systemImage: "calendar.badge.checkmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    daySection
                    upcomingSection
                }
                .padding(Layout.screenPadding)
                .adaptiveColumn()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Agenda")
            .toolbar { toolbar }
            .sheet(isPresented: $showingPlan) {
                PlanSessionView(group: nil, defaultStart: defaultPlanStart)
            }
            .sheet(item: $editingExam) { exam in
                if let course = exam.course {
                    ExamFormSheet(course: course, exam: exam)
                }
            }
            .confirmationDialog("Supprimer cette session ?",
                                isPresented: Binding(get: { sessionToDelete != nil },
                                                     set: { if !$0 { sessionToDelete = nil } }),
                                titleVisibility: .visible) {
                Button("Supprimer", role: .destructive) {
                    if let session = sessionToDelete {
                        PlannedSessionActions.delete(session, context: context, app: app)
                    }
                    sessionToDelete = nil
                }
                Button("Annuler", role: .cancel) { sessionToDelete = nil }
            } message: {
                Text("La session est aussi retirée du calendrier système et son rappel annulé.")
            }
        }
    }

    /// Planifier depuis un jour choisi : la feuille s'ouvre sur ce jour, à 18 h.
    private var defaultPlanStart: Date {
        if calendar.isDateInToday(selectedDay) { return Date().addingTimeInterval(3600) }
        return calendar.date(bySettingHour: 18, minute: 0, second: 0, of: selectedDay) ?? selectedDay
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Toggle(isOn: $filter.lectures) { Label("Séances et cours", systemImage: "building.columns.fill") }
                Toggle(isOn: $filter.exams) { Label("Évaluations", systemImage: "graduationcap.fill") }
                Toggle(isOn: $filter.sessions) { Label("Sessions d'étude", systemImage: "timer") }
                Toggle(isOn: $filter.tasks) { Label("Tâches", systemImage: "checklist") }
                Divider()
                Button {
                    syncCalendar()
                } label: {
                    Label(isSyncing ? "Synchronisation…" : "Synchroniser le calendrier",
                          systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isSyncing)
            } label: {
                Image(systemName: filter.isEverything ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .accessibilityLabel("Filtres et synchronisation")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showingPlan = true
            } label: {
                Image(systemName: "calendar.badge.plus")
            }
            .accessibilityLabel("Planifier une session")
        }
    }

    // MARK: Bande de semaine

    private var weekStrip: some View {
        VStack(spacing: Layout.block) {
            HStack {
                Button {
                    shiftWeek(-1)
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: Layout.minTouch, height: Layout.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Semaine précédente")

                Spacer()
                VStack(spacing: Layout.micro) {
                    Text(weekTitle)
                        .font(.headline)
                    Text(weekSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                Button {
                    shiftWeek(1)
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: Layout.minTouch, height: Layout.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Semaine suivante")
            }

            HStack(spacing: Layout.tight) {
                ForEach(weekDays, id: \.self) { day in
                    dayCell(day)
                }
            }

            if !calendar.isDate(selectedDay, inSameDayAs: Date()) {
                Button("Revenir à aujourd'hui") {
                    withAnimation {
                        selectedDay = DateUtils.startOfDay(Date())
                        weekStart = DateUtils.startOfWeek(Date())
                    }
                    Haptics.soft()
                }
                .font(.caption)
            }
        }
        .padding(Layout.gutter)
        .background(Theme.softBackground, in: RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
    }

    private var weekTitle: String {
        let tracked = courses.filter(\.isTracked)
        if let term = AcademicTerm.resolve(from: tracked.compactMap(\.term)),
           weekStart >= term.startDate, weekStart < term.endDate {
            return "Semaine \(DateUtils.clampedWeek(for: weekStart, term: term))"
        }
        return "Semaine du \(DateUtils.shortDay.string(from: weekStart))"
    }

    private var weekSubtitle: String {
        guard let last = weekDays.last else { return "" }
        let count = weekDays.reduce(0) { $0 + entries(on: $1).count }
        let range = "\(DateUtils.shortDay.string(from: weekStart)) – \(DateUtils.shortDay.string(from: last))"
        return count == 0 ? range : "\(range) · \(count) élément\(count > 1 ? "s" : "")"
    }

    private func dayCell(_ day: Date) -> some View {
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)
        let isToday = calendar.isDateInToday(day)
        let dayEntries = entries(on: day)
        // Jusqu'à trois pastilles, de couleurs distinctes : c'est la nature de la
        // journée qu'on lit, pas son volume.
        var seen: [Color] = []
        for entry in dayEntries where seen.count < 3 && !seen.contains(entry.color) {
            seen.append(entry.color)
        }
        return Button {
            withAnimation(.snappy) { selectedDay = day }
            Haptics.soft()
        } label: {
            VStack(spacing: Layout.tight) {
                Text(DateUtils.weekdayInitial(day))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isSelected ? Theme.accent.badgeInk : .secondary)
                Text("\(calendar.component(.day, from: day))")
                    .font(.subheadline.weight(isToday || isSelected ? .bold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Theme.accent.badgeInk : (isToday ? Theme.accentInk : .primary))
                    .frame(width: 32, height: 32)
                    .background(isSelected ? Theme.accent : Color.clear, in: Circle())
                HStack(spacing: 3) {
                    if seen.isEmpty {
                        Circle().fill(Color.clear).frame(width: 5, height: 5)
                    } else {
                        ForEach(Array(seen.enumerated()), id: \.offset) { _, color in
                            Circle().fill(color.accessibleMark).frame(width: 5, height: 5)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Layout.tight)
            .background(isSelected ? Theme.accent.badgeFill : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(DateUtils.fullDayLabel(day))\(isToday ? ", aujourd'hui" : ""), \(dayEntries.count) élément\(dayEntries.count > 1 ? "s" : "")")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func shiftWeek(_ delta: Int) {
        withAnimation(.snappy) {
            weekStart = DateUtils.addWeeks(delta, to: weekStart)
            // Le jour choisi suit la semaine : même jour de la semaine.
            selectedDay = DateUtils.addWeeks(delta, to: selectedDay)
        }
        Haptics.soft()
    }

    // MARK: Journée

    private var daySection: some View {
        let items = entries(on: selectedDay)
        let total = items.compactMap { entry -> Int? in
            guard let end = entry.endDate else { return nil }
            return Int(end.timeIntervalSince(entry.date))
        }.reduce(0, +)
        return VStack(alignment: .leading, spacing: Layout.control) {
            SectionHeader(title: dayTitle,
                          trailing: total > 0 ? DateUtils.durationLabel(seconds: total) : nil)
            if items.isEmpty {
                EmptyCard(icon: "calendar",
                          title: calendar.isDateInToday(selectedDay) ? "Rien aujourd'hui" : "Rien ce jour-là",
                          message: filter.isEverything
                              ? "Planifie une session d'étude, ou importe ton horaire pour voir tes séances ici."
                              : "Rien avec les filtres actuels.",
                          actionTitle: "Planifier une session") {
                    showingPlan = true
                }
            } else {
                Card {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, entry in
                            timelineRow(entry)
                            if index < items.count - 1 {
                                Divider().padding(.leading, 64)
                            }
                        }
                    }
                }
            }
        }
    }

    private var dayTitle: String {
        if calendar.isDateInToday(selectedDay) { return "Aujourd'hui" }
        if calendar.isDateInTomorrow(selectedDay) { return "Demain" }
        if calendar.isDateInYesterday(selectedDay) { return "Hier" }
        return DateUtils.fullDayLabel(selectedDay)
    }

    /// Une ligne de journée : l'heure à gauche, dans sa colonne, puis l'entrée.
    private func timelineRow(_ entry: AgendaEntry) -> some View {
        HStack(alignment: .top, spacing: Layout.block) {
            VStack(alignment: .trailing, spacing: Layout.micro) {
                Text(entry.isAllDay ? "journée" : DateUtils.time.string(from: entry.date))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                if let end = entry.endDate {
                    Text(DateUtils.time.string(from: end))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .frame(width: 44, alignment: .trailing)
            .padding(.top, Layout.micro)

            RoundedRectangle(cornerRadius: 2)
                .fill(entry.color.accessibleMark)
                .frame(width: 4)

            actions(for: entry) {
                HStack(spacing: Layout.control) {
                    VStack(alignment: .leading, spacing: Layout.micro) {
                        Text(entry.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        if !entry.subtitle.isEmpty {
                            Text(entry.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: Layout.inline)
                    Image(systemName: entry.icon)
                        .font(.caption)
                        .foregroundStyle(entry.color.accessibleMark)
                    if let event = entry.event, event.isLecture, event.course != nil {
                        CheckCircleButton(isOn: event.isAttended,
                                          tint: .blue,
                                          label: "Marquer la présence à \(event.title)") {
                            event.isAttended.toggle()
                            try? context.save()
                        }
                    }
                }
            }
        }
        .padding(.vertical, Layout.inline)
        .frame(minHeight: Layout.minTouch)
    }

    // MARK: À venir

    @ViewBuilder
    private var upcomingSection: some View {
        let items = upcoming
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Layout.control) {
                SectionHeader(title: "Ensuite", trailing: "\(items.count) prochains")
                Card {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, entry in
                            actions(for: entry) {
                                HStack(spacing: Layout.block) {
                                    VStack(alignment: .leading, spacing: Layout.micro) {
                                        Text(DateUtils.relativeLabel(entry.date))
                                            .font(.caption.weight(.semibold))
                                        Text(entry.isAllDay ? "—" : DateUtils.time.string(from: entry.date))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
                                    }
                                    .frame(width: 84, alignment: .leading)
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(entry.color.accessibleMark)
                                        .frame(width: 4, height: 30)
                                    VStack(alignment: .leading, spacing: Layout.micro) {
                                        Text(entry.title).font(.subheadline).lineLimit(1)
                                        if !entry.subtitle.isEmpty {
                                            Text(entry.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: Layout.inline)
                                    if entry.kind == .exam {
                                        Text(DateUtils.countdownLabel(to: entry.date))
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(entry.color.accessibleInk)
                                    }
                                }
                            }
                            .padding(.vertical, Layout.inline)
                            if index < items.count - 1 {
                                Divider().padding(.leading, 96)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Actions de ligne

    /// Habille une entrée des gestes qui lui correspondent : tap pour modifier une
    /// évaluation, menu contextuel pour supprimer une session, terminer une tâche
    /// ou lancer le chrono.
    @ViewBuilder
    private func actions<Content: View>(for entry: AgendaEntry, @ViewBuilder content: () -> Content) -> some View {
        let base = content().contentShape(Rectangle())
        if let exam = entry.exam {
            Button { editingExam = exam } label: { base }
                .buttonStyle(.plain)
                .accessibilityHint("Modifier l'évaluation")
        } else if let session = entry.plannedSession {
            base.contextMenu {
                Button {
                    app.router.startFocus(courseID: session.course?.id,
                                          courseCode: session.course?.code ?? "",
                                          taskType: .exercise,
                                          label: session.title)
                } label: {
                    Label("Démarrer le chrono", systemImage: "timer")
                }
                Button(role: .destructive) {
                    sessionToDelete = session
                } label: {
                    Label("Supprimer la session", systemImage: "trash")
                }
            }
        } else if let task = entry.task {
            base.contextMenu {
                Button {
                    complete(task)
                } label: {
                    Label("Terminer la tâche", systemImage: "checkmark")
                }
            }
        } else {
            base
        }
    }

    private func complete(_ task: LinkedTask) {
        task.isDone = true
        task.updatedAt = Date()
        try? context.save()
        Haptics.success()
        if let externalID = task.externalID,
           let service = TaskServiceFactory.shared.service(for: task.provider, settings: app.settings) {
            Task { _ = await service.setCompleted(identifier: externalID, completed: true) }
        }
    }

    private func syncCalendar() {
        isSyncing = true
        Task { @MainActor in
            defer { isSyncing = false }

            if !app.calendar.hasAccess {
                let granted = await app.calendar.requestAccess()
                guard granted else {
                    syncMessage = "Accès au calendrier refusé. Autorise-le dans Réglages › StudyTrack."
                    return
                }
            }

            let result = CalendarSync.sync(context: context,
                                           courses: courses,
                                           service: app.calendar)
            if result.total == 0 {
                syncMessage = "Aucun événement trouvé sur la période."
            } else {
                syncMessage = "\(result.imported) événement(s) importé(s) · \(result.updated) mis à jour."
            }
        }
    }
}
