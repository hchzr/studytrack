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
    /// La même fonction, qui a lu les **pages en image** : colonnes, points
    /// imbriqués et formules compris. Sa lecture des questions fait foi.
    case vision

    var label: String {
        switch self {
        case .heuristic: return "détection par motifs"
        case .onDevice: return "IA sur l'appareil"
        case .shared: return "IA StudyTrack (sans clé)"
        case .vision: return "IA StudyTrack · lecture des pages"
        }
    }

    /// Le moteur a-t-il vu la mise en page ? Sa lecture des sous-questions
    /// l'emporte alors sur celle du texte (`SeriesAIParsing.merge`).
    var readsLayout: Bool { self == .vision }

    var icon: String {
        switch self {
        case .heuristic: return "text.magnifyingglass"
        case .onDevice: return "apple.intelligence"
        case .shared: return "sparkles"
        case .vision: return "eye"
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
///
/// (Un troisième maillon, un « service perso » avec sa propre clé d'API, a été
/// retiré : il n'apportait rien que la fonction de l'app ne fasse déjà, et
/// gardait une clé en clair dans les réglages.)
///
/// Dans les deux cas la réponse **complète** l'heuristique et passe par l'écran de
/// relecture : le modèle propose, l'étudiant·e dispose. Rien n'est créé sur sa
/// seule parole.
enum SeriesAIExtractor {

    enum ExtractionError: LocalizedError {
        case unavailable
        case remote(String)
        /// La fonction Supabase n'est pas déployée — cas le plus fréquent, et le
        /// seul qu'un simple réessai ne résoudra jamais.
        case sharedNotDeployed(Int)
        case emptyAnswer

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Aucun modèle disponible : l'analyse IA est désactivée, ou aucun moteur n’est joignable (Réglages › IA de lecture)."
            case .remote(let detail):
                return "Le service distant a refusé : \(detail)"
            case .sharedNotDeployed(let status):
                return """
                La fonction d'analyse n'est pas déployée sur ton projet Supabase (HTTP \(status)).                 L'import par motifs a quand même lu le PDF.

                Pour l'activer, une seule fois, depuis le dossier du projet :
                    supabase functions deploy extract-series --project-ref <ta-ref>
                    supabase secrets set LLM_API_KEY=<ta-clé>
                Le détail est dans README.md §5.
                """
            case .emptyAnswer:
                return "Le modèle n'a rien trouvé de structuré dans ce texte."
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

    /// La fonction partagée existe dès que la build porte une configuration
    /// Supabase — la même qui sert aux groupes. Si elle n'est pas déployée, l'appel
    /// échoue proprement et le maillon suivant prend la main.
    static var isSharedAvailable: Bool { SupabaseConfig.isConfigured }

    /// Un texte d'essai, court et sans ambiguïté : deux séries, un bonus, un
    /// intitulé. Assez pour juger un moteur, assez court pour ne rien coûter.
    static let sampleText = """
    Série 3 — Récurrences
    Exercice 1 : Tri fusion
    Montrer que l'algorithme s'exécute en O(n log n).
    Exercice 2 (facultatif)
    Écrire la relation de récurrence du cas moyen.

    Série 4 — Graphes
    Exercice 1
    Parcours en largeur : donner la complexité.
    """

    /// Vérifie le modèle **sur l'appareil**, comme `diagnoseShared` le fait pour la
    /// fonction serveur.
    ///
    /// Sans ce test, un étudiant·e dont l'import IA « ne marche pas » n'a aucun
    /// moyen de savoir si le modèle est absent, occupé, ou simplement mauvais.
    static func diagnoseOnDevice() async -> String? {
        guard isOnDeviceAvailable else {
            return onDeviceUnavailabilityReason ?? "Modèle embarqué indisponible."
        }
        do {
            let series = try await extractOnDevice(SeriesAIParsing.prepare(sampleText))
            let count = series.reduce(0) { $0 + $1.exercises.count }
            if series.isEmpty {
                return "Le modèle a répondu, mais n'a trouvé aucune série. Le texte était pourtant explicite : l'analyse sur l'appareil n'est pas fiable sur cet appareil."
            }
            if count < 3 {
                return "Le modèle a trouvé \(series.count) série(s) et \(count) exercice(s) sur les 3 attendus. Utilisable, mais la lecture par motifs fera souvent mieux."
            }
            return "Le modèle sur l'appareil fonctionne : \(series.count) série(s), \(count) exercices."
        } catch {
            return "Le modèle sur l'appareil a échoué : \(error.localizedDescription)"
        }
    }

    /// Ce que vaut la fonction partagée, en trois cas **distincts**.
    ///
    /// « Pas déployée » et « déployée mais en échec » demandent deux gestes
    /// opposés : déployer la fonction, ou corriger la clé / le modèle du
    /// fournisseur. Les confondre sous un même message envoyait l'utilisateur
    /// déployer une fonction qui l'était déjà.
    enum SharedVerdict: Equatable {
        case ready
        /// La fonction n'existe pas sur le projet (HTTP 404).
        case notDeployed(Int)
        /// La fonction a répondu, mais l'analyse a échoué — clé, modèle, quota.
        case failing(String)
        /// Aucun projet Supabase compilé dans cette build.
        case unconfigured
    }

    /// Vérifie la fonction partagée sans dépendre d'un import, pour l'écran de réglages.
    static func diagnoseShared() async -> SharedVerdict {
        guard SupabaseConfig.isConfigured else { return .unconfigured }
        do {
            _ = try await extractShared("Série 1\nExercice 1.1")
            return .ready
        } catch let error as ExtractionError {
            if case .sharedNotDeployed(let status) = error { return .notDeployed(status) }
            return .failing(error.localizedDescription)
        } catch {
            return .failing(error.localizedDescription)
        }
    }

    /// Le moteur qui servira, selon les réglages et l'appareil.
    /// Le moteur qui servira, dans le même ordre que `chain`.
    static func plannedSource(_ settings: SettingsStore) -> SeriesExtractionSource? {
        guard settings.aiExtractionEnabled else { return nil }
        switch engineOrder(sharedAvailable: isSharedAvailable && sharedIsReachable,
                           onDeviceAvailable: isOnDeviceAvailable).first {
        case .shared: return .shared
        case .onDevice: return .onDevice
        case nil: return nil
        }
    }

    /// Les moteurs à essayer, dans l'ordre. Un échec passe au suivant.
    ///
    /// **Le service d'abord, le modèle embarqué ensuite.**
    ///
    /// L'ordre inverse semblait prudent — gratuit, privé, hors ligne — mais il
    /// plaçait un modèle de quelques milliards de paramètres devant un modèle servi.
    /// Sur une série d'exercices réels, l'écart de qualité n'est pas marginal : le
    /// modèle embarqué rate des numéros, invente des intitulés, et confond un
    /// énoncé avec un titre. Faire relire ce travail coûte plus de temps qu'il n'en
    /// fait gagner.
    ///
    /// Le modèle embarqué garde sa place : il prend le relais **hors ligne**, quand
    /// la fonction est absente, ou quand le réseau manque. Un résultat imparfait
    /// vaut mieux que pas de résultat du tout.
    private static func chain(_ settings: SettingsStore) -> [SeriesExtractionSource] {
        guard settings.aiExtractionEnabled else { return [] }
        return engineOrder(sharedAvailable: isSharedAvailable && sharedIsReachable,
                           onDeviceAvailable: isOnDeviceAvailable)
            .map { kind in
                switch kind {
                case .shared: return .shared
                case .onDevice: return .onDevice
                }
            }
    }

    /// Les moteurs disponibles, **du meilleur au moins bon**.
    ///
    /// L'ordre vit dans `SeriesEngineOrder` (Domain) : il est ainsi testable sans
    /// FoundationModels, et une seule définition sert au service et aux tests.
    static func engineOrder(sharedAvailable: Bool,
                            onDeviceAvailable: Bool) -> [SeriesEngineKind] {
        SeriesEngineOrder.engines(sharedAvailable: sharedAvailable,
                                  onDeviceAvailable: onDeviceAvailable)
    }

    /// La fonction partagée a-t-elle répondu au moins une fois dans cette session ?
    ///
    /// `nil` = jamais essayée. `false` = 404 constaté, on n'insiste plus. Un seul
    /// aller-retour perdu au lieu d'un par import.
    nonisolated(unsafe) private static var sharedVerdict: Bool?
    static var sharedIsReachable: Bool { sharedVerdict != false }

    // MARK: Extraction

    static func extract(from text: String, settings: SettingsStore) async throws -> (series: [DetectedSeries], source: SeriesExtractionSource) {
        try await extract(prepared: SeriesAIParsing.prepare(text), settings: settings)
    }

    /// Extraction d'un texte **déjà préparé** — celui de `prepareLayout`, qui
    /// garde titres, retraits et l'indice de série. Le préparer une seconde fois
    /// le ramènerait à un texte aplati.
    static func extract(prepared: String, pageImages: [Data] = [], seriesHint: Int? = nil,
                        language: String? = nil, settings: SettingsStore) async throws -> (series: [DetectedSeries], source: SeriesExtractionSource) {
        let engines = chain(settings)
        guard !engines.isEmpty else { throw ExtractionError.unavailable }
        var lastError: Error = ExtractionError.emptyAnswer

        // Chaque maillon est tenté à son tour : un modèle local occupé, une fonction
        // non déployée ou un quota épuisé ne doivent pas priver l'étudiant·e des
        // suivants. Une réponse vide compte comme un échec du maillon.
        for engine in engines {
            do {
                let series: [DetectedSeries]
                switch engine {
                case .onDevice: series = try await extractOnDevice(prepared)
                case .shared:
                    // Les pages d'abord : c'est la seule lecture fiable des
                    // sous-questions. Le texte reste le repli, dans le même maillon.
                    if !pageImages.isEmpty {
                        do {
                            let seen = try await extractSharedVision(pageImages, text: prepared, seriesHint: seriesHint,
                                                                   language: language)
                            if !seen.isEmpty { return (seen, .vision) }
                        } catch {
                            if Task.isCancelled { throw error }
                            if case ExtractionError.sharedNotDeployed = error { throw error }
                            AppLog.record(.warning, AppLog.Category.ai, "Lecture des pages impossible",
                                          detail: error.localizedDescription)
                        }
                    }
                    series = try await extractShared(prepared)
                case .heuristic, .vision: continue
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
        try await callShared(["text": text], timeout: 45)
    }

    /// Les pages en image. Plus lent (un paquet de cinq pages par appel côté
    /// serveur), d'où un délai plus large.
    /// Le texte extrait part avec les images : ses numéros et son vocabulaire
    /// sont exacts, ses formules non — le modèle prend l'un et l'autre où ils sont
    /// fiables.
    private static func extractSharedVision(_ pages: [Data], text: String, seriesHint: Int?,
                                            language: String?) async throws -> [DetectedSeries] {
        var body: [String: Any] = ["images": pages.map { $0.base64EncodedString() }, "text": text]
        if let seriesHint { body["seriesHint"] = seriesHint }
        // Le texte n'accompagne pas toujours les images (Groq le retire faute de
        // quota) : la langue voyage donc à part.
        if let language { body["language"] = language }
        return try await callShared(body, timeout: 150)
    }

    private static func callShared(_ body: [String: Any], timeout: TimeInterval) async throws -> [DetectedSeries] {
        guard SupabaseConfig.isConfigured,
              let url = URL(string: "\(SupabaseConfig.urlString)/functions/v1/extract-series") else {
            throw ExtractionError.unavailable
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ExtractionError.remote("réponse invalide") }
        guard (200..<300).contains(http.statusCode) else {
            // 404 = la fonction n'existe pas. Le dire précisément évite de chercher
            // du côté du réseau, de la clé ou du modèle — trois fausses pistes.
            if http.statusCode == 404 {
                sharedVerdict = false
                throw ExtractionError.sharedNotDeployed(http.statusCode)
            }
            let detail = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw ExtractionError.remote("fonction StudyTrack : HTTP \(http.statusCode) \(detail)")
        }
        guard let raw = String(data: data, encoding: .utf8) else { throw ExtractionError.remote("réponse illisible") }
        sharedVerdict = true
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
                                                  title: SeriesPDFParser.looksLikeGeneratedTitle(title) ? title : "",
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
