import SwiftUI
import SwiftData

/// Un groupe, sur une seule page : qui travaille maintenant, le classement de
/// la semaine, qui en est où dans la série, l'entraide, les sessions.
///
/// Les groupes étaient une liste, puis une fiche, puis quatre sous-pages : il
/// fallait trois touchers pour savoir si quelqu'un travaillait, et rien ne
/// donnait envie d'y revenir. Ici, l'onglet **est** le groupe. Ce qui change
/// souvent (le direct, les questions) est en haut ; ce qui se règle rarement
/// (membres, matières, invitation, quitter) est dans le menu « ⋯ ».
struct GroupHubView: View {
    @Bindable var group: StudyGroup

    @Environment(AppContainer.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \Course.code) private var myCourses: [Course]
    @Query(sort: \PlannedSession.startsAt) private var allPlanned: [PlannedSession]

    @State private var presence: [PresenceEntry] = []
    @State private var presenceError: String?
    @State private var posts: [RemotePost] = []
    @State private var postsError: String?
    @State private var now = Date()
    @State private var composing = false
    @State private var openedThread: RemotePost?
    @State private var showingPlan = false

    // MARK: Dérivés

    private var isOnline: Bool { group.remoteID != nil && app.social.isSignedIn }
    private var liveEntries: [PresenceEntry] { PresenceBoard.live(presence, at: now) }
    private var trackedCodes: Set<String> { Set(myCourses.filter(\.isTracked).map { $0.code.uppercased() }) }
    private var mySubjects: [String] {
        let shared = group.mySubjectCodes(myTrackedCourses: trackedCodes)
        return shared.isEmpty && trackedCodes.isEmpty ? group.subjectCodes : shared
    }
    private var sessions: [PlannedSession] {
        allPlanned.filter { $0.groupName == group.name && !$0.isPast }.sorted { $0.startsAt < $1.startsAt }
    }
    private var questions: [RemotePost] { posts.filter { $0.parentId == nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            liveCard
            ranking
            whoIsWhere
            helpSection
            sessionsSection
        }
        .task(id: group.remoteID) { await watch() }
        .sheet(isPresented: $composing) {
            HelpComposer(group: group, subjects: mySubjects) { post in
                posts.insert(post, at: 0)
            }
        }
        .sheet(item: $openedThread) { post in
            HelpThread(group: group, question: post, replies: posts.filter { $0.parentId == post.id }) { changed in
                Task { await reloadPosts() }
                _ = changed
            }
        }
        .sheet(isPresented: $showingPlan) { PlanSessionView(group: group) }
    }

    // MARK: En direct

    private var liveCard: some View {
        let live = liveEntries
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(live.isEmpty ? Carnet.inkTertiary : Carnet.correct)
                    .frame(width: 8, height: 8)
                CarnetKicker(live.isEmpty ? "En direct" : PresenceBoard.summary(live),
                             color: live.isEmpty ? Carnet.inkSecondary : Carnet.correct)
            }
            if !isOnline {
                Text(group.remoteID == nil
                     ? "Ce groupe n'existe que sur ton téléphone : partage-le pour travailler ensemble."
                     : "Connecte-toi (Moi › Réglages › Compte et groupes) pour voir qui travaille.")
                    .font(.subheadline)
                    .foregroundStyle(Carnet.inkSecondary)
            } else if let presenceError {
                Text(presenceError).font(.footnote).foregroundStyle(Carnet.wrong)
            } else if live.isEmpty {
                Text(app.presence.isSharing
                     ? "Personne d'autre pour l'instant. Ta session est visible par le groupe."
                     : "Personne ne travaille. Lance le chrono : le groupe te verra, et pourra te rejoindre.")
                    .font(.subheadline)
                    .foregroundStyle(Carnet.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(live) { entry in
                    liveRow(entry)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .carnetGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func liveRow(_ entry: PresenceEntry) -> some View {
        HStack(spacing: 12) {
            GroupAvatar(name: entry.isMe ? "Toi" : entry.displayName, highlighted: entry.isMe)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.isMe ? "Toi" : entry.displayName).font(.body.weight(.medium)).foregroundStyle(Carnet.ink)
                Text("\(entry.activityLabel) · \(entry.elapsedLabel(at: now))")
                    .font(.footnote)
                    .foregroundStyle(Carnet.inkSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if !entry.isMe, !entry.courseCode.isEmpty {
                Button("Rejoindre") { join(entry) }
                    .buttonStyle(.carnetPrimary)
                    .controlSize(.small)
                    .accessibilityLabel("Travailler sur \(entry.courseCode) avec \(entry.displayName)")
            }
        }
    }

    /// Lance mon chrono sur le même travail que ce membre.
    private func join(_ entry: PresenceEntry) {
        let type = TaskType.allCases.first { $0.label == entry.taskLabel } ?? .exercise
        let course = myCourses.first { $0.code.uppercased() == entry.courseCode.uppercased() }
        app.router.startFocus(courseID: course?.id, courseCode: entry.courseCode, taskType: type,
                              label: "\(entry.courseCode) · \(type.label) · avec \(entry.displayName)")
        Haptics.success()
    }

    // MARK: Classement

    private var ranking: some View {
        let members = group.members.sorted {
            $0.weeklySeconds != $1.weeklySeconds ? $0.weeklySeconds > $1.weeklySeconds : $0.isMe
        }
        let peak = max(members.first?.weeklySeconds ?? 0, 1)
        return VStack(alignment: .leading, spacing: 10) {
            CarnetSectionTitle("Classement") {
                NavigationLink("7 derniers jours", value: GroupPageRoute(groupID: group.id, page: .time))
            }
            CarnetSheet {
                if members.isEmpty {
                    CarnetRow(title: "Aucun membre", subtitle: "Invite tes camarades avec le code du groupe.")
                }
                ForEach(Array(members.enumerated()), id: \.element.id) { index, member in
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(Carnet.serif(.title3))
                            .foregroundStyle(index == 0 && member.weeklySeconds > 0 ? Carnet.review : Carnet.inkSecondary)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(member.isMe ? "Toi" : member.shownName)
                                    .font(.body.weight(member.isMe ? .semibold : .regular))
                                    .foregroundStyle(Carnet.ink)
                                Spacer()
                                Text(member.weeklyLabel)
                                    .font(Carnet.mono(.footnote, weight: .medium))
                                    .foregroundStyle(Carnet.ink)
                            }
                            CarnetBar(value: Double(member.weeklySeconds) / Double(peak),
                                      tint: member.isMe ? Carnet.ink : Carnet.inkTertiary, height: 4)
                            if member.completedSeriesCount > 0 {
                                Text("\(member.completedSeriesCount) série\(member.completedSeriesCount > 1 ? "s" : "") terminée\(member.completedSeriesCount > 1 ? "s" : "")")
                                    .font(.caption)
                                    .foregroundStyle(Carnet.inkSecondary)
                            }
                        }
                    }
                    .padding(.horizontal, Carnet.rowInset)
                    .padding(.vertical, 10)
                    .background(member.isMe ? Carnet.marker.opacity(0.5) : .clear)
                    .accessibilityElement(children: .combine)
                    if index < members.count - 1 { CarnetRule(inset: 48) }
                }
            }
        }
    }

    // MARK: Qui en est où

    @ViewBuilder
    private var whoIsWhere: some View {
        let boards = currentBoards
        if !boards.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                CarnetSectionTitle("Qui en est où") {
                    NavigationLink("Toutes les séries", value: GroupPageRoute(groupID: group.id, page: .series))
                }
                ForEach(boards, id: \.code) { entry in
                    boardCard(code: entry.code, board: entry.board)
                }
            }
        }
    }

    /// Pour chaque matière partagée, la série de la semaine (sinon la dernière
    /// commencée).
    private var currentBoards: [(code: String, board: SeriesBoard)] {
        mySubjects.compactMap { code in
            let course = myCourses.first { $0.code.uppercased() == code.uppercased() }
            let boards = GroupProgressBuilder.seriesBoards(subject: code, group: group, course: course, meID: app.social.userID)
            guard !boards.isEmpty else { return nil }
            let week = course?.currentWeek ?? 0
            let board = boards.first { $0.plannedWeek == week }
                ?? boards.last { $0.startedCount > 0 }
                ?? boards.first
            return board.map { (code, $0) }
        }
    }

    private func boardCard(code: String, board: SeriesBoard) -> some View {
        let course = myCourses.first { $0.code.uppercased() == code.uppercased() }
        let tint = course.map { Carnet.tint($0.colorHex) } ?? Carnet.inkSecondary
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(code) · Série \(board.seriesNumber)").font(.subheadline.weight(.semibold)).foregroundStyle(tint)
                Spacer()
                Text(board.summary).font(.footnote).foregroundStyle(Carnet.inkSecondary)
            }
            Grid(horizontalSpacing: 4, verticalSpacing: 6) {
                GridRow {
                    Text("").frame(width: 56, alignment: .leading)
                    ForEach(board.exerciseNumbers, id: \.self) { number in
                        Text(number.split(separator: ".").last.map(String.init) ?? number)
                            .font(.caption2)
                            .foregroundStyle(Carnet.inkTertiary)
                            .frame(maxWidth: .infinity)
                    }
                }
                ForEach(board.rows.prefix(8)) { row in
                    GridRow {
                        Text(row.isMe ? "Toi" : row.displayName)
                            .font(.caption.weight(row.isMe ? .semibold : .regular))
                            .foregroundStyle(Carnet.ink)
                            .lineLimit(1)
                            .frame(width: 56, alignment: .leading)
                        ForEach(board.exerciseNumbers, id: \.self) { number in
                            let done = row.declaredComplete || row.doneNumbers.contains(number)
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(done ? tint : Carnet.rule)
                                .frame(height: 12)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .accessibilityElement()
                    .accessibilityLabel("\(row.isMe ? "Toi" : row.displayName) : \(row.doneCount) exercices sur \(board.total)")
                }
            }
        }
        .padding(14)
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
    }

    // MARK: Entraide

    private var helpSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            CarnetSectionTitle("Entraide") {
                if isOnline {
                    Button {
                        composing = true
                    } label: {
                        Label("Demander", systemImage: "plus.bubble")
                    }
                }
            }
            CarnetSheet {
                if !isOnline {
                    CarnetRow(icon: "bubble.left.and.bubble.right", tint: Carnet.inkSecondary,
                              title: "Pose tes questions au groupe",
                              subtitle: "Disponible une fois le groupe partagé et ton compte connecté.")
                } else if let postsError {
                    CarnetRow(icon: "exclamationmark.triangle", tint: Carnet.wrong, title: "Entraide indisponible",
                              subtitle: postsError)
                } else if questions.isEmpty {
                    Button { composing = true } label: {
                        CarnetRow(icon: "bubble.left.and.bubble.right", tint: Carnet.inkSecondary,
                                  title: "Bloqué·e sur un exercice ?",
                                  subtitle: "Demande au groupe : la question porte l'exercice, la réponse arrive ici.")
                    }
                    .buttonStyle(.plain)
                }
                ForEach(Array(questions.prefix(8).enumerated()), id: \.element.id) { index, post in
                    Button { openedThread = post } label: {
                        questionRow(post)
                    }
                    .buttonStyle(.plain)
                    if index < min(questions.count, 8) - 1 { CarnetRule(inset: 56) }
                }
            }
        }
    }

    private func questionRow(_ post: RemotePost) -> some View {
        let replies = posts.filter { $0.parentId == post.id }.count
        let mine = post.authorId == app.social.userID
        return HStack(alignment: .top, spacing: 12) {
            GroupAvatar(name: mine ? "Toi" : post.authorName, highlighted: mine)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(mine ? "Toi" : post.authorName).font(.subheadline.weight(.semibold)).foregroundStyle(Carnet.ink)
                    if !post.target.isEmpty {
                        Text(post.target).font(.footnote).foregroundStyle(Carnet.inkSecondary)
                    }
                    Spacer(minLength: 0)
                    Text(DateUtils.relativeLabel(post.createdAt)).font(.caption).foregroundStyle(Carnet.inkTertiary)
                }
                Text(post.body).font(.body).foregroundStyle(Carnet.ink).lineLimit(3)
                HStack(spacing: 10) {
                    Label(replies == 0 ? "Répondre" : "\(replies) réponse\(replies > 1 ? "s" : "")",
                          systemImage: "arrowshape.turn.up.left")
                    if post.resolved {
                        Label("Résolu", systemImage: "checkmark.circle.fill").foregroundStyle(Carnet.correct)
                    }
                }
                .font(.footnote)
                .foregroundStyle(Carnet.inkSecondary)
            }
        }
        .padding(.horizontal, Carnet.rowInset)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    // MARK: Sessions

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            CarnetSectionTitle("Sessions") {
                Button {
                    showingPlan = true
                } label: {
                    Label("Planifier", systemImage: "calendar.badge.plus")
                }
            }
            CarnetSheet {
                if sessions.isEmpty {
                    CarnetRow(icon: "calendar", tint: Carnet.inkSecondary, title: "Aucune session prévue",
                              subtitle: "Propose un créneau : « Physique jeudi 18h, BC 01 ».")
                }
                ForEach(Array(sessions.prefix(4).enumerated()), id: \.element.id) { index, session in
                    NavigationLink(value: GroupPageRoute(groupID: group.id, page: .planning)) {
                        CarnetRow(icon: "person.2.wave.2", tint: session.course.map { Carnet.tint($0.colorHex) } ?? Carnet.inkSecondary,
                                  title: session.title,
                                  subtitle: [DateUtils.relativeLabel(session.startsAt) + " " + DateUtils.time.string(from: session.startsAt),
                                             session.location.isEmpty ? nil : session.location]
                                    .compactMap { $0 }.joined(separator: " · ")) {
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Carnet.inkTertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    if index < min(sessions.count, 4) - 1 { CarnetRule() }
                }
            }
        }
    }

    // MARK: Réseau

    /// Le direct et l'entraide, relus tant que la page est ouverte.
    private func watch() async {
        guard isOnline else { return }
        while !Task.isCancelled {
            await refreshPresence()
            await reloadPosts()
            now = Date()
            try? await Task.sleep(for: .seconds(30))
        }
    }

    private func refreshPresence() async {
        guard let remoteID = group.remoteID else { return }
        do {
            presence = try await app.social.fetchPresence(groupID: remoteID)
            presenceError = nil
        } catch {
            presenceError = GroupSync.explain(error)
        }
    }

    func reloadPosts() async {
        guard let remoteID = group.remoteID else { return }
        do {
            posts = try await app.social.fetchPosts(groupID: remoteID)
            postsError = nil
        } catch {
            postsError = GroupSync.explain(error)
        }
    }
}

/// Les initiales d'un membre, dans un rond.
struct GroupAvatar: View {
    let name: String
    var highlighted = false

    var body: some View {
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map { String($0).uppercased() }.joined()
        Text(initials.isEmpty ? "?" : initials)
            .font(.caption.weight(.bold))
            .foregroundStyle(highlighted ? Carnet.ground : Carnet.ink)
            .frame(width: 34, height: 34)
            .background(highlighted ? Carnet.ink : Carnet.sheetRaised, in: Circle())
            .accessibilityHidden(true)
    }
}

// MARK: - Entraide : poser une question

/// « Je bloque sur 4.3 (b) » : la question porte le cours et l'exercice.
struct HelpComposer: View {
    let group: StudyGroup
    let subjects: [String]
    var onPosted: (RemotePost) -> Void

    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Course.code) private var courses: [Course]

    @State private var courseCode = ""
    @State private var exerciseID: UUID?
    @State private var text = ""
    @State private var sending = false
    @State private var error: String?

    private var course: Course? { courses.first { $0.code.uppercased() == courseCode.uppercased() } }

    /// Les exercices proposés : ceux de la semaine d'abord, puis le reste.
    private var exercises: [Exercise] {
        guard let course else { return [] }
        let week = course.currentWeek
        return course.sortedSeries
            .sorted { lhs, rhs in
                let l = lhs.plannedWeek == week ? 0 : (lhs.plannedWeek < week ? 1 : 2)
                let r = rhs.plannedWeek == week ? 0 : (rhs.plannedWeek < week ? 1 : 2)
                return l != r ? l < r : lhs.seriesNumber > rhs.seriesNumber
            }
            .flatMap(\.sortedExercises)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Sur quoi") {
                    Picker("Cours", selection: $courseCode) {
                        Text("Général").tag("")
                        ForEach(subjects, id: \.self) { Text($0).tag($0) }
                    }
                    if !exercises.isEmpty {
                        Picker("Exercice", selection: $exerciseID) {
                            Text("Aucun en particulier").tag(UUID?.none)
                            ForEach(exercises) { exercise in
                                Text("\(exercise.exerciseNumber) · \(MathMarkup.plain(exercise.title))").tag(UUID?.some(exercise.id))
                            }
                        }
                    }
                }
                Section {
                    TextField("Où bloques-tu ? Ce que tu as essayé…", text: $text, axis: .vertical)
                        .lineLimit(4...10)
                } footer: {
                    if let error { Text(error).foregroundStyle(Carnet.wrong) }
                }
            }
            .carnetBackground()
            .navigationTitle("Demander de l'aide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Envoyer") { Task { await send() } }
                        .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if courseCode.isEmpty, let first = subjects.first { courseCode = first }
            }
        }
    }

    private func send() async {
        guard let remoteID = group.remoteID else { return }
        sending = true
        defer { sending = false }
        let exercise = exercises.first { $0.id == exerciseID }
        do {
            let post = try await app.social.createPost(groupID: remoteID,
                                                       authorName: app.settings.displayName.isEmpty ? "Moi" : app.settings.displayName,
                                                       courseCode: courseCode,
                                                       seriesNumber: exercise?.series?.seriesNumber,
                                                       exerciseNumber: exercise?.exerciseNumber ?? "",
                                                       body: text.trimmingCharacters(in: .whitespacesAndNewlines))
            onPosted(post)
            Haptics.success()
            dismiss()
        } catch {
            self.error = GroupSync.explain(error)
        }
    }
}

// MARK: - Entraide : un fil

struct HelpThread: View {
    let group: StudyGroup
    let question: RemotePost
    @State var replies: [RemotePost]
    var onChange: (Bool) -> Void

    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var sending = false
    @State private var resolved: Bool
    @State private var error: String?

    init(group: StudyGroup, question: RemotePost, replies: [RemotePost], onChange: @escaping (Bool) -> Void) {
        self.group = group
        self.question = question
        _replies = State(initialValue: replies.sorted { $0.createdAt < $1.createdAt })
        self.onChange = onChange
        _resolved = State(initialValue: question.resolved)
    }

    private var isMine: Bool { question.authorId == app.social.userID }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    message(question, isQuestion: true)
                    ForEach(replies) { reply in
                        message(reply, isQuestion: false)
                    }
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(Carnet.wrong)
                    }
                }
                .padding(16)
            }
            .background(Carnet.ground.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    TextField("Répondre…", text: $text, axis: .vertical)
                        .lineLimit(1...5)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    Button {
                        Task { await send() }
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.body.weight(.bold))
                            .foregroundStyle(Carnet.ground)
                            .frame(width: 40, height: 40)
                            .background(Carnet.ink, in: Circle())
                    }
                    .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Envoyer la réponse")
                }
                .padding(10)
                .carnetGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }
            .navigationTitle(question.target.isEmpty ? "Question" : question.target)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
                if isMine {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(resolved ? "Rouvrir" : "Résolu") { Task { await toggleResolved() } }
                    }
                }
            }
        }
    }

    private func message(_ post: RemotePost, isQuestion: Bool) -> some View {
        let mine = post.authorId == app.social.userID
        return HStack(alignment: .top, spacing: 10) {
            GroupAvatar(name: mine ? "Toi" : post.authorName, highlighted: mine)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(mine ? "Toi" : post.authorName).font(.subheadline.weight(.semibold))
                    Text(DateUtils.relativeLabel(post.createdAt)).font(.caption).foregroundStyle(Carnet.inkTertiary)
                    if isQuestion, resolved {
                        Label("Résolu", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Carnet.correct)
                    }
                }
                Text(post.body)
                    .font(isQuestion ? Carnet.serif(.body) : .body)
                    .foregroundStyle(Carnet.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isQuestion ? Carnet.sheet : Carnet.sheet.opacity(0.7),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func send() async {
        guard let remoteID = group.remoteID else { return }
        sending = true
        defer { sending = false }
        do {
            let reply = try await app.social.createPost(groupID: remoteID,
                                                        authorName: app.settings.displayName.isEmpty ? "Moi" : app.settings.displayName,
                                                        parentID: question.id,
                                                        courseCode: question.courseCode,
                                                        body: text.trimmingCharacters(in: .whitespacesAndNewlines))
            replies.append(reply)
            text = ""
            error = nil
            onChange(true)
            Haptics.success()
        } catch {
            self.error = GroupSync.explain(error)
        }
    }

    private func toggleResolved() async {
        do {
            try await app.social.setPostResolved(postID: question.id, resolved: !resolved)
            resolved.toggle()
            onChange(true)
        } catch {
            self.error = GroupSync.explain(error)
        }
    }
}
