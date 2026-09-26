import SwiftUI
import SwiftData

/// Destination « avancement d'une matière », adressable par valeur.
///
/// Une valeur plutôt qu'une destination en ligne : c'est ce qui permet d'y arriver
/// depuis la fiche du groupe **et** de l'ouvrir directement au lancement en Debug,
/// pour la capture d'écran.
struct GroupSubjectRoute: Hashable {
    let groupID: UUID
    let subject: String
}

/// Onglet Groupes : mes groupes, leur avancement, la présence et le planning partagé.
struct GroupsView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var app
    @Query(sort: \StudyGroup.name) private var groups: [StudyGroup]

    @State private var showingCreate = false
    @State private var showingJoin = false
    @State private var joinCode = ""
    @State private var isSyncing = false
    @State private var syncMessage: String?
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let syncMessage {
                    Section {
                        Label(syncMessage, systemImage: "person.3.sequence.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if groups.isEmpty {
                    ContentUnavailableView(
                        "Aucun groupe",
                        systemImage: "person.3",
                        description: Text("Créez un groupe d'étude ou rejoignez-en un avec un code d'invitation.")
                    )
                } else {
                    Section("Mes groupes") {
                        ForEach(groups) { group in
                            NavigationLink(value: group) {
                                GroupRow(group: group)
                            }
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .adaptiveListColumn()
            .navigationTitle("Groupes")
            .navigationDestination(for: StudyGroup.self) { group in
                GroupDetailView(group: group)
            }
            .navigationDestination(for: GroupSubjectRoute.self) { route in
                if let group = groups.first(where: { $0.id == route.groupID }) {
                    GroupSubjectProgressView(group: group, subject: route.subject)
                }
            }
            .navigationDestination(for: GroupPageRoute.self) { route in
                if let group = groups.first(where: { $0.id == route.groupID }) {
                    switch route.page {
                    case .members: GroupMembersView(group: group)
                    case .time: GroupStudyTimeView(group: group)
                    case .series: GroupSeriesProgressView(group: group)
                    case .planning: GroupPlanningView(group: group)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ProfileButton() }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        joinCode = ""
                        showingJoin = true
                    } label: {
                        Image(systemName: "person.badge.plus")
                    }
                    .accessibilityLabel("Rejoindre un groupe")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button {
                            Task { await syncNow() }
                        } label: {
                            if isSyncing {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                        }
                        .disabled(isSyncing)
                        .accessibilityLabel("Synchroniser les groupes")
                        Button {
                            showingCreate = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Créer un groupe")
                    }
                }
            }
            .sheet(isPresented: $showingCreate) { CreateGroupView() }
            .sheet(isPresented: $showingJoin) { JoinGroupView(prefilledCode: joinCode) }
            .task {
                // Les données de démonstration ne se créent que sur demande explicite
                // en Debug. Elles ont déjà été injectées chez de vrais utilisateurs
                // quand cet appel était inconditionnel.
                #if DEBUG
                if PreviewLaunch.isSet(PreviewLaunch.seedFlag) {
                    GroupDemoData.seedIfNeeded(context)
                }
                // `-group 0` ouvre directement la fiche d'un groupe : `simctl` ne
                // sait pas taper, et ces écrans ne sont atteignables qu'après deux
                // navigations.
                if let index = PreviewLaunch.int(PreviewLaunch.groupFlag),
                   groups.indices.contains(index) {
                    path.append(groups[index])
                    if let code = PreviewLaunch.string(PreviewLaunch.groupSubjectFlag) {
                        path.append(GroupSubjectRoute(groupID: groups[index].id, subject: code))
                    }
                    if let raw = PreviewLaunch.string(PreviewLaunch.groupPageFlag),
                       let page = GroupPageRoute.Page(rawValue: raw) {
                        path.append(GroupPageRoute(groupID: groups[index].id, page: page))
                    }
                }
                #endif
                if app.social.isSignedIn {
                    await syncNow()
                }
            }
            // Un lien d'invitation ouvert pendant que l'app tourne.
            .onChange(of: app.router.pendingJoinCode) { _, newValue in
                guard let code = newValue else { return }
                joinCode = code
                showingJoin = true
                _ = app.router.consumeJoinCode()
            }
            .onAppear {
                // …et un lien qui a lancé l'app, avant que cet écran n'existe.
                if let code = app.router.consumeJoinCode() {
                    joinCode = code
                    showingJoin = true
                }
            }
        }
    }

    private func syncNow() async {
        isSyncing = true
        defer { isSyncing = false }
        syncMessage = await GroupSync.refresh(context: context,
                                              social: app.social,
                                              settings: app.settings)
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets where index < groups.count {
            context.delete(groups[index])
        }
        try? context.save()
    }
}

/// Ligne de groupe : nom, matières, membres, et ce que j'y ai fait.
struct GroupRow: View {
    let group: StudyGroup

    @Environment(AppContainer.self) private var app

    private var subjects: [String] { group.subjectCodes }

    /// Mon rang au classement de la semaine, quand je suis identifié·e.
    private var myRank: Int? {
        let sorted = group.sortedMembers
        guard let index = sorted.firstIndex(where: \.isMe) else { return nil }
        return index + 1
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Theme.accent.badgeFill).frame(width: 44, height: 44)
                Image(systemName: "person.3.fill")
                    .foregroundStyle(Theme.accent.badgeInk)
            }
            VStack(alignment: .leading, spacing: Layout.tight) {
                Text(group.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: Layout.snug) {
                    Pill(text: "\(group.members.count) membre\(group.members.count > 1 ? "s" : "")",
                         color: .secondary)
                }
                // Une seule ligne de matières, tronquée proprement : au-delà de
                // trois codes, la liste complète n'apporte rien dans une liste.
                if !subjects.isEmpty {
                    Text(subjects.prefix(3).joined(separator: " · ")
                         + (subjects.count > 3 ? " +\(subjects.count - 3)" : ""))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Layout.inline)
            // « 7 séries » comptait les séries de **tous** les membres — un chiffre
            // qui ne veut rien dire pour moi. Mon rang au temps d'étude, si.
            if let rank = myRank {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("#\(rank)")
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(rank == 1 ? Color.yellow.accessibleInk : .primary)
                    Text("sur \(group.members.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [group.name, "\(group.members.count) membres"]
        if !subjects.isEmpty { parts.append("matières : \(subjects.joined(separator: ", "))") }
        if let rank = myRank { parts.append("rang \(rank) sur \(group.members.count) cette semaine") }
        return parts.joined(separator: ", ")
    }
}
