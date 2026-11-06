import SwiftUI
import SwiftData

/// Où mène un résultat de recherche — **l'élément lui-même**, pas sa page.
///
/// L'ancienne recherche avait son onglet et menait au mieux à la liste des
/// séries du cours : trouver « 3.4 » demandait encore de chercher la 3.4. Elle
/// vit maintenant dans « Cours » (tirer vers le bas, ou la barre du bas), cherche
/// aussi dans les énoncés et les annales, et ouvre l'exercice, la théorie,
/// l'évaluation trouvés.
enum SearchDestination: Hashable {
    case course(UUID, CourseDetailView.Section, target: UUID?)
    case history
    case tasks
    case life
    case group(UUID)

    static func of(_ hit: SearchHit, courses: [Course]) -> SearchDestination? {
        let id = hit.document.id
        func uuid(after prefix: String) -> UUID? {
            id.hasPrefix(prefix) ? UUID(uuidString: String(id.dropFirst(prefix.count))) : nil
        }
        var courseID = uuid(after: "course.")
        if courseID == nil, let code = hit.document.courseCode {
            courseID = courses.first { $0.displayCode == code || $0.code == code }?.id
        }
        switch hit.kind {
        case .course:
            return courseID.map { .course($0, .exercises, target: nil) }
        case .series:
            return courseID.map { .course($0, .exercises, target: nil) }
        case .exercise:
            return courseID.map { .course($0, .exercises, target: uuid(after: "exercise.")) }
        case .theory:
            return courseID.map { .course($0, .theory, target: uuid(after: "theory.")) }
        case .exam:
            return courseID.map { .course($0, .exams, target: nil) }
        case .session: return .history
        case .task: return .tasks
        case .milestone: return .life
        case .group: return uuid(after: "group.").map { .group($0) }
        }
    }
}

/// Les résultats, rangés par nature, dans l'onglet « Cours ».
struct SearchResultsList: View {
    let query: String
    let index: [SearchDocument]
    var open: (SearchHit) -> Void

    var body: some View {
        let hits = SearchEngine.search(query, in: index)
        if hits.isEmpty {
            ContentUnavailableView("Aucun résultat",
                                   systemImage: "magnifyingglass",
                                   description: Text(SearchEngine.summary([], query: query)))
                .padding(.top, 40)
        } else {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(SearchEngine.grouped(hits), id: \.kind) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.kind.label)
                            .font(.caption.weight(.semibold))
                            .textCase(.uppercase)
                            .tracking(1)
                            .foregroundStyle(Carnet.inkSecondary)
                        CarnetSheet {
                            ForEach(Array(group.hits.enumerated()), id: \.element.id) { offset, hit in
                                Button { open(hit) } label: { row(hit) }
                                    .buttonStyle(.plain)
                                if offset < group.hits.count - 1 { CarnetRule(inset: 46) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func row(_ hit: SearchHit) -> some View {
        HStack(spacing: Layout.control) {
            Image(systemName: hit.kind.icon)
                .font(.footnote)
                .foregroundStyle(Theme.accent.accessibleMark)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.document.title)
                    .font(.subheadline)
                    .foregroundStyle(Carnet.ink)
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
            // un mot de son énoncé semble être un faux positif.
            if hit.match != .title {
                Pill(text: hit.match.label, color: .secondary)
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Carnet.inkTertiary)
        }
        .padding(.horizontal, Carnet.rowInset)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(hit.document.title). \(hit.document.subtitle)")
    }
}

/// L'index de recherche, construit à la demande (la première lettre tapée).
@MainActor
enum SearchIndex {
    static func build(context: ModelContext) -> [SearchDocument] {
        let courses = (try? context.fetch(FetchDescriptor<Course>(sortBy: [SortDescriptor(\.code)]))) ?? []
        var sessionsDescriptor = FetchDescriptor<StudySession>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        sessionsDescriptor.fetchLimit = SearchIndexBuilder.sessionLimit
        let sessions = (try? context.fetch(sessionsDescriptor)) ?? []
        let tasks = (try? context.fetch(FetchDescriptor<LinkedTask>())) ?? []
        let milestones = (try? context.fetch(FetchDescriptor<AcademicMilestone>(sortBy: [SortDescriptor(\.date)]))) ?? []
        let groups = (try? context.fetch(FetchDescriptor<StudyGroup>(sortBy: [SortDescriptor(\.name)]))) ?? []
        return SearchIndexBuilder.documents(courses: courses, sessions: sessions, tasks: tasks,
                                            milestones: milestones, groups: groups)
    }
}
