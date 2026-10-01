import Foundation

/// Ce qu'un modèle de langage a compris d'une activité Moodle que les règles ne
/// savent pas lire : sa nature, sa semaine, son numéro de série.
///
/// Les règles de `MoodleCourseAnalyzer` ont été écrites sur quelques cours
/// réels ; un enseignant·e qui nomme ses séries « TP 3 – Récursivité », ses
/// cours « Séance du 14 », ou qui pose tout dans une seule section, leur
/// échappe. Le modèle lit alors **le plan du cours** (noms, types, sections —
/// jamais de contenu personnel) et répond par une étiquette par activité. Sa
/// réponse ne remplace que ce qu'elle tranche ; le reste suit les règles.
struct MoodleAIHint: Equatable {
    var kind: MoodleCourseAnalyzer.ActivityKind?
    var week: Int?
    var seriesNumber: Int?
}

enum MoodleCourseAI {

    /// La consigne, partagée par la fonction serveur et le modèle embarqué.
    static let instructions = """
    Tu ranges les activités d'un cours Moodle de l'EPFL pour une app de suivi d'études.
    Réponds UNIQUEMENT par un objet JSON : {"activities":[{"id":"123","kind":"theory","week":3,"series":null}]}
    - kind : "theory" (cours, vidéo, enregistrement, transparents, notes, polycopié, chapitre à lire), "series" (énoncé d'une série / feuille / TP d'exercices), "solution" (corrigé), "deadline" (rendu noté, devoir, projet, quiz noté), "document" (organisation, formulaire, ressource générale, ancien examen), "ignore" (forum, annonce, sondage, lien sans contenu).
    - week : la semaine du semestre (1 à N) où l'activité se travaille, d'après la section (« Semaine 3 », une plage de dates), un numéro (« Lecture 7 » quand il y a deux cours par semaine → semaine 4), ou une date. null si inconnue.
    - series : le numéro de la série d'exercices quand kind vaut "series" ou "solution", sinon null.
    - Une entrée par activité reçue, avec son id exact. N'invente aucune activité.
    Si un PLAN DU COURS et un MOOC sont fournis, ajoute "mooc":[{"id":"<id du chapitre>","week":N}] : les chapitres du MOOC dont le plan demande de regarder les VIDÉOS une semaine donnée. Jamais les quiz ni les exercices du MOOC, jamais un chapitre que le plan ne cite pas, rien d'optionnel. La semaine est le numéro que le plan donne à la ligne (souvent en tête, avant les dates) : ne le décale jamais. N'utilise QUE des id de chapitres présents dans la liste.
    """

    /// Ce que le modèle répond : une étiquette par activité, et la semaine
    /// des chapitres du MOOC que le plan du cours demande de regarder.
    struct Answer: Equatable {
        var hints: [String: MoodleAIHint] = [:]
        var moocWeeks: [String: Int] = [:]
    }

    /// Le plan du cours, compact : ce que le modèle lit.
    static func payload(for snapshot: MoodleCourseSnapshot, termStart: Date?, totalWeeks: Int,
                        plan: String? = nil, moocs: [ScrapedCourse] = [],
                        calendar: Calendar = .current) -> [String: Any] {
        var lines: [String] = []
        for section in snapshot.sections {
            let week = MoodleCourseAnalyzer.week(of: section, termStart: termStart, totalWeeks: totalWeeks, calendar: calendar)
            lines.append("## Section \(section.number) : \(MoodleCourseAnalyzer.sectionTitle(section))" + (week.map { " [semaine \($0)]" } ?? ""))
            for activity in section.activities where activity.isVisible {
                let host = URL(string: activity.link)?.host.map { " → \($0)" } ?? ""
                lines.append("- id=\(activity.id) [\(activity.module)] \(activity.name)\(host)")
            }
        }
        var payload: [String: Any] = ["course": snapshot.title, "weeks": totalWeeks, "outline": lines.joined(separator: "\n")]
        if let plan, !plan.isEmpty { payload["plan"] = String(plan.prefix(9000)) }
        if !moocs.isEmpty {
            payload["mooc"] = moocs.enumerated().flatMap { index, mooc in
                ["# MOOC \(index + 1) : \(mooc.title)"] + mooc.sections.compactMap { chapter -> String? in
                    guard let id = chapter.id else { return nil }
                    let videos = chapter.items.reduce(0) { $0 + ($1.videoCount ?? 0) }
                    return "- id=\(id) : \(chapter.title) (\(chapter.items.count) leçons, \(videos) vidéos)"
                }
            }.joined(separator: "\n")
        }
        return payload
    }

    static func answer(_ raw: String) -> Answer {
        var result = Answer(hints: parse(raw))
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
              let data = String(raw[start...end]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mooc = json["mooc"] as? [[String: Any]] else { return result }
        for entry in mooc {
            guard let id = entry["id"] as? String, let week = (entry["week"] as? NSNumber)?.intValue, week > 0 else { continue }
            result.moocWeeks[id] = min(result.moocWeeks[id] ?? week, week)
        }
        return result
    }

    /// La réponse du modèle, tolérante : texte autour, champs manquants.
    static func parse(_ raw: String) -> [String: MoodleAIHint] {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
              let data = String(raw[start...end]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let activities = json["activities"] as? [[String: Any]] else { return [:] }
        var result: [String: MoodleAIHint] = [:]
        for entry in activities {
            let id = (entry["id"] as? String) ?? (entry["id"] as? NSNumber)?.stringValue
            guard let id else { continue }
            let kind: MoodleCourseAnalyzer.ActivityKind?
            switch (entry["kind"] as? String)?.lowercased() {
            case "theory", "video", "lecture": kind = .lecture
            case "series", "exercise", "exercises": kind = .series
            case "solution": kind = .solution
            case "deadline", "assignment": kind = .deadline
            case "document", "resource": kind = .document
            case "ignore": kind = .ignore
            default: kind = nil
            }
            let week = (entry["week"] as? NSNumber)?.intValue
            let series = (entry["series"] as? NSNumber)?.intValue
            result[id] = MoodleAIHint(kind: kind, week: week.flatMap { $0 > 0 ? $0 : nil },
                                      seriesNumber: series.flatMap { $0 > 0 ? $0 : nil })
        }
        return result
    }
}
