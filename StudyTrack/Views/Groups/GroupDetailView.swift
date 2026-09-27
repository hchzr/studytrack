import SwiftUI
import SwiftData

/// Détail d'un groupe : présence, matières, avancement, membres, planning.
///
/// L'ordre des cartes suit l'usage réel : ce qui se passe **maintenant** d'abord
/// (qui travaille), puis où en est le groupe matière par matière, puis la
/// composition du groupe, et enfin ce qui se planifie. Les actions destructrices
/// sont en bas, jamais à portée de pouce.
struct GroupDetailView: View {
    let group: StudyGroup

    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \Course.code) private var myCourses: [Course]
    @Query(sort: \PlannedSession.startsAt) private var allPlanned: [PlannedSession]

    @State private var presence: [PresenceEntry] = []
    @State private var presenceError: String?
    @State private var syncMessage: String?
    @State private var isRepairing = false
    @State private var now = Date()
    @State private var showingPlan = false
    @State private var showingSubjects = false
    @State private var showingInvite = false
    @State private var showingLeave = false
    @State private var showingDelete = false
    @State private var isLeaving = false
    @State private var isPublishing = false
    @State private var inviteError: String?

    // MARK: Dérivés

    private var groupSessions: [PlannedSession] {
        allPlanned
            .filter { $0.groupName == group.name && !$0.isPast }
            .sorted { $0.startsAt < $1.startsAt }
    }

    /// Mes matières suivies, en majuscules — pour ne proposer que ce qui me concerne.
    private var myTrackedCodes: Set<String> {
        Set(myCourses.filter(\.isTracked).map { $0.code.uppercased() })
    }

    /// Les matières du groupe que je suis réellement.
    ///
    /// Si je n'ai encore aucun cours (onboarding à peine terminé, import en cours),
    /// on montre tout plutôt que rien : une carte vide laisserait croire que le
    /// groupe n'a pas de matières.
    private var mySubjects: [String] {
        let shared = group.mySubjectCodes(myTrackedCourses: myTrackedCodes)
        return shared.isEmpty && myTrackedCodes.isEmpty ? group.subjectCodes : shared
    }

    /// Les matières du groupe que je ne suis pas — affichées, mais en retrait.
    private var otherSubjects: [String] {
        group.subjectCodes.filter { !mySubjects.contains($0) }
    }

    private var me: GroupMember? { group.members.first(where: \.isMe) }
    private var iAmAdmin: Bool { me?.isAdmin ?? group.isAdmin }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                presenceCard
                overviewCard
                pagesCard
                subjectsCard
                inviteCard
                dangerZone
            }
            .padding()
            .adaptiveColumn()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingPlan = true
                } label: {
                    Image(systemName: "calendar.badge.plus")
                }
                .accessibilityLabel("Planifier une session")
            }
        }
        .sheet(isPresented: $showingPlan) { PlanSessionView(group: group) }
        .sheet(isPresented: $showingSubjects) { GroupSubjectsView(group: group) }
        .sheet(isPresented: $showingInvite) { GroupInviteView(group: group) }
        .onAppear {
            #if DEBUG
            // `-groupInvite` : la feuille d'invitation n'est atteignable qu'après
            // un tap, et `simctl` ne sait pas taper.
            if PreviewLaunch.isSet(PreviewLaunch.groupInviteFlag) { showingInvite = true }
            if PreviewLaunch.isSet(PreviewLaunch.groupSubjectsFlag) { showingSubjects = true }
            #endif
        }
        .confirmationDialog("Quitter « \(group.name) » ?",
                            isPresented: $showingLeave,
                            titleVisibility: .visible) {
            Button("Quitter le groupe", role: .destructive) { leave() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text(leaveWarning)
        }
        .confirmationDialog("Supprimer « \(group.name) » ?",
                            isPresented: $showingDelete,
                            titleVisibility: .visible) {
            Button("Supprimer pour tout le monde", role: .destructive) { deleteGroup() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text(group.remoteID == nil
                 ? "Le groupe n'existe que sur cet appareil : il disparaît avec ses membres et son avancement."
                 : "Le groupe est supprimé côté serveur : les \(group.members.count) membres le perdent, avec l'avancement partagé. Pour partir seul·e, utilise « Quitter ».")
        }
        .task(id: group.remoteID) { await watchPresence() }
    }

    // MARK: Présence

    private var liveEntries: [PresenceEntry] { PresenceBoard.live(presence, at: now) }

    /// Pourquoi le direct marche — ou pas.
    private var availability: PresenceAvailability {
        PresenceAvailability.evaluate(isConfigured: app.social.isConfigured,
                                      isSignedIn: app.social.isSignedIn,
                                      hasRemoteGroup: group.remoteID != nil,
                                      lastError: app.presence.lastError ?? presenceError)
    }

    /// Interroge le serveur tant que l'écran est ouvert.
    ///
    /// Trente secondes : assez frais pour que « Alice travaille » soit vrai, assez
    /// rare pour ne pas vider la batterie d'un écran qu'on laisse ouvert pendant
    /// une session de révision.
    private func watchPresence() async {
        guard group.remoteID != nil, app.social.isSignedIn else { return }
        while !Task.isCancelled {
            await refreshPresence()
            now = Date()
            try? await Task.sleep(for: .seconds(30))
        }
    }

    /// Synchronise (ce qui rétablit mon adhésion si elle manque), puis relit le direct.
    private func repairAndRefresh() async {
        isRepairing = true
        syncMessage = await GroupSync.refresh(context: context,
                                              social: app.social,
                                              settings: app.settings)
        await refreshPresence()
        // La synchronisation a pu reconstruire les membres : on relit le groupe.
        isRepairing = false
    }

    private func refreshPresence() async {
        guard let remoteID = group.remoteID else { return }
        do {
            presence = try await app.social.fetchPresence(groupID: remoteID)
            presenceError = nil
        } catch {
            // Un échec de lecture doit se voir : sinon « personne ne travaille »
            // s'affiche alors que la question n'a même pas pu être posée.
            presenceError = GroupSync.explain(error)
        }
    }

    /// La carte est **toujours** affichée, même inutilisable : quand le direct ne
    /// peut pas fonctionner, le dire est plus utile que de masquer la carte — sinon
    /// « personne ne travaille » se lit comme une information, alors que c'est une
    /// absence de réponse.
    private var presenceCard: some View {
        Card(title: "En direct", icon: "dot.radiowaves.left.and.right") {
            presenceContent
        }
    }

    @ViewBuilder
    private var presenceContent: some View {
        let live = liveEntries
        if !availability.isReady {
            VStack(alignment: .leading, spacing: Layout.control) {
                Label(availability.message ?? "Direct indisponible.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Color.orange.accessibleInk)
                    .fixedSize(horizontal: false, vertical: true)
                if group.remoteID != nil, app.social.isSignedIn {
                    // Une **synchronisation**, pas une simple relecture : c'est
                    // elle qui rétablit l'adhésion manquante côté serveur, cause
                    // la plus fréquente d'un refus RLS ici.
                    Button {
                        Task { await repairAndRefresh() }
                    } label: {
                        if isRepairing {
                            HStack(spacing: Layout.snug) {
                                ProgressView()
                                Text("Réparation…")
                            }
                            .font(.caption)
                        } else {
                            Label("Réparer et réessayer", systemImage: "arrow.clockwise")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRepairing)
                }
            }
        } else if live.isEmpty {
            VStack(alignment: .leading, spacing: Layout.tight) {
                Text("Personne ne travaille en ce moment.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if app.presence.isSharing {
                    Label("Ta session est publiée — les autres te voient.", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.green.accessibleInk)
                } else {
                    Text("Ta session apparaît ici dès que tu lances le chrono.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: Layout.block) {
                Text(PresenceBoard.summary(live))
                    .font(.subheadline.weight(.semibold))
                ForEach(live) { entry in
                    liveRow(entry)
                }
            }
        }
    }

    private func liveRow(_ entry: PresenceEntry) -> some View {
        let tint: Color = entry.isMe ? Theme.accent : .green
        let elapsed = entry.elapsedLabel(at: now)
        return HStack(spacing: Layout.control) {
            ZStack {
                Circle()
                    .fill(tint.badgeFill)
                    .frame(width: 32, height: 32)
                Text(initials(entry.displayName))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tint.badgeInk)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Layout.snug) {
                    Text(entry.isMe ? "Toi" : entry.displayName)
                        .font(.subheadline)
                        .lineLimit(1)
                    Circle()
                        .fill(Color.green.accessibleMark)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
                Text(entry.activityLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Layout.inline)
            Text(elapsed)
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            // Rejoindre : on travaille sur le même cours, au même moment. C'est
            // tout l'intérêt d'un groupe d'entraide — et ça ne demande rien au
            // serveur, la présence porte déjà le cours et la nature du travail.
            if !entry.isMe, !entry.courseCode.isEmpty {
                Button {
                    join(entry)
                } label: {
                    Text("Rejoindre")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, Layout.snug)
                        .padding(.vertical, 4)
                        .background(Theme.accent.badgeFill, in: Capsule())
                        .foregroundStyle(Theme.accent.badgeInk)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Travailler sur \(entry.courseCode) comme \(entry.displayName)")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.isMe ? "Toi" : entry.displayName), \(entry.activityLabel), depuis \(elapsed)")
    }

    /// Lance mon chrono sur le même travail que ce membre.
    ///
    /// On retrouve la nature du travail depuis son libellé : c'est le seul champ
    /// que la présence transporte, et il suffit — « Exercices » désigne le même
    /// type pour tout le monde.
    private func join(_ entry: PresenceEntry) {
        let type = TaskType.allCases.first { $0.label == entry.taskLabel } ?? .exercise
        let label = "\(entry.courseCode) · \(type.label) · avec \(entry.displayName)"
        app.router.startFocus(courseID: nil,
                              courseCode: entry.courseCode,
                              taskType: type,
                              label: label)
        Haptics.success()
    }

    private func initials(_ name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let value = parts.map { String($0.prefix(1)).uppercased() }.joined()
        return value.isEmpty ? "?" : value
    }

    // MARK: Vue d'ensemble

    /// Trois chiffres qui situent le groupe, avant d'entrer dans les pages.
    private var overviewCard: some View {
        let ranked = group.sortedMembers
        let myRank = ranked.firstIndex(where: \.isMe).map { $0 + 1 }
        let upcoming = groupSessions.count
        return HStack(spacing: Layout.block) {
            StatCard(icon: "person.3.fill",
                     value: "\(group.members.count)",
                     title: "membre\(group.members.count > 1 ? "s" : "")",
                     tint: .purple)
            StatCard(icon: "trophy.fill",
                     value: myRank.map { "#\($0)" } ?? "—",
                     title: "ta place (7 j)",
                     tint: .orange)
            StatCard(icon: "calendar",
                     value: "\(upcoming)",
                     title: upcoming == 1 ? "session à venir" : "sessions à venir",
                     tint: .indigo)
        }
    }

    // MARK: Pages

    /// Les quatre sous-pages : une ligne, un chiffre, une flèche. La fiche ne
    /// tente plus de tout montrer — elle oriente.
    private var pagesCard: some View {
        Card {
            VStack(spacing: 0) {
                pageRow(.series, detail: seriesDetail)
                Divider().padding(.leading, 36)
                pageRow(.time, detail: timeDetail)
                Divider().padding(.leading, 36)
                pageRow(.members, detail: "\(group.members.count) membre\(group.members.count > 1 ? "s" : "") · \(group.members.filter(\.isAdmin).count) admin")
                Divider().padding(.leading, 36)
                pageRow(.planning, detail: groupSessions.isEmpty
                        ? "Rien de planifié"
                        : "Prochaine : \(DateUtils.relativeLabel(groupSessions[0].startsAt)) \(DateUtils.time.string(from: groupSessions[0].startsAt))")
            }
        }
    }

    private var seriesDetail: String {
        let shared = mySubjects
        guard !shared.isEmpty else { return "Définis d'abord les matières" }
        var completed = 0
        var total = 0
        for code in shared {
            let course = myCourses.first { $0.code.uppercased() == code.uppercased() }
            let boards = GroupProgressBuilder.seriesBoards(subject: code, group: group, course: course, meID: app.social.userID)
            total += boards.count
            completed += boards.filter { $0.me?.isComplete ?? false }.count
        }
        return total == 0 ? "Aucune série connue" : "\(completed)/\(total) séries terminées par toi"
    }

    private var timeDetail: String {
        guard let me = group.members.first(where: \.isMe) else { return "Connecte-toi pour te comparer" }
        let leader = group.sortedMembers.first
        if let leader, !leader.isMe {
            return "Toi \(me.weeklyLabel) · \(leader.shownName) \(leader.weeklyLabel)"
        }
        return "Toi \(me.weeklyLabel) · en tête"
    }

    private func pageRow(_ page: GroupPageRoute.Page, detail: String) -> some View {
        NavigationLink(value: GroupPageRoute(groupID: group.id, page: page)) {
            HStack(spacing: Layout.block) {
                Image(systemName: page.icon)
                    .font(.subheadline)
                    .foregroundStyle(Theme.accentInk)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: Layout.micro) {
                    Text(page.title).font(.subheadline.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Layout.inline)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, Layout.inline)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Matières

    /// Les matières du groupe — la liste, pas l'avancement : celui-ci a sa page.
    private var subjectsCard: some View {
        Card(title: "Matières", icon: "books.vertical.fill",
             trailing: group.subjectCodes.isEmpty ? nil : "\(group.subjectCodes.count)") {
            VStack(alignment: .leading, spacing: Layout.block) {
                if group.subjectCodes.isEmpty {
                    Text("Aucune matière définie. Sans elles, rien n'est comparé ni partagé.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // Des pastilles, une par matière : les miennes en couleur, les
                    // autres en retrait. Un tap ouvre le détail par membre.
                    FlowLayout(spacing: Layout.inline) {
                        ForEach(group.subjectCodes, id: \.self) { code in
                            let course = myCourses.first { $0.code.uppercased() == code.uppercased() }
                            NavigationLink(value: GroupSubjectRoute(groupID: group.id, subject: code)) {
                                HStack(spacing: Layout.snug) {
                                    if let course {
                                        Circle().fill(Color(hex: course.colorHex)).frame(width: 8, height: 8)
                                    }
                                    Text(code).font(.caption.weight(.semibold))
                                    if course == nil {
                                        Image(systemName: "eye.slash").font(.caption2)
                                    }
                                }
                                .padding(.horizontal, Layout.control)
                                .padding(.vertical, Layout.snug)
                                .background(course == nil ? Color.secondary.badgeFill : Theme.accent.badgeFill, in: Capsule())
                                .foregroundStyle(course == nil ? Color.secondary : Theme.accent.badgeInk)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(code)\(course == nil ? ", non suivie par toi" : "")")
                            .accessibilityHint("Voir le détail par membre")
                        }
                    }
                    if !otherSubjects.isEmpty {
                        Text("Les matières grisées ne sont pas dans tes cours : elles ne sont pas comparées.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Button {
                    showingSubjects = true
                } label: {
                    Label(group.subjectCodes.isEmpty ? "Définir les matières" : "Gérer les matières",
                          systemImage: "slider.horizontal.3")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: Invitation

    private var inviteCard: some View {
        Card(title: "Inviter", icon: "person.badge.plus") {
            VStack(alignment: .leading, spacing: Layout.block) {
                if !group.details.isEmpty {
                    Text(group.details)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: Layout.control) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Code d'invitation")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(group.inviteCode)
                            .font(.headline.monospaced())
                    }
                    Spacer()
                    Button {
                        showingInvite = true
                    } label: {
                        Label("Partager", systemImage: "square.and.arrow.up")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                }

                HStack(spacing: Layout.snug) {
                    Image(systemName: app.settings.isSupabaseConfigured ? "checkmark.icloud.fill" : "icloud.slash")
                        .foregroundStyle(app.settings.isSupabaseConfigured ? Color.green.accessibleMark : .secondary)
                    Text(app.settings.isSupabaseConfigured
                         ? (group.remoteID == nil
                            ? "Pas encore synchronisé — lance une synchronisation"
                            : "Synchronisé avec le groupe")
                         : "Mode local — la synchronisation nécessite Supabase")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // Un groupe créé hors ligne (ou par une version antérieure) n'existe
                // que sur cet appareil : aucune synchronisation ne peut le faire
                // apparaître, puisque le serveur ne le connaît pas. Il faut le
                // **publier**. C'est le seul moyen de réparer un groupe local.
                if group.remoteID == nil, app.social.isSignedIn {
                    Button {
                        publish()
                    } label: {
                        if isPublishing {
                            HStack(spacing: Layout.snug) {
                                ProgressView()
                                Text("Publication…")
                            }
                            .font(.caption)
                        } else {
                            Label("Publier ce groupe pour l'inviter", systemImage: "icloud.and.arrow.up")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isPublishing)
                }

                if let inviteError {
                    Label(inviteError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.orange.accessibleInk)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let syncMessage {
                    Text(syncMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Zone sensible

    private var dangerZone: some View {
        VStack(spacing: Layout.control) {
            Button(role: .destructive) {
                showingLeave = true
            } label: {
                Label(isLeaving ? "Sortie…" : "Quitter le groupe",
                      systemImage: "rectangle.portrait.and.arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isLeaving)

            // Supprimer n'est proposé qu'à celles et ceux qui le peuvent : créer le
            // groupe, et le supprimer, sont réservés au créateur côté serveur.
            if group.remoteID == nil || iAmAdmin {
                Button(role: .destructive) {
                    showingDelete = true
                } label: {
                    Label("Supprimer le groupe", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var leaveWarning: String {
        let admins = group.members.filter(\.isAdmin)
        if iAmAdmin, admins.count <= 1, group.members.count > 1 {
            return "Tu es le seul administrateur : plus personne ne pourra gérer les membres après ton départ."
        }
        return "Tu n'apparaîtras plus dans ce groupe. Ton historique de temps reste sur ton appareil."
    }

    // MARK: Actions

    /// Crée le groupe côté serveur et retient son identifiant distant.
    ///
    /// Publier ne duplique rien : on n'arrive ici que si `remoteID` est vide, donc
    /// le groupe n'existe pas encore en face.
    private func publish() {
        isPublishing = true
        inviteError = nil
        Task {
            do {
                let remote = try await app.social.createGroup(
                    name: group.name,
                    description: group.details,
                    courseCode: "",
                    courseCodes: group.subjectCodes,
                    displayName: group.members.first(where: \.isMe)?.displayName ?? "Moi")
                await MainActor.run {
                    group.remoteID = remote.id
                    if !remote.inviteCode.isEmpty { group.inviteCode = remote.inviteCode }
                    if let me = group.members.first(where: \.isMe) { me.role = .admin }
                    group.isAdmin = true
                    try? context.save()
                    isPublishing = false
                }
            } catch {
                await MainActor.run {
                    isPublishing = false
                    inviteError = "Publication impossible — \(GroupSync.explain(error))"
                }
            }
        }
    }

    /// Quitte le groupe : mon adhésion distante, puis le groupe local.
    ///
    /// Le local part **après** le distant, comme pour la suppression : si on
    /// effaçait d'abord, on perdrait l'identifiant distant et on resterait membre
    /// côté serveur sans jamais pouvoir le voir.
    private func leave() {
        isLeaving = true
        Task {
            var failure: String?
            if let remoteID = group.remoteID, app.social.isSignedIn {
                do {
                    try await app.social.leaveGroup(groupID: remoteID)
                } catch {
                    failure = GroupSync.explain(error)
                }
            }
            await MainActor.run {
                isLeaving = false
                if let failure {
                    inviteError = "Sortie impossible — \(failure)"
                    return
                }
                context.delete(group)
                try? context.save()
                Haptics.removed()
                dismiss()
            }
        }
    }

    /// Supprime le groupe partout. Le serveur part en premier, pour la même raison.
    private func deleteGroup() {
        Task {
            if let remoteID = group.remoteID, app.social.isSignedIn {
                try? await app.social.deleteGroup(id: remoteID)
            }
            await MainActor.run {
                context.delete(group)
                try? context.save()
                Haptics.removed()
                dismiss()
            }
        }
    }
}
