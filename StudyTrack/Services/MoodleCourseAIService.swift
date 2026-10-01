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
        guard settings.aiExtractionEnabled else { return [:] }
        let payload = MoodleCourseAI.payload(for: snapshot, termStart: termStart, totalWeeks: totalWeeks)
        let outline = payload["outline"] as? String ?? ""
        guard !outline.isEmpty else { return [:] }
        let key = "moodleAI." + Insecure.SHA1.hash(data: Data(outline.utf8)).map { String(format: "%02x", $0) }.joined()
        if let cached = UserDefaults.standard.string(forKey: key) { return MoodleCourseAI.parse(cached) }

        var raw: String?
        do {
            raw = try await askShared(payload)
        } catch {
            AppLog.record(.info, "import", "Rangement du cours par l'IA : service indisponible", detail: error.localizedDescription)
            raw = try? await askOnDevice(payload)
        }
        guard let raw else { return [:] }
        let hints = MoodleCourseAI.parse(raw)
        if !hints.isEmpty {
            UserDefaults.standard.set(raw, forKey: key)
            AppLog.record(.info, "import", "Cours rangé avec l'IA", detail: "\(snapshot.title) — \(hints.count) activités")
        }
        return hints
    }

    private static func askShared(_ payload: [String: Any]) async throws -> String {
        guard SupabaseConfig.isConfigured,
              let url = URL(string: "\(SupabaseConfig.urlString)/functions/v1/analyze-course") else {
            throw SeriesAIExtractor.ExtractionError.unavailable
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
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
            let prompt = "Cours : \(payload["course"] ?? "")\nSemaines : \(payload["weeks"] ?? 14)\n\nPlan :\n\(payload["outline"] ?? "")"
            return try await session.respond(to: prompt).content
        }
        #endif
        throw SeriesAIExtractor.ExtractionError.unavailable
    }
}
