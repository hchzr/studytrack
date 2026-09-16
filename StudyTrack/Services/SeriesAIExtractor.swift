import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// D'où vient la structure proposée à la relecture.
enum SeriesExtractionSource: Equatable {
    case heuristic
    case onDevice
    /// La fonction Supabase de l'app : la clé du fournisseur est côté serveur.
    case shared
    /// Un service configuré par l'étudiant·e, avec sa propre clé.
    case remote(model: String)

    var label: String {
        switch self {
        case .heuristic: return "détection par motifs"
        case .onDevice: return "IA sur l'appareil"
        case .shared: return "IA StudyTrack (sans clé)"
        case .remote(let model): return "IA perso · \(model)"
        }
    }

    var icon: String {
        switch self {
        case .heuristic: return "text.magnifyingglass"
        case .onDevice: return "apple.intelligence"
        case .shared: return "sparkles"
        case .remote: return "cloud"
        }
    }
}

/// Extraction des séries et exercices d'un PDF par un modèle de langage.
///
/// Le moteur est choisi **automatiquement**, sans rien demander à l'étudiant·e :
///   1. **Sur l'appareil** (Apple Intelligence, iOS 26+) — gratuit, privé, hors
///      ligne. Le texte ne quitte pas le téléphone.
///   2. **La fonction Supabase de l'app** (`extract-series`) — la clé du
///      fournisseur est côté serveur, l'app n'a besoin que de sa clé `anon`.
///   3. **Un service perso**, si l'étudiant·e a saisi une URL et une clé (Groq,
///      OpenRouter, Ollama sur un Mac…) — pour qui veut choisir son modèle.
///
/// Dans les deux cas la réponse **complète** l'heuristique et passe par l'écran de
/// relecture : le modèle propose, l'étudiant·e dispose. Rien n'est créé sur sa
/// seule parole.
enum SeriesAIExtractor {

    enum ExtractionError: LocalizedError {
        case unavailable
        case remote(String)
        case emptyAnswer

        var errorDescription: String? {
            switch self {
            case .unavailable: return "Aucun modèle disponible : l'analyse IA est désactivée ou l'adresse du service est vide (Profil › Import intelligent)."
            case .remote(let detail): return "Le service distant a refusé : \(detail)"
            case .emptyAnswer: return "Le modèle n'a rien trouvé de structuré dans ce texte."
            }
        }
    }

    // MARK: Disponibilité

    /// Le modèle embarqué est-il utilisable sur cet appareil, maintenant ?
    static var isOnDeviceAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// Pourquoi le modèle embarqué manque, en clair — ou `nil` s'il est là.
    static var onDeviceUnavailabilityReason: String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return "Cet appareil ne prend pas en charge Apple Intelligence."
                case .appleIntelligenceNotEnabled: return "Apple Intelligence est désactivé dans Réglages."
                case .modelNotReady: return "Le modèle se télécharge encore ; réessaie dans quelques minutes."
                @unknown default: return "Modèle embarqué indisponible."
                }
            }
        }
        #endif
        return "L'analyse sur l'appareil demande iOS 26."
    }

    /// Un service perso est prêt avec une URL, un modèle et une clé.
    static func isRemoteConfigured(_ settings: SettingsStore) -> Bool {
        guard let url = URL(string: settings.aiEndpoint.trimmingCharacters(in: .whitespaces)),
              url.scheme?.hasPrefix("http") == true else { return false }
        return !settings.aiModel.trimmingCharacters(in: .whitespaces).isEmpty
            && !settings.aiAPIKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// La fonction partagée existe dès que la build porte une configuration
    /// Supabase — la même qui sert aux groupes. Si elle n'est pas déployée, l'appel
    /// échoue proprement et le maillon suivant prend la main.
    static var isSharedAvailable: Bool { SupabaseConfig.isConfigured }

    /// Le moteur qui servira, selon les réglages et l'appareil.
    static func plannedSource(_ settings: SettingsStore) -> SeriesExtractionSource? {
        guard settings.aiExtractionEnabled else { return nil }
        if isOnDeviceAvailable { return .onDevice }
        if isSharedAvailable { return .shared }
        if isRemoteConfigured(settings) { return .remote(model: settings.aiModel) }
        return nil
    }

    /// Les moteurs à essayer, dans l'ordre. Un échec passe au suivant.
    private static func chain(_ settings: SettingsStore) -> [SeriesExtractionSource] {
        guard settings.aiExtractionEnabled else { return [] }
        var result: [SeriesExtractionSource] = []
        if isOnDeviceAvailable { result.append(.onDevice) }
        if isSharedAvailable { result.append(.shared) }
        if isRemoteConfigured(settings) { result.append(.remote(model: settings.aiModel)) }
        return result
    }

    // MARK: Extraction

    static func extract(from text: String, settings: SettingsStore) async throws -> (series: [DetectedSeries], source: SeriesExtractionSource) {
        let engines = chain(settings)
        guard !engines.isEmpty else { throw ExtractionError.unavailable }
        let prepared = SeriesAIParsing.prepare(text)
        var lastError: Error = ExtractionError.emptyAnswer

        // Chaque maillon est tenté à son tour : un modèle local occupé, une fonction
        // non déployée ou un quota épuisé ne doivent pas priver l'étudiant·e des
        // suivants. Une réponse vide compte comme un échec du maillon.
        for engine in engines {
            do {
                let series: [DetectedSeries]
                switch engine {
                case .onDevice: series = try await extractOnDevice(prepared)
                case .shared: series = try await extractShared(prepared)
                case .remote: series = try await extractRemote(prepared, settings: settings)
                case .heuristic: continue
                }
                if !series.isEmpty { return (series, engine) }
                lastError = ExtractionError.emptyAnswer
            } catch {
                if Task.isCancelled { throw error }
                lastError = error
            }
        }
        throw lastError
    }

    // MARK: Fonction Supabase partagée

    private static func extractShared(_ text: String) async throws -> [DetectedSeries] {
        guard SupabaseConfig.isConfigured,
              let url = URL(string: "\(SupabaseConfig.urlString)/functions/v1/extract-series") else {
            throw ExtractionError.unavailable
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ExtractionError.remote("réponse invalide") }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw ExtractionError.remote("fonction StudyTrack : HTTP \(http.statusCode) \(detail)")
        }
        guard let raw = String(data: data, encoding: .utf8) else { throw ExtractionError.remote("réponse illisible") }
        return SeriesAIParsing.parse(raw)
    }

    // MARK: Sur l'appareil

    private static func extractOnDevice(_ text: String) async throws -> [DetectedSeries] {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let session = LanguageModelSession(instructions: SeriesAIParsing.instructions)
            let response = try await session.respond(
                to: "Texte du PDF :\n\n\(text)",
                generating: GeneratedSeriesList.self)
            return response.content.detected
        }
        #endif
        throw ExtractionError.unavailable
    }

    // MARK: Distant (API compatible OpenAI)

    /// Le distant seul, pour le bouton « Tester » des réglages.
    static func extractRemoteForTest(_ text: String, settings: SettingsStore) async throws -> [DetectedSeries] {
        try await extractRemote(text, settings: settings)
    }

    private static func extractRemote(_ text: String, settings: SettingsStore) async throws -> [DetectedSeries] {
        guard let base = URL(string: settings.aiEndpoint) else { throw ExtractionError.unavailable }
        let url = base.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = settings.aiAPIKey.trimmingCharacters(in: .whitespaces)
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = [
            "model": settings.aiModel.trimmingCharacters(in: .whitespaces),
            "temperature": 0,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": SeriesAIParsing.instructions],
                ["role": "user", "content": "Texte du PDF :\n\n\(text)"]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ExtractionError.remote("réponse invalide") }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw ExtractionError.remote("HTTP \(http.statusCode) \(detail)")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            // Certains services renvoient directement l'objet JSON demandé.
            if let raw = String(data: data, encoding: .utf8) {
                let parsed = SeriesAIParsing.parse(raw)
                if !parsed.isEmpty { return parsed }
            }
            throw ExtractionError.remote("format de réponse inattendu")
        }
        // `content` est une chaîne… ou déjà l'objet, selon le service.
        if let content = message["content"] as? String {
            return SeriesAIParsing.parse(content)
        }
        if let contentObject = message["content"],
           let encoded = try? JSONSerialization.data(withJSONObject: contentObject),
           let raw = String(data: encoded, encoding: .utf8) {
            return SeriesAIParsing.parse(raw)
        }
        throw ExtractionError.remote("format de réponse inattendu")
    }
}

// MARK: - Schéma guidé du modèle embarqué

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable(description: "Les séries d'exercices trouvées dans le texte")
struct GeneratedSeriesList {
    @Guide(description: "Une entrée par série, dans l'ordre du document ; vide s'il n'y en a aucune")
    var series: [GeneratedSeries]

    var detected: [DetectedSeries] {
        var result: [DetectedSeries] = []
        for item in series {
            guard (1...60).contains(item.number) else { continue }
            var seen = Set<String>()
            var exercises: [DetectedExercise] = []
            for exercise in item.exercises {
                guard let number = SeriesAIParsing.normalizeNumber(exercise.number, series: item.number),
                      seen.insert(number).inserted else { continue }
                let title = exercise.title.trimmingCharacters(in: .whitespacesAndNewlines)
                exercises.append(DetectedExercise(number: number,
                                                  title: SeriesPDFParser.looksLikeTitle(title) ? title : "",
                                                  isBonus: exercise.isBonus))
            }
            exercises.sort { $0.number.localizedStandardCompare($1.number) == .orderedAscending }
            result.append(DetectedSeries(number: item.number,
                                         title: item.title.trimmingCharacters(in: .whitespacesAndNewlines),
                                         exercises: exercises))
        }
        return result.sorted { $0.number < $1.number }
    }
}

@available(iOS 26.0, *)
@Generable(description: "Une série d'exercices")
struct GeneratedSeries {
    @Guide(description: "Numéro de la série, tel qu'écrit dans le document (Série 3 → 3)")
    var number: Int
    @Guide(description: "Intitulé court de la série s'il existe, sinon chaîne vide")
    var title: String
    @Guide(description: "Les exercices de la série, dans l'ordre")
    var exercises: [GeneratedExercise]
}

@available(iOS 26.0, *)
@Generable(description: "Un exercice")
struct GeneratedExercise {
    @Guide(description: "Numéro au format série.exercice, par exemple 3.2 ; un simple « 2 » est accepté")
    var number: String
    @Guide(description: "Intitulé court s'il existe, jamais l'énoncé ; sinon chaîne vide")
    var title: String
    @Guide(description: "Vrai si marqué bonus, facultatif, optionnel ou étoilé")
    var isBonus: Bool
}
#endif
