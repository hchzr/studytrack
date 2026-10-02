#if DEBUG
import Foundation
import SwiftData

/// `-dumpAIPayloads` : relit les cours Moodle de l'app **sans rien écrire**,
/// et garde ce que le modèle reçoit pour chacun (`Documents/ai-eval/`), ainsi
/// que sa réponse. Sert à comparer des modèles sur de vrais cours ; jamais
/// dans une version publiée.
@MainActor
enum AIPayloadDump {
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ai-eval")
    }

    static var isActive: Bool { PreviewLaunch.isSet(PreviewLaunch.dumpAIPayloadsFlag) }

    static func run(container: ModelContainer, settings: SettingsStore) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        status("démarrage")
        let context = ModelContext(container)
        let courses = ((try? context.fetch(FetchDescriptor<Course>())) ?? [])
            .filter { MoodleCourseMatcher.linkedID(in: $0.contentSources) != nil }
        let client = MoodleClient()
        guard await client.ensureSignedIn() else { status("échec : Moodle non connecté"); return }
        let enrolled = (try? await client.enrolled()) ?? []
        for (index, course) in courses.enumerated() {
            status("\(index + 1)/\(courses.count) \(course.displayCode)")
            guard case .unique(let ref)? = try? await client.resolve(course, enrolled: enrolled),
                  let snapshot = try? await client.snapshot(of: ref) else { continue }
            current = course.displayCode
            _ = await CourseImportPipeline.draft(from: snapshot, termStart: course.term?.startDate,
                                                 totalWeeks: course.term?.totalWeeks ?? 14, settings: settings)
        }
        status("fini : \(courses.count) cours")
    }

    /// Le cours en cours de relecture (nomme le fichier).
    static var current = "cours"

    /// Appelé par `MoodleCourseAIService` avec ce qu'il envoie au modèle.
    static func record(payload: [String: Any]) {
        guard isActive, let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: directory.appendingPathComponent("\(current).payload.json"))
    }

    static func record(answer raw: String) {
        guard isActive else { return }
        try? Data(raw.utf8).write(to: directory.appendingPathComponent("\(current).answer.json"))
    }

    private static func status(_ text: String) {
        try? Data((text + "\n").utf8).write(to: directory.appendingPathComponent("status.txt"))
        AppLog.record(.info, "eval", text)
    }
}
#endif
