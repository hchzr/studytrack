import Foundation

/// La langue de l'app : celle du système par défaut (français ou anglais),
/// ou une langue choisie dans Personnaliser. L'app a été française seulement
/// jusqu'ici : qui l'utilisait déjà la garde en français, même sur un système
/// en anglais — rien ne change pour elle ou lui sans le demander.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, french, english

    var id: String { rawValue }

    var code: String? {
        switch self {
        case .system: nil
        case .french: "fr"
        case .english: "en"
        }
    }

    var title: String {
        switch self {
        case .system: String(localized: "Celle du système")
        case .french: "Français"
        case .english: "English"
        }
    }

    private static let key = "AppleLanguages"
    private static let settled = "appLanguage.settled"

    static var current: AppLanguage {
        let chosen = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[key] as? [String]
        switch chosen?.first?.prefix(2) {
        case "fr": return .french
        case "en": return .english
        default: return .system
        }
    }

    /// Prend effet au prochain lancement.
    static func choose(_ language: AppLanguage) {
        if let code = language.code {
            UserDefaults.standard.set([code], forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Au lancement, une seule fois : un·e utilisateur·rice d'avant la
    /// traduction garde le français.
    static func settle(existingUser: Bool) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: settled) else { return }
        defaults.set(true, forKey: settled)
        if existingUser, current == .system { choose(.french) }
    }
}
