import Foundation
import SwiftData

/// Relit Moodle **depuis le Mac**, comme `ContentRefresher` sur l'iPhone.
///
/// La série 6 d'algèbre linéaire, publiée sur Moodle, n'arrivait jamais dans
/// l'app : seule l'iPhone relisait, et seulement avec une session Moodle encore
/// valide — ce qui, au bout de quelques jours, n'est plus le cas. Le Mac, lui,
/// se reconnecte sans rien afficher (`SchoolConnect`) : c'est lui qui relit.
///
/// Mêmes précautions que sur l'iPhone : rien n'est supprimé, une semaine
/// corrigée à la main n'est pas réécrite, une seule relecture pour tous les
/// appareils (`CloudRelay.refreshIsDue`). Les règles seules (`MoodleCourseAnalyzer`),
/// sans modèle : elles suffisent à voir une série de plus.
@MainActor
enum MacContentRefresher {
    static let interval: TimeInterval = 6 * 3600
    private static let lastKey = "mac.contentLastRefresh"
    private static var running = false

    static func refreshIfDue(context: ModelContext, force: Bool = false, now: Date = Date()) async {
        guard !running else { return }
        let last = UserDefaults.standard.object(forKey: lastKey) as? Date
        guard force || CloudRelay.refreshIsDue(localLast: last, claim: CloudRelay.moodleRefreshClaim(),
                                               device: CloudRelay.deviceID, interval: interval, now: now) else { return }
        let courses = ((try? context.fetch(FetchDescriptor<Course>())) ?? [])
            .filter { $0.isTracked && MoodleCourseMatcher.linkedID(in: $0.contentSources) != nil }
        guard !courses.isEmpty else { return }
        running = true
        defer { running = false }

        await SchoolConnect.shared.ensure(.moodle, prompting: false)
        guard SchoolConnect.shared.state(.moodle) == .connected else {
            AppLog.record(.info, "import", "Mise à jour Moodle sautée : Moodle attend une connexion")
            return
        }
        CloudRelay.claimMoodleRefresh(now: now)
        let client = SiteHub.shared.moodle
        var news: [String] = []
        for course in courses {
            guard let id = MoodleCourseMatcher.linkedID(in: course.contentSources) else { continue }
            let ref = MoodleCourseRef(id: id, fullname: course.name, shortname: course.code)
            let snapshot: MoodleCourseSnapshot
            do { snapshot = try await client.snapshot(of: ref) } catch {
                trace("\(course.displayCode) : lecture impossible (\(error))")
                continue
            }
            let draft = MoodleCourseAnalyzer.draft(from: snapshot, termStart: course.term?.startDate,
                                                   totalWeeks: course.term?.totalWeeks ?? 14)
            guard !draft.isEmpty else { trace("\(course.displayCode) : rien lu"); continue }
            let result = ContentDraftWriter.apply(draft, to: course, context: context, updateWeeks: false)
            trace("\(course.displayCode) : \(draft.seriesCount) séries lues, \(result.seriesAdded) ajoutées")
            if result.seriesAdded > 0 {
                news.append("\(course.displayCode) : \(result.seriesAdded) série\(result.seriesAdded > 1 ? "s" : "")")
            }
        }
        try? context.save()
        UserDefaults.standard.set(now, forKey: lastKey)
        if !news.isEmpty {
            AppLog.record(.info, "import", "Mise à jour automatique (Mac)", detail: news.joined(separator: " · "))
        }
    }

    private static func trace(_ line: String) {
        #if DEBUG
        FileHandle.standardError.write(Data("REFRESH \(line)\n".utf8))
        #endif
    }
}
