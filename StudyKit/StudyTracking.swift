import SwiftUI
import CryptoKit

// MARK: - Lire, c'est cocher

/// Ce qu'on lit et regarde **compte** : arriver au bout d'une section du
/// polycopié, regarder 90 % d'une vidéo, atteindre la dernière page des
/// diapositives coche l'élément de théorie qui y mène. Avant, il fallait
/// lire, puis aller cocher ailleurs — et la lecture Botafogo ne se notait
/// que sur cet appareil.
@MainActor
enum TheoryTracking {

    /// Les éléments du cours qui mènent à cette adresse (ou ce chemin du polycopié).
    static func items(for address: String, in course: Course) -> [TheoryItem] {
        let wanted = key(address)
        guard !wanted.isEmpty else { return [] }
        return course.theoryItems.filter { item in
            ([item.urlString] + item.links.map(\.url)).contains { key($0) == wanted }
        }
    }

    /// Marque vu ce qui mène là ; rend ce qui vient d'être coché.
    ///
    /// Une leçon de MOOC porte plusieurs vidéos (ses liens) : elle n'est vue
    /// qu'une fois **toutes** ses vidéos vues, pas à la première.
    @discardableResult
    static func mark(_ address: String, in course: Course, at date: Date = Date()) -> [TheoryItem] {
        let wanted = key(address)
        var parts = Set(UserDefaults.standard.stringArray(forKey: partsKey) ?? [])
        var done: [TheoryItem] = []
        for item in items(for: address, in: course) where !item.isWatched {
            let videos = item.links.filter { $0.kind == .video }.map { key($0.url) }
            if videos.count > 1, videos.contains(wanted) {
                parts.insert(wanted)
                guard videos.allSatisfy(parts.contains) else { continue }
            }
            item.watchedAt = date
            done.append(item)
        }
        UserDefaults.standard.set(Array(parts).sorted(), forKey: partsKey)
        if !done.isEmpty { try? course.modelContext?.save() }
        return done
    }

    /// Les vidéos vues une à une, sur cet appareil (pour les leçons qui en ont plusieurs).
    private static let partsKey = "tracking.watchedParts"

    static func isPartWatched(_ address: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: partsKey) ?? []).contains(key(address))
    }

    /// Les sections du polycopié déjà vues, d'après les éléments cochés (sur
    /// n'importe quel appareil).
    static func readHandoutPaths(in course: Course) -> Set<String> {
        Set(course.theoryItems.filter(\.isWatched).compactMap { handoutPath($0.urlString) })
    }

    static func key(_ address: String) -> String { StudyLinkKey.key(address) }
    static func handoutPath(_ address: String) -> String? { StudyLinkKey.handoutPath(address) }
    static func coursewareBlock(_ address: String) -> String? { StudyLinkKey.coursewareBlock(address) }
}

private struct MarkStudiedKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
    /// « J'ai fini ceci » (une adresse, un chemin du polycopié, un bloc
    /// Courseware) : le cours ouvert coche ce qui y mène.
    var markStudied: ((String) -> Void)? {
        get { self[MarkStudiedKey.self] }
        set { self[MarkStudiedKey.self] = newValue }
    }
}

// MARK: - Où l'on s'était arrêté

/// La place dans chaque document, **sur cet appareil** : la seconde d'une
/// vidéo, la page d'un PDF, le passage d'une section du polycopié. Rouvrir
/// reprend là.
enum ReadingMemory {
    private static func key(_ kind: String, _ address: String) -> String {
        let digest = SHA256.hash(data: Data(address.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        return "resume.\(kind).\(digest)"
    }

    // Vidéo : la seconde, et la durée (pour « 12 min restantes »).
    static func video(_ address: String) -> (position: Double, duration: Double)? {
        guard let pair = UserDefaults.standard.array(forKey: key("video", address)) as? [Double], pair.count == 2 else { return nil }
        return (pair[0], pair[1])
    }

    static func setVideo(_ address: String, position: Double, duration: Double) {
        guard duration > 0 else { return }
        // Presque au bout : la prochaine fois, depuis le début.
        if position > duration - 15 || position < 5 {
            UserDefaults.standard.removeObject(forKey: key("video", address))
        } else {
            UserDefaults.standard.set([position, duration], forKey: key("video", address))
        }
    }

    // PDF : la page (0-based) et le nombre de pages.
    static func page(_ address: String) -> (page: Int, count: Int)? {
        guard let pair = UserDefaults.standard.array(forKey: key("pdf", address)) as? [Int], pair.count == 2 else { return nil }
        return (pair[0], pair[1])
    }

    static func setPage(_ address: String, page: Int, count: Int) {
        if page == 0 { UserDefaults.standard.removeObject(forKey: key("pdf", address)); return }
        UserDefaults.standard.set([page, count], forKey: key("pdf", address))
    }

    // Polycopié : le bloc repère où l'on lisait.
    static func block(_ path: String) -> Int? {
        UserDefaults.standard.object(forKey: key("poly", path)) as? Int
    }

    static func setBlock(_ path: String, _ index: Int?) {
        if let index, index > 0 { UserDefaults.standard.set(index, forKey: key("poly", path)) }
        else { UserDefaults.standard.removeObject(forKey: key("poly", path)) }
    }

    /// La vitesse de lecture des vidéos, la même partout.
    static var videoRate: Float {
        get { (UserDefaults.standard.object(forKey: "video.rate") as? Float) ?? 1 }
        set { UserDefaults.standard.set(newValue, forKey: "video.rate") }
    }
}
