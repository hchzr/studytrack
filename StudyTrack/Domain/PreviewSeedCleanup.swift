import Foundation
import SwiftData

/// Le cours d'essai des captures du Mac (`-memoryStore -previewSeed`) est parti
/// dans le vrai iCloud : la base « en mémoire » n'avait pas `cloudKitDatabase:
/// .none` et se synchronisait. On le retire, **lui seul** : son nom exact, son
/// site Botafogo d'essai, et une série qui pointe vers le PDF du dépôt sur le
/// disque (`file://…/Analyse I Serie 03.pdf`) — aucun cours importé n'a ça.
enum PreviewSeedCleanup {
    static func isLeakedSeed(name: String, contentSources: [String], seriesAddresses: [String]) -> Bool {
        name == "Analyse I (classe inversée)"
            && contentSources == ["https://botafogo.epfl.ch/analyse-1-flipped/"]
            && seriesAddresses.contains { address in
                address.hasPrefix("file://")
                    && (address.hasSuffix("Analyse%20I%20Serie%2003.pdf") || address.hasSuffix("Analyse I Serie 03.pdf"))
            }
    }

    @discardableResult
    static func run(in context: ModelContext) -> Int {
        guard let courses = try? context.fetch(FetchDescriptor<Course>()) else { return 0 }
        let leaked = courses.filter {
            isLeakedSeed(name: $0.name, contentSources: $0.contentSources, seriesAddresses: $0.series.map(\.urlString))
        }
        // Le temps chronométré dessus (s'il y en a) rejoint le vrai cours du
        // même code avant la suppression, qui emporterait les sessions ; sans
        // vrai cours pour les recevoir, on ne supprime rien.
        var removed = 0
        for course in leaked {
            if !course.sessions.isEmpty {
                guard let real = courses.first(where: { $0.code == course.code && !leaked.contains($0) }) else { continue }
                for session in course.sessions { session.course = real; session.exercise = nil; session.theoryItem = nil }
            }
            context.delete(course)
            removed += 1
        }
        if removed > 0 {
            try? context.save()
            AppLog.record(.info, AppLog.Category.sync, "cours d'essai retiré (\(removed))")
        }
        return removed
    }
}
