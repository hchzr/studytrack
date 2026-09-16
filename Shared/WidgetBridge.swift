import Foundation

/// Instantané de l'état StudyTrack, partagé entre l'app et l'extension widget
/// via le conteneur de groupe d'app (`StudyTrackAppGroup`, voir `WidgetBridge`).
///
/// Ce fichier est compilé dans **les deux cibles** : il ne dépend donc que de
/// Foundation, et sert de contrat unique entre l'app et le widget.
struct WidgetSnapshot: Codable, Equatable {
    var updatedAt: Date
    var weekSeconds: Int
    var streak: Int
    var level: Int
    var xp: Int
    var todoCount: Int
    var todos: [WidgetTodo]
    var nextExamTitle: String?
    var nextExamCourse: String?
    var nextExamDate: Date?

    static let empty = WidgetSnapshot(updatedAt: .distantPast,
                                      weekSeconds: 0,
                                      streak: 0,
                                      level: 1,
                                      xp: 0,
                                      todoCount: 0,
                                      todos: [],
                                      nextExamTitle: nil,
                                      nextExamCourse: nil,
                                      nextExamDate: nil)

    var hasContent: Bool {
        updatedAt != .distantPast
    }
}

struct WidgetTodo: Codable, Equatable, Identifiable {
    var id: String
    var courseCode: String
    var title: String
    var kind: String
    var colorHex: String
}

/// Lecture / écriture de l'instantané dans le conteneur partagé.
enum WidgetBridge {
    /// Identifiant du groupe d'app.
    ///
    /// Défini **une seule fois** dans le projet (`STUDYTRACK_APP_GROUP`), puis
    /// injecté dans l'Info.plist des deux cibles et dans leurs entitlements.
    /// Le lire ici évite qu'une valeur codée en dur ne diverge de la configuration.
    static let appGroupID: String = {
        if let value = Bundle.main.object(forInfoDictionaryKey: "StudyTrackAppGroup") as? String,
           !value.isEmpty {
            return value
        }
        return "group.com.studytracker.app"
    }()

    static let fileName = "widget-snapshot.json"

    /// `nil` si l'app n'a pas l'entitlement App Group (par exemple avant signature).
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    static var fileURL: URL? {
        containerURL?.appendingPathComponent(fileName)
    }

    static func write(_ snapshot: WidgetSnapshot) {
        guard let url = fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func read() -> WidgetSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }
}

/// Formats partagés entre l'app et le widget.
///
/// Le widget ne peut pas importer `DateUtils` : ces fonctions sont pures et
/// compilées dans les deux cibles, et vérifiées par `validate.sh`.
enum WidgetFormat {
    /// « 45 min », « 2 h », « 1,6 h » — dixièmes d'heure **arrondis**.
    ///
    /// La version précédente écrivait `minutes / 10` : 1 h 35 donnait « 1,3 h »,
    /// soit dix-sept minutes de moins que la réalité.
    static func hours(_ seconds: Int) -> String {
        let totalMinutes = max(0, seconds) / 60
        if totalMinutes < 60 { return "\(totalMinutes) min" }
        let tenths = Int((Double(totalMinutes) / 60 * 10).rounded())
        let hours = tenths / 10
        let fraction = tenths % 10
        return fraction == 0 ? "\(hours) h" : "\(hours),\(fraction) h"
    }

    /// « J-12 », « Demain », « Aujourd'hui ».
    static func countdown(to date: Date, from reference: Date = Date()) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day],
                                           from: calendar.startOfDay(for: reference),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        if days <= 0 { return "Aujourd'hui" }
        if days == 1 { return "Demain" }
        return "J-\(days)"
    }
}

/// Liens profonds ouverts par les widgets. Le schéma est celui de l'app.
enum WidgetLink {
    static let focus = URL(string: "studytrack://focus")!
    static let today = URL(string: "studytrack://today")!
    static let courses = URL(string: "studytrack://courses")!
    static let agenda = URL(string: "studytrack://agenda")!
}
