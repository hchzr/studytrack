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
    ///
    /// Le modèle lit **tout ce que le cours montre** — sections et leurs
    /// consignes, activités et ce qu'il y a derrière chaque lien, plan du cours,
    /// MOOC — et dit ce qu'il faut regarder et faire chaque semaine, et où sont
    /// les exercices. Rien n'est propre à un cours : un cours jamais vu se lit
    /// de la même façon. Ses réponses ne désignent que des éléments reçus
    /// (identifiants, références de liens), vérifiés à l'arrivée.
    static let instructions = """
    Tu lis un cours de l'EPFL comme un·e étudiant·e attentif·ve, pour une app de suivi d'études. Tu reçois les sections Moodle (titre, semaine si connue, texte et consignes, liens cités « Lnn »), chaque activité (id, type Moodle, nom, où mène le lien, ce qu'est la cible et le début de son texte), et parfois le PLAN DU COURS et les MOOC cités (chapitres numérotés). Le cours peut avoir n'importe quelle forme : comprends-le d'après son contenu, pas d'après des habitudes.
    Réponds UNIQUEMENT par un objet JSON :
    {"activities":[{"id":"123","kind":"theory","week":3,"series":null}],"series":[{"number":3,"week":3,"statement":"a123","solution":"a124"}],"mooc":[{"id":"<id du chapitre>","week":3}],"weeks":[{"week":3,"todo":"…"}]}
    - activities : une entrée par activité reçue, avec son id exact. kind : "theory" (cours, enregistrement, transparents, notes, polycopié, chapitre à lire), "series" (énoncé d'exercices à faire), "solution" (corrigé), "deadline" (rendu noté, devoir, projet, quiz noté), "document" (organisation, formulaire, ressource générale, ancien examen, matériel facultatif), "ignore" (forum, annonce, sondage, lien sans contenu). week : la semaine du semestre (1 à N) où l'activité se travaille — d'après la section, une date, un numéro (« Lecture 7 » avec deux cours par semaine → semaine 4) ou une consigne ; null si inconnue. series : son numéro de série pour "series" et "solution", sinon null.
    - series : chaque série d'exercices du cours, une entrée par numéro. statement : la référence (« a » + id d'activité, ou « Lnn » pour un lien du texte d'une section) qui mène à l'ÉNONCÉ LUI-MÊME, la page ou le PDF où sont les exercices. Choisis d'après ce que contient la cible (son début de texte), pas seulement d'après le nom : un lien « série 4 » qui mène à un chapitre de MOOC sans ces exercices n'est pas l'énoncé ; une page « énoncé/corrigé » ou « corrigé » qui contient aussi les énoncés peut l'être. solution : le corrigé s'il est à une autre adresse, sinon null. week : la semaine où la série se fait.
    - Les exercices et quiz d'un MOOC ne sont des séries que si le cours (consignes, plan) demande de les faire.
    - mooc : si un MOOC est fourni, les chapitres dont le cours demande de regarder les vidéos, avec la semaine — d'après le plan, les consignes des sections ou les liens de chaque semaine. « MOOC 2 : vidéos Module 3 » désigne l'entrée « module 3 » du MOOC 2 (préambules hors numérotation). La semaine est celle de la ligne du plan ou de la section : ne la décale jamais. Uniquement des id de la liste ; rien d'optionnel.
    - weeks : pour chaque semaine où il y a du travail, la consigne en une phrase courte (160 caractères au plus), concrète, à l'infinitif : quoi regarder (enregistrement, chapitres du MOOC et leurs numéros), quoi lire, quelle série faire, ce qui est à rendre. Uniquement d'après ce que tu as reçu.
    - N'invente aucun id ni aucune référence.
    """

    /// Une série comprise par le modèle : son numéro, sa semaine, et les
    /// références (« a123 », « L4 ») de son énoncé et de son corrigé.
    struct SeriesPlan: Equatable {
        var number: Int
        var week: Int?
        var statement: String?
        var solution: String?
    }

    /// Ce que le modèle répond : une étiquette par activité, les séries et
    /// où sont leurs énoncés, la semaine des chapitres du MOOC à regarder, et
    /// la consigne de chaque semaine.
    struct Answer: Equatable {
        var hints: [String: MoodleAIHint] = [:]
        var moocWeeks: [String: Int] = [:]
        var series: [SeriesPlan] = []
        var guide: [Int: String] = [:]
    }

    /// Les références de liens données au modèle : « a<id> » pour une
    /// activité, « L<n> » pour un lien du texte d'une section, dans l'ordre.
    static func references(in snapshot: MoodleCourseSnapshot) -> [String: (url: String, solution: String?)] {
        var result: [String: (url: String, solution: String?)] = [:]
        var counter = 0
        for section in snapshot.sections {
            for activity in section.activities where activity.isVisible {
                result["a" + activity.id] = (activity.link, activity.solutionTarget)
            }
            for link in section.links {
                counter += 1
                result["L\(counter)"] = (link.url, nil)
            }
        }
        return result
    }

    /// Le cours, compact : ce que le modèle lit.
    static func payload(for snapshot: MoodleCourseSnapshot, termStart: Date?, totalWeeks: Int,
                        plan: String? = nil, moocs: [ScrapedCourse] = [],
                        calendar: Calendar = .current) -> [String: Any] {
        var lines: [String] = []
        var counter = 0
        for section in snapshot.sections {
            let week = MoodleCourseAnalyzer.week(of: section, termStart: termStart, totalWeeks: totalWeeks, calendar: calendar)
            lines.append("## Section \(section.number) : \(MoodleCourseAnalyzer.sectionTitle(section))" + (week.map { " [semaine \($0)]" } ?? ""))
            let text = compact(section.text, limit: 700)
            if !text.isEmpty { lines.append("Texte : « \(text) »") }
            for link in section.links {
                counter += 1
                lines.append("Lien L\(counter) : \(link.title.isEmpty ? "(sans titre)" : link.title) → \(shortURL(link.url))")
            }
            for activity in section.activities where activity.isVisible {
                var line = "- id=\(activity.id) [\(activity.module)] \(activity.name)"
                if let target = URL(string: activity.link), target.host != nil, !activity.link.contains("/mod/\(activity.module)/view.php") {
                    line += " → \(shortURL(activity.link))"
                } else if let host = URL(string: activity.link)?.host {
                    line += " → \(host)"
                }
                if let solution = activity.solutionTarget, !solution.isEmpty { line += " (corrigé à côté : \(shortURL(solution)))" }
                if let destination = activity.destination { line += " {\(destination)}" }
                if let preview = activity.preview.map({ compact($0, limit: 260) }), !preview.isEmpty { line += " « \(preview) »" }
                lines.append(line)
            }
        }
        var payload: [String: Any] = ["course": snapshot.title, "weeks": totalWeeks, "outline": lines.joined(separator: "\n"),
                                      "instructions": instructions]
        if let plan, !plan.isEmpty { payload["plan"] = String(plan.prefix(12_000)) }
        if !moocs.isEmpty {
            payload["mooc"] = moocs.enumerated().flatMap { index, mooc in
                // Les chapitres numérotés comme les « Module N » des plans de cours
                // (préambule, bienvenue et quiz hors numérotation).
                var module = 0
                return ["# MOOC \(index + 1) : \(mooc.title)"] + mooc.sections.compactMap { chapter -> String? in
                    guard let id = chapter.id else { return nil }
                    let videos = chapter.items.reduce(0) { $0 + ($1.videoCount ?? 0) }
                    let label: String
                    if isFrontMatter(chapter) {
                        label = "\(chapter.title) [hors module]"
                    } else {
                        module += 1
                        label = "module \(module) — \(chapter.title)"
                    }
                    let lessons = chapter.items.prefix(14).map(\.title).joined(separator: " ; ")
                    return "- id=\(id) : \(label) (\(chapter.items.count) leçons, \(videos) vidéos : \(lessons))"
                }
            }.joined(separator: "\n")
        }
        return payload
    }

    /// `proginsc.epfl.ch/wwwhiver/series/serie04/serie.html` : l'hôte et le
    /// chemin disent souvent ce qu'est un lien.
    static func shortURL(_ address: String) -> String {
        guard let url = URL(string: address), let host = url.host else { return String(address.prefix(120)) }
        let path = (url.path.removingPercentEncoding ?? url.path)
        return String((host + path).prefix(120))
    }

    private static func compact(_ text: String, limit: Int) -> String {
        let flat = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    static func answer(_ raw: String) -> Answer {
        var result = Answer(hints: parse(raw))
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
              let data = String(raw[start...end]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return result }
        func int(_ value: Any?) -> Int? {
            if let number = value as? NSNumber { return number.intValue }
            if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespaces)) }
            return nil
        }
        func ref(_ value: Any?) -> String? {
            let text = (value as? String) ?? (value as? NSNumber)?.stringValue
            guard var text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty, text.lowercased() != "null" else { return nil }
            if text.allSatisfy(\.isNumber) { text = "a" + text }
            return text
        }
        for entry in json["mooc"] as? [[String: Any]] ?? [] {
            guard let id = entry["id"] as? String, let week = int(entry["week"]), week > 0 else { continue }
            result.moocWeeks[id] = min(result.moocWeeks[id] ?? week, week)
        }
        for entry in json["series"] as? [[String: Any]] ?? [] {
            guard let number = int(entry["number"]), number > 0,
                  !result.series.contains(where: { $0.number == number }) else { continue }
            result.series.append(SeriesPlan(number: number, week: int(entry["week"]).flatMap { $0 > 0 ? $0 : nil },
                                            statement: ref(entry["statement"]), solution: ref(entry["solution"])))
        }
        for entry in json["weeks"] as? [[String: Any]] ?? [] {
            guard let week = int(entry["week"]), week > 0,
                  let todo = (entry["todo"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !todo.isEmpty else { continue }
            result.guide[week] = String(todo.prefix(240))
        }
        return result
    }

    /// Un chapitre hors programme, reconnu à son titre **ou à ses leçons** :
    /// l'accueil d'un MOOC (« Bienvenue », « Informations pratiques »,
    /// « Installation »…) ne porte pas toujours un titre parlant, et le compter
    /// comme « module 1 » décalait tous les modules d'une semaine.
    static func isFrontMatter(_ chapter: ScrapedSection) -> Bool {
        if isFrontMatter(chapter.title) { return true }
        let lessons = chapter.items.map { $0.title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil) }
        let welcome = lessons.contains { $0.range(of: #"\b(bienvenue|welcome|informations pratiques|installation|preambule|prise en main)\b"#, options: .regularExpression) != nil }
        let assessed = lessons.contains { $0.range(of: #"\b(controle des connaissances|quiz|exercices?)\b"#, options: .regularExpression) != nil }
        return welcome && !assessed
    }

    /// Un chapitre hors programme : accueil, préambule, quiz final, annexe.
    static func isFrontMatter(_ title: String) -> Bool {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return folded.range(of: #"\b(bienvenue|welcome|preambule|preamble|quiz|examen|exam|annexe|appendix|ressources)\b"#,
                            options: .regularExpression) != nil
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
