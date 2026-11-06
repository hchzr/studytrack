import Foundation

/// Quels énoncés et corrigés garder sur l'iPhone, dans quel ordre, et jusqu'où.
///
/// Pur, donc testé. La place est comptée : ce qui sert **maintenant** passe en
/// premier (la semaine en cours et la suivante), puis le passé récent (on
/// révise d'abord les dernières séries), puis le reste du semestre.
enum OfflinePlan {
    struct Candidate: Equatable {
        /// L'adresse normalisée du document : la clé de son fichier.
        var key: String
        var week: Int
        var isSolution: Bool
        /// La semaine en cours **de son cours** : deux cours peuvent ne pas
        /// suivre le même calendrier.
        var currentWeek: Int
    }

    /// Le rang d'une semaine : la semaine en cours, la suivante, puis le
    /// passé du plus récent au plus ancien, puis le futur lointain.
    static func rank(week: Int, current: Int) -> Int {
        if week == current { return 0 }
        if week == current + 1 { return 1 }
        if week < current { return 1 + (current - week) }
        return 100 + (week - current)
    }

    /// Les documents voulus, du plus utile au moins utile ; sans doublon.
    static func order(_ candidates: [Candidate], includeSolutions: Bool) -> [Candidate] {
        var seen = Set<String>()
        return candidates
            .filter { includeSolutions || !$0.isSolution }
            .enumerated()
            .sorted { lhs, rhs in
                let a = rank(week: lhs.element.week, current: lhs.element.currentWeek)
                let b = rank(week: rhs.element.week, current: rhs.element.currentWeek)
                if a != b { return a < b }
                // À semaine égale, l'énoncé avant son corrigé.
                if lhs.element.isSolution != rhs.element.isSolution { return !lhs.element.isSolution }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
            .filter { seen.insert($0.key).inserted }
    }

    /// Ce qui tient sous le plafond, dans l'ordre : les tailles connues
    /// s'additionnent ; un document au-delà du plafond n'est pas gardé (ni
    /// ceux qui suivent, pour que l'ordre reste respecté).
    static func kept(_ ordered: [String], sizes: [String: Int], limit: Int) -> Set<String> {
        var total = 0
        var kept = Set<String>()
        for key in ordered {
            guard let size = sizes[key] else { continue }
            guard total + size <= limit else { break }
            total += size
            kept.insert(key)
        }
        return kept
    }

    /// « 128 Mo », « 1,2 Go ».
    static func label(bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
