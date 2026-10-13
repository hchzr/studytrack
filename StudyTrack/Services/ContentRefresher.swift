import Foundation
import SwiftData

/// Relit Moodle et Botafogo **tout seul**, pour les cours déjà importés.
///
/// Sans elle, la série 4 publiée mardi n'existait dans l'app que si l'on
/// pensait à réimporter. Au passage au premier plan, au plus toutes les douze
/// heures : chaque cours relié à Moodle (son adresse est dans ses sources) ou à
/// Botafogo est relu, et ce qui est **nouveau** est ajouté.
///
/// Un seul appareil s'en charge (`CloudRelay.refreshIsDue`) : la relecture est
/// réclamée dans iCloud avant de commencer.
///
/// Prudente par construction :
///   • rien n'est supprimé (`ContentDraftWriter` n'efface jamais) ;
///   • une semaine corrigée à la main n'est pas réécrite (`updateWeeks: false`) ;
///   • sans connexion Moodle valide, on n'insiste pas : pas de fenêtre de
///     connexion surgie de nulle part, l'écran d'import le dira.
@MainActor
enum ContentRefresher {
    static let interval: TimeInterval = 12 * 3600
    private static var running = false

    static func refreshIfDue(context: ModelContext, settings: SettingsStore, now: Date = Date()) async {
        guard settings.contentAutoRefresh, !running else { return }
        // Un seul appareil relit : l'iPad ouvert une heure après l'iPhone ne
        // relit pas Moodle (ni ne repaie l'IA) — ce qui a été ajouté arrive
        // par iCloud. Sauf si la surveillance d'ici vient de trouver du neuf.
        let forced = MoodleWatcher.hasPendingNews
        guard forced || CloudRelay.refreshIsDue(localLast: settings.contentLastRefresh,
                                                claim: CloudRelay.moodleRefreshClaim(),
                                                device: CloudRelay.deviceID,
                                                interval: interval, now: now) else { return }
        CloudRelay.claimMoodleRefresh(now: now)
        MoodleWatcher.hasPendingNews = false
        running = true
        defer { running = false }

        let courses = ((try? context.fetch(FetchDescriptor<Course>())) ?? []).filter(\.isTracked)
        let moodleCourses = courses.filter { MoodleCourseMatcher.linkedID(in: $0.contentSources) != nil }
        // Un cours lié à Moodle passe par la chaîne d'import, qui lit Botafogo
        // elle-même quand il le faut : pas de seconde lecture.
        let botafogoCourses = courses.compactMap { course -> (Course, URL)? in
            guard MoodleCourseMatcher.linkedID(in: course.contentSources) == nil, let link = course.contentSources.compactMap(URL.init(string:))
                    .first(where: { ContentSource.detect(host: $0.host) == .botafogo }) else { return nil }
            return (course, link)
        }
        guard !moodleCourses.isEmpty || !botafogoCourses.isEmpty else {
            settings.contentLastRefresh = now
            return
        }

        var news: [String] = []

        if !moodleCourses.isEmpty {
            let client = MoodleClient()
            // La session Moodle de l'app expire en quelques jours : on se
            // reconnecte d'abord sans rien afficher (Microsoft s'en souvient),
            // sinon la mise à jour était sautée en silence pendant des semaines.
            await SchoolConnect.shared.ensure(.moodle, prompting: false)
            if await client.ensureSignedIn() {
                let enrolled = (try? await client.enrolled()) ?? []
                for course in moodleCourses {
                    guard case .unique(let ref)? = try? await client.resolve(course, enrolled: enrolled),
                          let snapshot = try? await client.snapshot(of: ref) else { continue }
                    let draft = await CourseImportPipeline.draft(from: snapshot, termStart: course.term?.startDate,
                                                                 totalWeeks: course.term?.totalWeeks ?? 14, settings: settings).draft
                    if let line = apply(draft, to: course, context: context) { news.append(line) }
                }
            } else {
                AppLog.record(.info, "import", "Mise à jour Moodle sautée : reconnexion nécessaire")
            }
        }

        for (course, link) in botafogoCourses {
            guard let draft = try? await BotafogoClient.draft(at: link, termStart: course.term?.startDate,
                                                              totalWeeks: course.term?.totalWeeks ?? 14) else { continue }
            if let line = apply(draft, to: course, context: context) { news.append(line) }
        }

        try? context.save()
        settings.contentLastRefresh = now
        // Une série apparue sur Moodle arrive avec son énoncé lu.
        news.append(contentsOf: await SeriesAutoReader.shared.readPending(courses: courses, context: context, settings: settings))
        if !news.isEmpty {
            settings.contentRefreshNews = news.joined(separator: " · ")
            AppLog.record(.info, "import", "Mise à jour automatique", detail: settings.contentRefreshNews)
        }
    }

    /// Écrit ce qui est nouveau ; rend « MATH-101 : 1 série » s'il y en a.
    private static func apply(_ draft: ContentDraft, to course: Course, context: ModelContext) -> String? {
        guard !draft.isEmpty else { return nil }
        let result = ContentDraftWriter.apply(draft, to: course, context: context, updateWeeks: false)
        var parts: [String] = []
        if result.seriesAdded > 0 { parts.append("\(result.seriesAdded) série\(result.seriesAdded > 1 ? "s" : "")") }
        if result.theoryAdded > 0 { parts.append("\(result.theoryAdded) théorie") }
        return parts.isEmpty ? nil : "\(course.displayCode) : " + parts.joined(separator: ", ")
    }
}
