import SwiftUI
import SwiftData

/// Où mène un résultat de recherche.
enum SearchRoute: Hashable {
    case course(UUID, CourseDetailView.Section)
    case history
    case tasks
    case life
    case group(UUID)
}

/// Recherche dans tout ce que l'app contient : cours, séries, exercices, théorie,
/// évaluations, sessions, tâches, échéances, groupes.
///
/// Le manque était quotidien : retrouver « le théorème de la moyenne » demandait
/// de se souvenir du cours, puis de l'onglet, puis de la section. Une barre de
/// recherche unique répond à la place.
struct SearchView: View {
    /// Requête déjà saisie — utilisé par les captures du simulateur, qui ne
    /// peuvent pas taper dans la barre de recherche.
    var initialQuery: String = ""

    @Environment(\.modelContext) private var context
    @Query(sort: \Course.code) private var courses: [Course]
    @Query(sort: \StudySession.startedAt, order: .reverse) private var sessions: [StudySession]
    @Query private var tasks: [LinkedTask]
    @Query(sort: \AcademicMilestone.date) private var milestones: [AcademicMilestone]
    @Query(sort: \StudyGroup.name) private var groups: [StudyGroup]

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var path = NavigationPath()
    /// L'index est construit **une fois par affichage** : le refaire à chaque
    /// frappe ferait payer la lecture de plusieurs centaines de lignes par lettre.
    @State private var index: [SearchDocument] = []

    private var hits: [SearchHit] { SearchEngine.search(query, in: index) }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if index.isEmpty {
                    ContentUnavailableView("Rien à chercher",
                                           systemImage: "magnifyingglass",
                                           description: nil)
                } else if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    // Avant de taper : tes cours, à un toucher — le plus souvent,
                    // c'est l'un d'eux qu'on cherche.
                    List {
                        Section("Cours") {
                            ForEach(courses.filter(\.isTracked)) { course in
                                NavigationLink(value: SearchRoute.course(course.id, .exercises)) {
                                    HStack(spacing: Layout.control) {
                                        Circle().fill(Carnet.tint(course.colorHex)).frame(width: 8, height: 8)
                                        Text(course.displayCode).font(.subheadline.weight(.semibold))
                                        Text(course.name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                    .adaptiveListColumn()
                } else if hits.isEmpty {
                    ContentUnavailableView("Aucun résultat",
                                           systemImage: "magnifyingglass",
                                           description: Text(SearchEngine.summary([], query: query)))
                } else {
                    resultsList
                }
            }
            .carnetBackground()
            .navigationTitle("Recherche")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Cours, exercice, résumé, tâche…")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
            .navigationDestination(for: SearchRoute.self) { route in
                destination(route)
            }
            .onAppear {
                if query.isEmpty, !initialQuery.isEmpty { query = initialQuery }
                buildIndex()
            }
        }
    }

    // MARK: Résultats

    private var resultsList: some View {
        List {
            ForEach(SearchEngine.grouped(hits), id: \.kind) { group in
                Section(group.kind.label) {
                    ForEach(group.hits) { hit in
                        Button {
                            open(hit)
                        } label: {
                            hitRow(hit)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .adaptiveListColumn()
    }

    private func hitRow(_ hit: SearchHit) -> some View {
        HStack(spacing: Layout.control) {
            Image(systemName: hit.kind.icon)
                .font(.footnote)
                .foregroundStyle(Theme.accent.accessibleMark)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.document.title)
                    .font(.subheadline)
                    .lineLimit(2)
                if !hit.document.subtitle.isEmpty {
                    Text(hit.document.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Layout.inline)
            // Dire **pourquoi** ce résultat sort : sans ça, un exercice trouvé par
            // un mot de sa note de correction semble être un faux positif.
            if hit.match != .title {
                Pill(text: hit.match.label, color: .secondary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(hit.document.title). \(hit.document.subtitle)")
    }

    // MARK: Index

    private func buildIndex() {
        guard index.isEmpty else { return }
        index = SearchIndexBuilder.documents(courses: courses,
                                             sessions: sessions,
                                             tasks: tasks,
                                             milestones: milestones,
                                             groups: groups)
    }

    // MARK: Navigation

    private func open(_ hit: SearchHit) {
        switch hit.kind {
        case .course:
            if let id = identifier(of: hit) { path.append(SearchRoute.course(id, .theory)) }
        case .series, .exercise:
            if let id = identifier(of: hit) { path.append(SearchRoute.course(id, .exercises)) }
        case .theory:
            if let id = identifier(of: hit) { path.append(SearchRoute.course(id, .theory)) }
        case .exam:
            if let id = identifier(of: hit) { path.append(SearchRoute.course(id, .exams)) }
        case .session:
            path.append(SearchRoute.history)
        case .task:
            path.append(SearchRoute.tasks)
        case .milestone:
            path.append(SearchRoute.life)
        case .group:
            if let id = identifier(of: hit) { path.append(SearchRoute.group(id)) }
        }
        Haptics.tap()
    }

    /// Le cours auquel rattacher un résultat : celui du document, sinon celui dont
    /// l'identifiant porte l'UUID.
    private func identifier(of hit: SearchHit) -> UUID? {
        if hit.kind == .group {
            return uuid(in: hit.document.id, prefix: "group.")
        }
        if hit.kind == .course {
            return uuid(in: hit.document.id, prefix: "course.")
        }
        guard let code = hit.document.courseCode else { return nil }
        return courses.first { $0.displayCode == code || $0.code == code }?.id
    }

    private func uuid(in identifier: String, prefix: String) -> UUID? {
        guard identifier.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(identifier.dropFirst(prefix.count)))
    }

    @ViewBuilder
    private func destination(_ route: SearchRoute) -> some View {
        switch route {
        case .course(let id, let section):
            if let course = courses.first(where: { $0.id == id }) {
                CourseDetailView(course: course, initialSection: section)
            }
        case .history:
            SessionHistoryView()
        case .tasks:
            TasksView()
        case .life:
            EPFLLifeView()
        case .group(let id):
            if let group = groups.first(where: { $0.id == id }) {
                GroupSettingsView(group: group)
            }
        }
    }
}
