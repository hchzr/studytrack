import Foundation

/// Explique (explique.epfl.ch) : l'outil d'AICC (CS-101) où vivent les cours
/// en replay, semaine par semaine, et les « exercices d'explication » à rendre.
///
/// Relevé sur le site (octobre 2026) : la page `/<cours>/lectures` titre chaque
/// semaine « Week N » (`h2`) et liste ses cours, chacun un lien
/// `/<cours>/v/<id>` vers le lecteur vidéo (avec un assistant IA) ; la page
/// `/<cours>/exercises` donne, par semaine, l'échéance (« Due on Tuesday
/// 29 September at 17:00 ») et les exercices `/<cours>/e/<id>`. Le contenu est
/// chargé par la page après connexion : l'app le lit dans le navigateur
/// invisible (`ExpliqueClient`), puis le range ici dans les semaines du cours.
enum ExpliqueImport {
    static let host = "explique.epfl.ch"

    struct Lecture: Equatable, Decodable {
        var week: Int
        var title: String
        var url: String
    }

    struct Exercise: Equatable, Decodable {
        var week: Int
        var title: String
        var url: String
        var due: String
        var done: Bool
    }

    /// `https://explique.epfl.ch/cs101/exercises` → `cs101`.
    static func slug(in links: [String]) -> String? {
        for link in links {
            guard let url = URL(string: link), url.host == host,
                  let first = url.path.split(separator: "/").first.map(String.init),
                  !["login", "api", "_next"].contains(first) else { continue }
            return first
        }
        return nil
    }

    /// Le cours sur Explique, d'après son code : CS-101 → `cs101`.
    static func slug(courseCode: String) -> String {
        courseCode.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: Échéances

    /// « Tuesday 29 September at 17:00 » → la date, à l'année du semestre.
    static func dueDate(_ text: String, termStart: Date?, calendar: Calendar = .current) -> Date? {
        let lower = text.lowercased()
        guard let regex = try? NSRegularExpression(pattern: #"(\d{1,2})\s+([a-zéû]+)(?:\s+(\d{4}))?(?:\s+(?:at|à)\s+(\d{1,2})[:h](\d{2}))?"#),
              let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) else { return nil }
        func group(_ index: Int) -> String? { Range(match.range(at: index), in: lower).map { String(lower[$0]) } }
        let months = ["january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6, "july": 7, "august": 8,
                      "september": 9, "october": 10, "november": 11, "december": 12,
                      "janvier": 1, "février": 2, "mars": 3, "avril": 4, "mai": 5, "juin": 6, "juillet": 7, "août": 8,
                      "septembre": 9, "octobre": 10, "novembre": 11, "décembre": 12]
        guard let day = group(1).flatMap(Int.init), let month = group(2).flatMap({ months[$0] }) else { return nil }
        var year = group(3).flatMap(Int.init) ?? calendar.component(.year, from: termStart ?? Date())
        if group(3) == nil, let termStart, month < calendar.component(.month, from: termStart) - 2 { year += 1 }
        return calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                  hour: group(4).flatMap(Int.init) ?? 23,
                                                  minute: group(5).flatMap(Int.init) ?? 59))
    }

    // MARK: Rangement

    /// « Lecture 5: Proofs (2026) » → 5 ; `nil` pour « Proofs - 1 ».
    static func lectureNumber(_ title: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"\blecture\s*(\d+)"#, options: .caseInsensitive),
              let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              let range = Range(match.range(at: 1), in: title) else { return nil }
        return Int(title[range])
    }

    /// Le titre sans ses variantes : « (2026) », « (view on speaker) ».
    static func baseTitle(_ title: String) -> String {
        title.replacingOccurrences(of: #"\s*\((?:\d{4}|view on speaker|speaker view|vue (?:sur l'|de l')orateur)\)"#,
                                   with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
    }

    /// Ajoute les cours (en replay) et les exercices d'Explique au brouillon
    /// Moodle, dans leurs semaines.
    ///
    /// **Un élément par semaine** : ses deux cours (mardi, mercredi) et leurs
    /// enregistrements successifs (l'an passé, cette année, vue sur l'orateur)
    /// deviennent les vidéos de l'élément de la semaine — celui venu de Moodle
    /// s'il existe, sinon un nouveau.
    static func merge(lectures: [Lecture], exercises: [Exercise], into draft: ContentDraft,
                      termStart: Date?, totalWeeks: Int = 14, calendar: Calendar = .current) -> (draft: ContentDraft, added: Int) {
        var result = draft
        var added = 0
        let currentYear = String(calendar.component(.year, from: termStart ?? Date()))

        let videos = CourseVideos.merge(lectures.map { CourseVideos.Video(title: $0.title, url: $0.url, week: $0.week > 0 ? $0.week : nil) },
                                        into: result, totalWeeks: totalWeeks, sourceLabel: "Explique", preferredYear: currentYear)
        result = videos.draft
        added += videos.added

        let known = Set(result.sections.flatMap(\.items).map(\.url))
        for exercise in exercises where !known.contains(exercise.url) {
            let title = exercise.title
                .replacingOccurrences(of: #"\s*explanation exercise$"#, with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespaces)
            var item = ContentDraftItem(kind: .deadline, number: "",
                                        title: "Explique · \(title)",
                                        url: exercise.url, videoCount: 0, seriesNumber: nil, theoryKind: .reading)
            item.date = dueDate(exercise.due, termStart: termStart, calendar: calendar)
            item.examKind = .assignment
            appendDeadline(item, to: &result)
            added += 1
        }
        return (result, added)
    }

    static let deadlinesTitle = "Échéances : rendus, projet, examen"

    private static func appendDeadline(_ item: ContentDraftItem, to draft: inout ContentDraft) {
        if let index = draft.sections.firstIndex(where: { $0.title == deadlinesTitle }) {
            draft.sections[index].items.append(item)
            draft.sections[index].items.sort { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
        } else {
            draft.sections.append(ContentDraftSection(title: deadlinesTitle, week: 0, weekIsInferred: false,
                                                      isIncluded: true, items: [item]))
        }
    }
}
