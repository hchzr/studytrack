import Foundation

/// Un paquet Anki.
struct AnkiDeck: Equatable, Identifiable, Hashable {
    var name: String
    var id: String { name }
}

/// Une carte à envoyer.
struct AnkiNote: Equatable {
    var deckName: String
    var modelName: String
    /// Champs du modèle. Les clés usuelles d'« Basic » sont `Front` et `Back`.
    var fields: [String: String]
    var tags: [String]

    init(deckName: String,
         modelName: String = "Basic",
         fields: [String: String],
         tags: [String] = []) {
        self.deckName = deckName
        self.modelName = modelName
        self.fields = fields
        self.tags = tags
    }

    /// Le corps envoyé à AnkiConnect pour `addNote`.
    var payload: [String: Any] {
        [
            "note": [
                "deckName": deckName,
                "modelName": modelName,
                "fields": fields,
                "tags": tags,
                "options": ["allowDuplicate": false]
            ]
        ]
    }
}

/// Ce qu'AnkiConnect a répondu.
enum AnkiOutcome: Equatable {
    case value(AnyJSON)
    case failure(String)

    var errorMessage: String? {
        if case .failure(let message) = self { return message }
        return nil
    }

    var stringList: [String] {
        if case .value(.array(let items)) = self {
            return items.compactMap { if case .string(let text) = $0 { return text } else { return nil } }
        }
        return []
    }

    var isSuccess: Bool { errorMessage == nil }
}

/// Un sous-ensemble de JSON, suffisant pour lire ce que renvoie AnkiConnect.
///
/// Écrire un décodeur complet serait disproportionné : l'API répond soit une
/// valeur simple, soit une liste de chaînes, soit un objet. Trois cas, et on
/// refuse le reste plutôt que de deviner.
indirect enum AnyJSON: Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([AnyJSON])
    case object([String: AnyJSON])

    init?(raw: Any) {
        switch raw {
        case let value as String: self = .string(value)
        case let value as NSNumber:
            // `NSNumber` porte aussi les booléens : `true` arrive en `1`.
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else {
                self = .number(value.doubleValue)
            }
        case is NSNull: self = .null
        case let value as [Any]:
            self = .array(value.compactMap { AnyJSON(raw: $0) })
        case let value as [String: Any]:
            self = .object(value.compactMapValues { AnyJSON(raw: $0) })
        default: return nil
        }
    }
}

/// Construit les requêtes et lit les réponses d'**AnkiConnect**.
///
/// Fonction **pure** : elle reçoit des valeurs et rend des valeurs, donc elle se
/// teste sans Anki ouvert ni réseau. C'est important, parce que le cas le plus
/// fréquent n'est pas « Anki répond mal » mais « Anki ne répond pas ».
enum AnkiConnect {

    /// Version du protocole. AnkiConnect expose `version` ; 6 est la version
    /// courante depuis longtemps, et l'annoncer évite les réponses en ancien format.
    static let protocolVersion = 6

    /// Port par défaut d'AnkiConnect.
    static let defaultEndpoint = "http://127.0.0.1:8765"

    /// Adresse utilisable, ou `nil`.
    ///
    /// On accepte ce que les gens tapent vraiment : « 192.168.1.10:8765 » sans
    /// schéma, ou « http://…/ » avec une barre finale.
    static func normalizeEndpoint(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.host != nil else { return nil }
        return text
    }

    /// Le corps d'une requête : `{"action": …, "version": 6, "params": {…}}`.
    static func requestData(action: String, params: [String: Any] = [:]) -> Data? {
        let body: [String: Any] = [
            "action": action,
            "version": protocolVersion,
            "params": params
        ]
        return try? JSONSerialization.data(withJSONObject: body)
    }

    /// Lit la réponse : `{"result": …, "error": …}`.
    ///
    /// AnkiConnect signale ses erreurs **dans** un corps HTTP 200 : ne regarder
    /// que le code de statut laisserait passer un échec pour un succès.
    static func outcome(from data: Data) -> AnkiOutcome {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure("Réponse illisible : AnkiConnect n'a pas renvoyé du JSON.")
        }
        if let error = object["error"] as? String, !error.isEmpty {
            return .failure(error)
        }
        guard let result = object["result"] else {
            return .failure("Réponse sans résultat ni erreur.")
        }
        if result is NSNull { return .value(.null) }
        guard let value = AnyJSON(raw: result) else {
            return .failure("Résultat dans un format inattendu.")
        }
        return .value(value)
    }

    /// Traduit une erreur d'AnkiConnect en quelque chose d'actionnable.
    ///
    /// Les messages d'Anki sont exacts mais supposent qu'on sait de quoi il parle —
    /// « collection is not available » ne dit pas qu'il faut ouvrir Anki.
    static func explain(_ message: String) -> String {
        let text = message.lowercased()
        if text.contains("collection is not available") || text.contains("collection unavailable") {
            return "Anki est ouvert mais aucune collection n'est chargée : ouvre un paquet, puis réessaie."
        }
        if text.contains("deck was not found") || text.contains("deck not found") {
            return "Ce paquet n'existe pas dans Anki. Choisis-en un dans la liste, ou crée-le d'abord."
        }
        if text.contains("model was not found") {
            return "Ce modèle de note n'existe pas dans Anki. « Basic » est le nom habituel."
        }
        if text.contains("cannot create note because it is a duplicate") {
            return "Cette carte existe déjà dans Anki."
        }
        return message
    }
}

/// Fabrique les cartes à partir des modèles de l'app.
///
/// Une carte doit tenir seule : on la relira dans six semaines, hors de l'app.
/// Le recto porte donc **le cours et le numéro** — sans eux, « Montrer que… » ne
/// veut plus rien dire — et le verso ce que l'étudiant·e a écrit.
enum AnkiNoteFactory {

    static func exercise(_ exercise: Exercise, deck: String, model: String = "Basic") -> AnkiNote {
        let course = exercise.series?.course?.displayCode ?? ""
        let series = exercise.series.map { "Série \($0.seriesNumber)" } ?? ""

        var front = [course, series].filter { !$0.isEmpty }.joined(separator: " · ")
        front += front.isEmpty ? "" : " — "
        front += exercise.displayNumber
        if !exercise.title.isEmpty { front += " : \(exercise.title)" }

        var back = exercise.title.isEmpty ? "À compléter." : exercise.title
        if let note = exercise.correctionNote, !note.isEmpty { back = note }
        if let score = exercise.scoreLabel { back += "\n\nScore : \(score)" }
        if exercise.redoRequired { back += "\n\nÀ refaire." }

        var tags = ["StudyTrack"]
        if !course.isEmpty { tags.append(course.replacingOccurrences(of: "-", with: "")) }
        if exercise.isBonus { tags.append("bonus") }
        if exercise.redoRequired { tags.append("à-refaire") }

        return AnkiNote(deckName: deck,
                        modelName: model,
                        fields: ["Front": front, "Back": back],
                        tags: tags)
    }

    static func theory(_ item: TheoryItem, deck: String, model: String = "Basic") -> AnkiNote {
        let course = item.course?.displayCode ?? ""
        var front = course.isEmpty ? "" : "\(course) — "
        front += item.displayNumber
        if !item.title.isEmpty { front += " : \(item.title)" }

        var back = item.summaryText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if back.isEmpty { back = "À résumer." }
        if !item.urlString.isEmpty { back += "\n\n[Source](\(item.urlString))" }

        var tags = ["StudyTrack", "théorie"]
        if !course.isEmpty { tags.append(course.replacingOccurrences(of: "-", with: "")) }
        if !item.isSummarized { tags.append("à-résumer") }

        return AnkiNote(deckName: deck,
                        modelName: model,
                        fields: ["Front": front, "Back": back],
                        tags: tags)
    }
}
