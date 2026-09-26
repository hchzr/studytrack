import UIKit

/// Les raccourcis de l'**écran d'accueil d'iOS** — appui long sur l'icône.
///
/// Ils doublent les tuiles de « Aujourd'hui », mais répondent à un autre moment :
/// on est sur l'écran d'accueil, pas dans l'app. « Importer une série » est le
/// geste de la semaine — un PDF reçu par mail ou Moodle, à ranger tout de suite.
///
/// Les types sont construits à partir de l'identifiant de bundle, comme le reste
/// du projet : renommer la cible ne casse donc pas les raccourcis en silence.
enum ShortcutAction: String {
    case importSeries
    case startTimer

    var type: String { "\(Bundle.main.bundleIdentifier ?? "").\(rawValue)" }

    init?(type: String) {
        guard let last = type.split(separator: ".").last,
              let value = ShortcutAction(rawValue: String(last)) else { return nil }
        self = value
    }

    var title: String {
        switch self {
        case .importSeries: return "Importer une série"
        case .startTimer: return "Lancer le chrono"
        }
    }
}

/// Reçoit le raccourci et le traduit en intention pour l'app.
///
/// SwiftUI n'expose pas `performActionFor` : il faut un délégué. Celui-ci ne fait
/// que déposer l'intention sur le routeur, que les écrans observent — aucun travail
/// de données ici, donc aucun risque d'agir avant que l'app soit prête.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        guard let shortcut = ShortcutAction(type: shortcutItem.type),
              let container = AppRuntime.container else {
            completionHandler(false)
            return
        }
        MainActor.assumeIsolated {
            container.router.shortcut = shortcut
        }
        completionHandler(true)
    }
}
