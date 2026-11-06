import Foundation

/// Le tuteur gratuit (fonction serveur `tutor`) : quand Claude Code n'est pas installé, l'app
/// répond quand même — un modèle gratuit d'abord (Groq), payant en repli, choisi par le
/// serveur. Le client choisit un **mode**, jamais la consigne (elle est sur le serveur, copiée
/// de l'app). Le même service que Windows (`windows/src/services/freeTutor.ts`).
enum FreeTutor {
    struct Answer { var text: String; var model: String }

    enum Failure: LocalizedError {
        case unavailable, server(String)
        var errorDescription: String? {
            switch self {
            case .unavailable: return String(localized: "Le tuteur gratuit n'est pas disponible dans cette version.")
            case .server(let message): return message
            }
        }
    }

    /// Un identifiant d'installation, pour les limites du serveur (rien d'autre).
    static var installID: String {
        if let id = UserDefaults.standard.string(forKey: "tutor.installID") { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: "tutor.installID")
        return id
    }

    /// `messages` alternent étudiant·e (`user`) et tuteur (`assistant`) ; le dernier est la question.
    static func ask(mode: String = "tutor", messages: [(role: String, content: String)]) async throws -> Answer {
        guard !SupabaseConfig.urlString.isEmpty, let url = URL(string: SupabaseConfig.urlString + "/functions/v1/tutor") else {
            throw Failure.unavailable
        }
        var request = URLRequest(url: url, timeoutInterval: mode == "tutor" ? 75 : 160)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(installID, forHTTPHeaderField: "x-polymestre-install")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "mode": mode, "messages": messages.map { ["role": $0.role, "content": $0.content] },
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200, let text = json["text"] as? String, !text.isEmpty else {
            throw Failure.server((json["error"] as? String) ?? String(localized: "Le tuteur ne répond pas."))
        }
        return Answer(text: text, model: json["model"] as? String ?? "")
    }

    /// Une réponse d'un trait (fiche, méthodes, carte du cours) : le mode qui porte cette consigne,
    /// le serveur n'en acceptant pas du client (il a la même copie). `nil` pour une autre consigne.
    static func mode(for instructions: String) -> String? {
        switch instructions {
        case RevisionSheetAI.instructions: return "sheet"
        case RevisionSheetAI.methodsInstructions: return "sheetMethods"
        case StudyMapAI.instructions: return "studyMap"
        case StudyMapAI.chapterInstructions: return "studyMapChapter"
        default: return nil
        }
    }

    /// L'écrivain de `RevisionSheetMaker` sans Claude Code (l'iPhone, un Mac sans lui).
    static func write(instructions: String, prompt: String) async throws -> String {
        guard let mode = mode(for: instructions) else { throw Failure.unavailable }
        return try await ask(mode: mode, messages: [(role: "user", content: prompt)]).text
    }
}
