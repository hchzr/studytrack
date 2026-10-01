import Foundation
import CryptoKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Demande au modèle comment ranger un cours Moodle (`MoodleCourseAI`).
///
/// Le service partagé (`analyze-course`) d'abord, le modèle de l'appareil en
/// repli. La réponse est **gardée** pour ce plan de cours : la mise à jour
/// automatique ne redemande que si le cours a changé sur Moodle.
@MainActor
enum MoodleCourseAIService {

    static func hints(for snapshot: MoodleCourseSnapshot, termStart: Date?, totalWeeks: Int,
                      settings: SettingsStore) async -> [String: MoodleAIHint] {
        await analyze(snapshot, termStart: termStart, totalWeeks: totalWeeks, settings: settings).hints
    }

    /// Le cours rangé par le modèle : ses activités, et — quand le plan du cours
    /// et le MOOC sont fournis — les chapitres du MOOC à regarder chaque semaine.
    static func analyze(_ snapshot: MoodleCourseSnapshot, termStart: Date?, totalWeeks: Int,
                        plan: String? = nil, moocs: [ScrapedCourse] = [],
                        settings: SettingsStore) async -> MoodleCourseAI.Answer {
        guard settings.aiExtractionEnabled else { return .init() }
        let payload = MoodleCourseAI.payload(for: snapshot, termStart: termStart, totalWeeks: totalWeeks,
                                             plan: plan, moocs: moocs)
        let outline = payload["outline"] as? String ?? ""
        guard !outline.isEmpty else { return .init() }
        let fingerprint = outline + "|" + (payload["plan"] as? String ?? "") + "|" + (payload["mooc"] as? String ?? "")
        let key = "moodleAI3." + Insecure.SHA1.hash(data: Data(fingerprint.utf8)).map { String(format: "%02x", $0) }.joined()
        if let cached = UserDefaults.standard.string(forKey: key) { return MoodleCourseAI.answer(cached) }

        var raw: String?
        do {
            raw = try await askShared(payload)
        } catch {
            AppLog.record(.info, "import", "Rangement du cours par l'IA : service indisponible", detail: error.localizedDescription)
            raw = try? await askOnDevice(payload)
        }
        guard let raw else { return .init() }
        let answer = MoodleCourseAI.answer(raw)
        if !answer.hints.isEmpty {
            UserDefaults.standard.set(raw, forKey: key)
            AppLog.record(.info, "import", "Cours rangé avec l'IA",
                          detail: "\(snapshot.title) — \(answer.hints.count) activités, \(answer.series.count) séries, \(answer.moocWeeks.count) chapitres de MOOC, \(answer.guide.count) semaines expliquées")
        }
        return answer
    }

    private static func askShared(_ payload: [String: Any]) async throws -> String {
        guard SupabaseConfig.isConfigured,
              let url = URL(string: "\(SupabaseConfig.urlString)/functions/v1/analyze-course") else {
            throw SeriesAIExtractor.ExtractionError.unavailable
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 150
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw SeriesAIExtractor.ExtractionError.remote("analyze-course : HTTP \(status) \(String(decoding: data.prefix(160), as: UTF8.self))")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func askOnDevice(_ payload: [String: Any]) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), case .available = SystemLanguageModel.default.availability {
            let session = LanguageModelSession(instructions: MoodleCourseAI.instructions)
            var prompt = "Cours : \(payload["course"] ?? "")\nSemaines : \(payload["weeks"] ?? 14)\n\nActivités Moodle :\n\(payload["outline"] ?? "")"
            if let plan = payload["plan"] as? String { prompt += "\n\nPLAN DU COURS :\n" + String(plan.prefix(4000)) }
            if let mooc = payload["mooc"] as? String { prompt += "\n\nMOOC :\n" + String(mooc.prefix(2500)) }
            return try await session.respond(to: prompt).content
        }
        #endif
        throw SeriesAIExtractor.ExtractionError.unavailable
    }
}
