import Foundation
import SwiftUI

/// Ce que les widgets du bureau affichent, écrit par l'app Mac dans le
/// conteneur partagé. Les widgets ne lisent pas la base : ils lisent ceci.
struct MacWidgetSnapshot: Codable, Equatable {
    struct Timer: Codable, Equatable {
        var courseCode: String
        var colorHex: String
        var label: String
        /// Début de la période en cours (le chrono tourne) ; `nil` en pause.
        var runningSince: Date?
        var accumulated: TimeInterval
        var breakEndsAt: Date?

        /// La date qui fait tourner `Text(_, style: .timer)`.
        var counterStart: Date? { runningSince.map { $0.addingTimeInterval(-accumulated) } }
    }

    struct Todo: Codable, Equatable, Identifiable {
        var id: String
        var title: String
        var detail: String
        var colorHex: String
        var icon: String
    }

    struct CourseWeek: Codable, Equatable, Identifiable {
        var id: String
        var code: String
        var colorHex: String
        var done: Int
        var total: Int
        var late: Int
    }

    var updatedAt: Date
    var todaySeconds: Int
    var weekSeconds: Int
    var week: Int
    var timer: Timer?
    var todos: [Todo]
    var courses: [CourseWeek]

    static let empty = MacWidgetSnapshot(updatedAt: .distantPast, todaySeconds: 0, weekSeconds: 0, week: 0,
                                         timer: nil, todos: [], courses: [])

    // MARK: Conteneur partagé

    /// Groupe préfixé par l'équipe : pas de profil à part sur macOS.
    static let groupID = "5GGDH5F3NG.com.hczr.studytrack"

    private static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("widget.json")
    }

    static func load() -> MacWidgetSnapshot {
        guard let url, let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(MacWidgetSnapshot.self, from: data) else { return .empty }
        return snapshot
    }

    func save() {
        guard let url = Self.url, let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Les mêmes données, sans l'horodatage : pour ne recharger les widgets
    /// que si quelque chose a vraiment changé.
    func sameContent(as other: MacWidgetSnapshot) -> Bool {
        var a = self, b = other
        a.updatedAt = .distantPast
        b.updatedAt = .distantPast
        return a == b
    }
}

extension Color {
    /// « #5B4FE0 » → couleur (les widgets n'ont pas le thème de l'app).
    init(widgetHex hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

/// « 2 h 10 », « 45 min ».
func widgetHours(_ seconds: Int) -> String {
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes) min" }
    let h = minutes / 60, m = minutes % 60
    return m == 0 ? "\(h) h" : "\(h) h \(String(format: "%02d", m))"
}
