import Foundation

/// Le plan d'un cours, lu **sans modèle** quand sa forme le permet.
///
/// Les plans de l'EPFL sont souvent des tableaux : une ligne par semaine (« 3 ·
/// 23/09/2026 · 25/09/2026 »), puis ce qu'il y a à faire (« MOOC 1 : vidéos
/// Module 2 »). Le modèle de langage lisait ce tableau aplati en texte, et
/// décalait les chapitres d'une semaine — les vidéos « à regarder » étaient
/// celles de la semaine suivante. Ici, la semaine courante est suivie ligne
/// par ligne : aucune ambiguïté. Le modèle reste le repli pour les autres
/// formes de plan.
enum CoursePlanParser {

    /// Une demande du plan : regarder les vidéos du module `module` du MOOC
    /// `mooc` (1, 2…) en semaine `week`.
    struct MoocAssignment: Equatable {
        var mooc: Int
        var module: Int
        var week: Int
    }

    static func moocAssignments(in plan: String, totalWeeks: Int) -> [MoocAssignment] {
        var result: [MoocAssignment] = []
        var week: Int?
        let header = try? NSRegularExpression(pattern: #"^(?:semaine|week|sem\.?)?\s*(\d{1,2})(?:\s+\d{1,2}[./]\d{1,2}[./]\d{2,4}.*)?$"#,
                                              options: .caseInsensitive)
        let video = try? NSRegularExpression(pattern: #"mooc\s*(\d)?\s*:\s*(?:les\s+)?vid[ée]os?\s+(?:du\s+)?modules?\s+(\d{1,2})((?:\s*(?:,|et|&|à|-)\s*\d{1,2})*)"#,
                                             options: .caseInsensitive)
        for raw in plan.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let range = NSRange(line.startIndex..., in: line)
            // Une ligne qui ouvre une semaine : « 3 », « 3 23/09/2026 25/09/2026 », « Semaine 3 ».
            if let match = header?.firstMatch(in: line, range: range),
               let value = Range(match.range(at: 1), in: line).flatMap({ Int(line[$0]) }),
               (1...totalWeeks).contains(value) {
                week = value
                continue
            }
            guard let week, let regex = video else { continue }
            for match in regex.matches(in: line, range: range) {
                let mooc = Range(match.range(at: 1), in: line).flatMap { Int(line[$0]) } ?? 1
                guard let first = Range(match.range(at: 2), in: line).flatMap({ Int(line[$0]) }) else { continue }
                var modules = [first]
                if let rest = Range(match.range(at: 3), in: line) {
                    modules += line[rest].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
                }
                for module in modules where !result.contains(where: { $0.mooc == mooc && $0.module == module }) {
                    result.append(MoocAssignment(mooc: mooc, module: module, week: week))
                }
            }
        }
        return result
    }

    /// Les semaines des chapitres, par identifiant : le module `n` du MOOC `k`
    /// est le `n`-ième chapitre de `moocs[k-1]` hors préambule et quiz — la
    /// même numérotation que celle donnée au modèle.
    static func chapterWeeks(_ assignments: [MoocAssignment], moocs: [ScrapedCourse]) -> [String: Int] {
        var result: [String: Int] = [:]
        for assignment in assignments {
            guard moocs.indices.contains(assignment.mooc - 1) else { continue }
            let modules = moocs[assignment.mooc - 1].sections.filter { $0.id != nil && !MoodleCourseAI.isFrontMatter($0) }
            guard modules.indices.contains(assignment.module - 1), let id = modules[assignment.module - 1].id else { continue }
            result[id] = min(result[id] ?? assignment.week, assignment.week)
        }
        return result
    }
}
