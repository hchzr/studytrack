#if DEBUG
import Foundation
import SwiftData
import PDFKit

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
        let client = MoodleClient.background
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

    /// `-dumpSeriesPayloads` : pour quelques séries en PDF de chaque cours, ce
    /// que l'app enverrait à `extract-series` (pages en images, texte préparé),
    /// sans l'envoyer — pour mesurer le coût réel de la lecture d'un énoncé.
    static func runSeries(container: ModelContainer, perCourse: Int = 3) async {
        let folder = directory.appendingPathComponent("series")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        status("séries : démarrage")
        let context = ModelContext(container)
        let courses = ((try? context.fetch(FetchDescriptor<Course>())) ?? []).filter(\.isTracked)
        if courses.contains(where: { $0.series.contains { URL(string: $0.urlString)?.host?.contains("moodle") == true } }) {
            _ = await MoodleClient.background.ensureSignedIn()
        }
        var written = 0
        for course in courses {
            var taken = 0
            for series in course.sortedSeries where taken < perCourse {
                guard let url = URL(string: series.urlString), url.scheme?.hasPrefix("http") == true else { continue }
                status("séries : \(course.displayCode) \(series.seriesNumber)")
                let file: URL
                if url.host?.contains("moodle") == true {
                    guard let downloaded = try? await AuthenticatedDownloader.download(url) else { continue }
                    file = downloaded
                } else {
                    guard let (data, _) = try? await URLSession.shared.data(from: url), data.starts(with: Data("%PDF".utf8)) else { continue }
                    file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
                    try? data.write(to: file)
                }
                defer { try? FileManager.default.removeItem(at: file) }
                guard let document = PDFDocument(url: file) else { continue }
                let lines = PDFLayoutExtractor.lines(from: document)
                guard lines.contains(where: { !$0.isEmpty }) else { continue }
                let language = SeriesDocumentInference.languageName(of: lines.map(\.text).joined(separator: "\n"))
                let prepared = SeriesAIParsing.prepareLayout(lines, seriesHint: series.seriesNumber, language: language)
                var body: [String: Any] = ["images": PDFPageRenderer.jpegPages(of: document).map { $0.base64EncodedString() },
                                           "text": prepared, "seriesHint": series.seriesNumber]
                if let language { body["language"] = language }
                guard let data = try? JSONSerialization.data(withJSONObject: body) else { continue }
                try? data.write(to: folder.appendingPathComponent("\(course.displayCode)-\(series.seriesNumber).json"))
                taken += 1
                written += 1
            }
        }
        status("séries : fini, \(written) énoncés")
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
