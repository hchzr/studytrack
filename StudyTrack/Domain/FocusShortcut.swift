import Foundation

/// Un raccourci du chrono : « CS-250 · Exercices », lancé d'un tap.
///
/// Les raccourcis étaient une grille fixe de **tous** les cours suivis croisés avec
/// trois types de travail. Sur quatre cours, cela faisait douze tuiles dont on
/// n'utilisait jamais les mêmes, et rien ne permettait de les choisir. Ils
/// deviennent une liste que l'étudiant·e compose.
struct FocusShortcut: Codable, Equatable, Identifiable, Hashable {
    var courseCode: String
    var taskTypeRaw: String

    init(courseCode: String, taskType: TaskType) {
        self.courseCode = courseCode
        self.taskTypeRaw = taskType.rawValue
    }

    var id: String { "\(courseCode)|\(taskTypeRaw)" }

    var taskType: TaskType { TaskType(rawValue: taskTypeRaw) ?? .other }

    /// Ce que la tuile affiche : le code du cours, la nature du travail.
    var title: String { courseCode }

    var subtitle: String { taskType.label }

    var icon: String { taskType.icon }

    static func decode(_ raw: String) -> [FocusShortcut] {
        guard let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([FocusShortcut].self, from: data)) ?? []
    }

    static func encode(_ shortcuts: [FocusShortcut]) -> String {
        guard let data = try? JSONEncoder().encode(shortcuts),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}

/// Les raccourcis par défaut, quand l'étudiant·e n'en a encore composé aucun.
///
/// Trois cours au plus, deux natures chacune : de quoi démarrer sans rien régler,
/// et assez peu pour que la grille reste lisible. L'ordre suit celui des cours,
/// donc il est stable.
enum FocusShortcutDefaults {

    static let maxDefaults = 6

    /// Une liste par défaut à partir des codes de cours suivis.
    ///
    /// Les types sont choisis dans l'ordre où ils servent réellement : on regarde
    /// une vidéo, puis on fait les exercices, puis on les corrige.
    static func make(from courseCodes: [String],
                     types: [TaskType] = [.video, .exercise]) -> [FocusShortcut] {
        var result: [FocusShortcut] = []
        for code in courseCodes {
            for type in types {
                result.append(FocusShortcut(courseCode: code, taskType: type))
                if result.count >= maxDefaults { return result }
            }
        }
        return result
    }

    /// Nettoie une liste : sans doublon, sans cours disparu, dans l'ordre donné.
    ///
    /// Un cours supprimé ne doit pas laisser une tuile qui ne mène nulle part.
    static func sanitize(_ shortcuts: [FocusShortcut],
                         knownCourses: Set<String>) -> [FocusShortcut] {
        var seen = Set<String>()
        return shortcuts.filter { shortcut in
            guard knownCourses.contains(shortcut.courseCode) else { return false }
            return seen.insert(shortcut.id).inserted
        }
    }
}
