import AppIntents
import Foundation
import WidgetKit

/// Les gestes faits **dans un widget**, en attente de l'app.
///
/// La base SwiftData vit dans le conteneur de l'app : le widget ne peut pas
/// l'écrire. Il dépose donc le geste dans le groupe d'app, met son propre
/// affichage à jour tout de suite, et l'app l'applique à sa prochaine activation
/// — le même chemin que les boutons du chrono sur l'écran verrouillé.
enum PendingWidgetActions {
    static let key = "widget.pendingCompletions"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: WidgetBridge.appGroupID) ?? .standard
    }

    /// « exercise:UUID », « theory:UUID ».
    static func add(kind: String, id: String) {
        var items = defaults.stringArray(forKey: key) ?? []
        let item = "\(kind):\(id)"
        guard !items.contains(item) else { return }
        items.append(item)
        defaults.set(items, forKey: key)
    }

    static func take() -> [(kind: String, id: String)] {
        let items = defaults.stringArray(forKey: key) ?? []
        defaults.removeObject(forKey: key)
        return items.compactMap { item in
            let parts = item.split(separator: ":", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
    }
}

/// « ✓ » dans le widget « Prochaine tâche » : l'action est cochée sans ouvrir l'app.
struct CompleteNextActionIntent: AppIntent {
    static var title: LocalizedStringResource = "Marquer comme fait"
    static var description = IntentDescription("Coche la prochaine tâche proposée par StudyTrack.")
    static var isDiscoverable: Bool = false

    @Parameter(title: "Type") var kind: String
    @Parameter(title: "Identifiant") var targetID: String

    init() {}

    init(kind: String, targetID: String) {
        self.kind = kind
        self.targetID = targetID
    }

    func perform() async throws -> some IntentResult {
        PendingWidgetActions.add(kind: kind, id: targetID)
        // L'affichage suit tout de suite : la case se coche, sans attendre l'app.
        if var snapshot = WidgetBridge.read(), snapshot.next?.targetID == targetID {
            snapshot.next?.isDone = true
            snapshot.todoCount = max(0, snapshot.todoCount - 1)
            WidgetBridge.write(snapshot)
        }
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
