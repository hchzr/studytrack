import SwiftUI
import SwiftData

/// Ce qui échappe au suivi, et comment le rattraper.
///
/// L'app affichait ce qu'elle contenait ; elle ne disait nulle part ce qui lui
/// **manquait**. Un cours sans série, une série sans exercice, une évaluation
/// jamais saisie passaient inaperçus. « Suivre tout » suppose de voir les trous.
struct CoverageView: View {
    @Environment(AppContainer.self) private var app
    @Query(sort: \Course.code) private var courses: [Course]
    @Query private var terms: [AcademicTerm]
    @Query private var events: [LinkedCalendarEvent]

    @State private var showingOnlyProblems = true
    @State private var showingImport = false

    private var report: CoverageReport {
        CoverageBuilder.report(courses: courses,
                               term: AcademicTerm.resolve(from: terms),
                               hasTimetable: !events.isEmpty)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                scoreCard
                if report.allFindings.isEmpty {
                    EmptyCard(icon: "checkmark.seal.fill",
                              title: "Suivi complet",
                              message: "Aucun manque : chaque cours a du contenu, des séries avec leurs exercices, des corrections à jour et ses évaluations. Rien n'échappe à l'app.",
                              actionTitle: nil,
                              action: nil)
                } else {
                    ForEach(report.populatedCategories) { category in
                        categoryCard(category)
                    }
                }
                coursesCard
            }
            .padding()
            .adaptiveColumn()
        }
        .background(Carnet.ground.ignoresSafeArea())
        .carnetBackground()
        .navigationTitle("Couverture du suivi")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingImport) {
            ImportSheet(defaultSectionCode: app.settings.sectionCode)
        }
    }

    // MARK: Score

    private var scoreCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Layout.block) {
                HStack(alignment: .firstTextBaseline, spacing: Layout.control) {
                    Text("\(Int((report.coverage * 100).rounded())) %")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(coverageTint)
                    Spacer(minLength: Layout.inline)
                    if !report.allFindings.isEmpty {
                        VStack(alignment: .trailing, spacing: Layout.tight) {
                            Pill(text: "\(report.count(.blocking)) à corriger",
                                 color: report.count(.blocking) > 0 ? .red : .secondary)
                            Pill(text: "\(report.count(.warning)) incomplets",
                                 color: report.count(.warning) > 0 ? .orange : .secondary)
                            Pill(text: "\(report.count(.info)) à compléter", color: .secondary)
                        }
                    }
                }

                LabeledProgress(title: "Cours sans aucun manque",
                                progress: report.coverage,
                                color: coverageTint,
                                countLabel: "\(report.healthyCourses)/\(report.trackedCount)")

                Text(scoreExplanation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var coverageTint: Color {
        switch report.coverage {
        case 1: return .green
        case 0.6...: return .yellow
        default: return .orange
        }
    }

    private var scoreExplanation: String {
        guard report.trackedCount > 0 else {
            return "Aucun cours suivi pour l'instant."
        }
        if report.isComplete {
            return "Tout est complet. Les remarques de confort ne comptent pas dans ce pourcentage : seuls les manques réels le font baisser."
        }
        return "Part des cours suivis qui n'ont ni manque bloquant ni suivi incomplet. Les simples suggestions ne font pas baisser ce chiffre."
    }

    // MARK: Manques

    private func categoryCard(_ category: CoverageCategory) -> some View {
        Card(title: category.label, icon: category.icon,
             trailing: "\(report.findings(in: category).count)") {
            VStack(spacing: 0) {
                let items = report.findings(in: category)
                ForEach(items) { finding in
                    findingRow(finding)
                    if finding.id != items.last?.id {
                        Divider().padding(.vertical, Layout.snug)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func findingRow(_ finding: CoverageFinding) -> some View {
        let content = HStack(alignment: .top, spacing: Layout.control) {
            Image(systemName: finding.severity.icon)
                .font(.footnote)
                .foregroundStyle(tint(finding.severity))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                // Le cours concerné est nommé **à côté** du constat : sans ça,
                // « 1 exercice fait non corrigé » et « 2 exercices faits non
                // corrigés » sont deux lignes indiscernables venues de deux cours.
                HStack(spacing: Layout.snug) {
                    Text(finding.title)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    if let code = finding.courseCode {
                        Pill(text: code, color: Theme.accent)
                    }
                }
                Text(finding.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Layout.inline)
        }
        .contentShape(Rectangle())

        if let code = finding.courseCode,
           let course = courses.first(where: { $0.displayCode == code }) {
            NavigationLink {
                CourseDetailView(course: course)
            } label: {
                content
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(finding.title). \(finding.detail)")
        } else {
            Button {
                act(on: finding)
            } label: {
                content
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(finding.title). \(finding.detail)")
        }
    }

    private func tint(_ severity: CoverageSeverity) -> Color {
        switch severity {
        case .blocking: return .red.accessibleInk
        case .warning: return .orange.accessibleInk
        case .info: return .secondary
        }
    }

    private func act(on finding: CoverageFinding) {
        // Les seuls constats sans cours sont ceux du socle : ils mènent aux deux
        // gestes qui les règlent.
        switch finding.id {
        case "socle.horaire": showingImport = true
        case "socle.semestre", "socle.cours": app.router.showingProfile = true
        default: break
        }
    }

    // MARK: Par cours

    /// Le détail par cours, pour vérifier un cours précis sans parcourir les familles.
    private var coursesCard: some View {
        Card(title: "Par cours", icon: "books.vertical.fill") {
            VStack(spacing: 0) {
                let rows = showingOnlyProblems
                    ? report.courses.filter { $0.isTracked && !$0.findings.isEmpty }
                    : report.courses.filter(\.isTracked)

                if rows.isEmpty {
                    Text("Aucun cours à afficher.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(rows) { course in
                    HStack(spacing: Layout.control) {
                        Image(systemName: course.isHealthy ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(course.isHealthy ? Color.green.accessibleMark : Color.orange.accessibleMark)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(course.code).font(.subheadline.weight(.medium))
                            Text(course.name)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: Layout.inline)
                        Text(course.findings.isEmpty ? "complet" : "\(course.findings.count) manque\(course.findings.count > 1 ? "s" : "")")
                            .font(.caption)
                            .foregroundStyle(course.isHealthy ? Color.green.accessibleInk : Color.orange.accessibleInk)
                    }
                    .padding(.vertical, Layout.snug)
                    if course.id != rows.last?.id {
                        Divider()
                    }
                }

                Toggle("Masquer les cours complets", isOn: $showingOnlyProblems)
                    .font(.caption)
                    .padding(.top, Layout.block)
            }
        }
    }
}
