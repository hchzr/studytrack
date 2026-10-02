import Foundation
import SwiftData
import Observation

/// L'accueil automatique : une connexion EPFL, et l'app fait le reste.
///
/// Une fois Moodle connecté :
///   1. les cours du semestre en cours sont lus dans les inscriptions Moodle et
///      créés (ou retrouvés, s'ils existent déjà) — reliés à leur page Moodle ;
///   2. Courseware, MediaSpace et Explique sont connectés en silence, s'ils le
///      peuvent (`SiteAutoLogin`) — ils servent à la chaîne d'import ;
///   3. chaque cours est importé : théorie, séries, échéances, consignes de la
///      semaine — sans relecture : l'étudiant·e voit le résultat cours par
///      cours, et tout reste modifiable ensuite ;
///   4. les énoncés des séries se lisent en arrière-plan.
///
/// Avant, il fallait choisir sa section, importer un fichier d'horaire ou
/// saisir chaque cours, relier Moodle, puis relire un import : l'accueil était
/// la partie la moins claire de l'app.
@MainActor
@Observable
final class OnboardingAutoSetup {

    enum Phase: Equatable {
        case idle
        case working(String)
        case done
        case failed(String)
    }

    struct Line: Identifiable, Equatable {
        let id: String
        var code: String
        var name: String
        var status: String
        var finished = false
        var failed = false
    }

    private(set) var phase: Phase = .idle
    private(set) var lines: [Line] = []
    /// Les autres sites connectés en passant (« Courseware, MediaSpace »).
    private(set) var extraSites: [String] = []

    var isWorking: Bool { if case .working = phase { return true } else { return false } }

    func run(context: ModelContext, settings: SettingsStore, term: AcademicTerm) async {
        guard !isWorking else { return }
        phase = .working("Connexion à Moodle…")
        let client = MoodleClient()
        guard await client.ensureSignedIn() else {
            phase = .failed("Moodle ne te reconnaît pas encore. Réessaie la connexion, ou continue sans Moodle.")
            return
        }
        ConnectionCenter.shared.report(.moodle, .connected)

        // Les autres sites pendant que Moodle travaille : ils ne partagent que
        // les cookies EPFL, pas le navigateur.
        let others = Task { @MainActor in await SiteAutoLogin.connectAll() }

        phase = .working("Lecture de tes cours sur Moodle…")
        var refs = (try? await client.enrolled(classification: "inprogress")) ?? []
        if MoodleOnboarding.courses(from: refs).isEmpty {
            // Hors semestre (ou cours mal datés sur Moodle) : tous les cours,
            // l'étudiant·e décochera ceux qu'il ne suit plus.
            refs = (try? await client.enrolled()) ?? []
        }
        let planned = MoodleOnboarding.courses(from: refs)
        guard !planned.isEmpty else {
            phase = .failed("Aucun cours EPFL trouvé dans tes inscriptions Moodle. Ajoute-les depuis ton horaire ou à la main.")
            return
        }

        // 1. Les cours, créés ou retrouvés.
        let existing = (try? context.fetch(FetchDescriptor<Course>())) ?? []
        let palette = Theme.coursePalette
        var targets: [(Course, MoodleCourseRef)] = []
        for (index, plan) in planned.enumerated() {
            let course: Course
            if let known = existing.first(where: { MoodleCourseMatcher.baseCode($0.code) == plan.code }) {
                course = known
            } else {
                course = Course(code: plan.code, name: plan.name,
                                colorHex: palette[(existing.count + index) % palette.count],
                                term: term,
                                sectionCode: settings.sectionCode)
                context.insert(course)
            }
            if course.term == nil { course.term = term }
            course.isTracked = true
            // Relié à **sa** page Moodle : la mise à jour automatique et les
            // imports suivants n'ont plus à chercher la bonne section.
            if !course.contentSources.contains(plan.ref.url.absoluteString) {
                course.contentSources = course.contentSources + [plan.ref.url.absoluteString]
            }
            targets.append((course, plan.ref))
        }
        try? context.save()
        lines = targets.map { course, ref in
            Line(id: course.id.uuidString, code: course.displayCode, name: course.name, status: "en attente")
        }

        // 2. Le contenu, cours par cours.
        var imported: [Course] = []
        for (index, (course, ref)) in targets.enumerated() {
            phase = .working("Import de \(course.displayCode) · \(index + 1) sur \(targets.count)")
            update(course) { $0.status = "lecture de la page Moodle…" }
            do {
                let snapshot = try await client.snapshot(of: ref)
                let outcome = await CourseImportPipeline.draft(from: snapshot,
                                                               termStart: course.term?.startDate ?? term.startDate,
                                                               totalWeeks: course.term?.totalWeeks ?? term.totalWeeks,
                                                               settings: settings) { [weak self] step in
                    self?.update(course) { $0.status = step }
                }
                let draft = outcome.draft
                if draft.isEmpty {
                    update(course) {
                        $0.status = snapshot.activityCount == 0 ? "vide sur Moodle pour l'instant" : "rien à suivre pour l'instant"
                        $0.finished = true
                    }
                } else {
                    ContentDraftWriter.apply(draft, to: course, context: context)
                    try? context.save()
                    imported.append(course)
                    update(course) {
                        $0.status = ContentDraftSummary.line(draft)
                        $0.finished = true
                    }
                }
            } catch {
                update(course) {
                    $0.status = "à importer plus tard (\(error.localizedDescription))"
                    $0.finished = true
                    $0.failed = true
                }
            }
        }

        // 3. Les énoncés, en arrière-plan ; la mise à jour automatique prend le relais.
        if !imported.isEmpty {
            SeriesAutoReading.start(courses: imported, context: context, settings: settings)
        }
        settings.contentLastRefresh = Date()

        extraSites = await others.value.filter(\.value).map(\.key.label).sorted()
        phase = .done
    }

    private func update(_ course: Course, _ change: (inout Line) -> Void) {
        guard let index = lines.firstIndex(where: { $0.id == course.id.uuidString }) else { return }
        change(&lines[index])
    }
}
