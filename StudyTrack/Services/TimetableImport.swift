import Foundation
import SwiftData

/// Import d'un emploi du temps iCalendar (« Mon horaire » EPFL ou tout autre flux).
///
/// Contrairement à une intégration Moodle, ce chemin fonctionne réellement à l'EPFL :
/// l'étudiant·e exporte/colle son flux `.ics`, l'app en déduit ses cours, détecte
/// lesquels ont des heures de cours (amphi) et crée les événements liés.
enum TimetableImport {

    struct Result {
        var coursesCreated = 0
        var coursesMatched = 0
        var eventsCreated = 0
        var eventsSkipped = 0
        var lecturesDetected = 0
        var sectionApplied = 0

        var message: String {
            var parts: [String] = []
            if coursesCreated > 0 { parts.append("\(coursesCreated) cours créé(s)") }
            if coursesMatched > 0 { parts.append("\(coursesMatched) cours reconnu(s)") }
            if eventsCreated > 0 { parts.append("\(eventsCreated) séance(s) importée(s)") }
            if eventsSkipped > 0 { parts.append("\(eventsSkipped) déjà présente(s)") }
            if lecturesDetected > 0 { parts.append("\(lecturesDetected) cours avec amphi détecté(s)") }
            return parts.isEmpty ? "Aucun événement trouvé dans le flux." : parts.joined(separator: " · ")
        }
    }

    // MARK: Récupération du flux

    enum TimetableError: LocalizedError {
        case invalidURL
        case network(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "URL du flux invalide."
            case .network(let detail): return "Téléchargement impossible : \(detail)"
            case .empty: return "Le flux ne contient aucun événement."
            }
        }
    }

    /// Télécharge un flux `.ics` (accepte `webcal://`).
    static func fetch(urlString: String) async throws -> String {
        var raw = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw TimetableError.invalidURL }
        if raw.lowercased().hasPrefix("webcal://") {
            raw = "https://" + raw.dropFirst("webcal://".count)
        }
        guard let url = URL(string: raw), url.scheme != nil else { throw TimetableError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("StudyTrack/1.0", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw TimetableError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TimetableError.network("HTTP \(http.statusCode)")
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              !text.isEmpty else { throw TimetableError.empty }
        return text
    }

    // MARK: Import

    @discardableResult
    static func `import`(_ icsText: String,
                         into context: ModelContext,
                         sectionCode: String = "") -> Result {
        var result = Result()
        let icsEvents = ICSParser.parse(icsText)
        guard !icsEvents.isEmpty else { return result }

        var courses = (try? context.fetch(FetchDescriptor<Course>())) ?? []
        var existingEventIDs = Set(
            ((try? context.fetch(FetchDescriptor<LinkedCalendarEvent>())) ?? [])
                .compactMap(\.externalEventID)
        )
        // Le semestre auquel rattacher les cours créés ici.
        //
        // Les créer avec `term: nil` les affichait en « semaine 1 » à perpétuité :
        // `Course.currentWeek` n'avait rien pour calculer, et retombait sur 1. Un
        // import en semaine 2 donnait donc « 1 / 14 » partout, sans aucun signe
        // d'erreur.
        let term = AcademicTerm.current(in: context)

        var lectureCourses = Set<UUID>()
        /// Un cours compte **une fois**, même s'il a 5 séances dans la semaine.
        var matchedCourses = Set<UUID>()
        var createdCourses = Set<UUID>()

        for event in icsEvents {
            // Le code n'est pas toujours dans l'intitulé — « Mon horaire » le met
            // souvent dans la description. On regarde les trois champs, du plus
            // fiable au moins fiable, avant de renoncer.
            // Uniquement l'intitulé et la description. **Jamais le lieu** : les
            // salles de l'EPFL s'écrivent « BS-170 », « CE1515 », « SG1 138 » — le
            // format exact d'un code de cours. Chercher là-dedans créait des cours
            // nommés d'après une salle.
            let code = detectCourseCode(in: event.summary)
                ?? detectCourseCode(in: event.notes)
            let name = cleanedName(event.summary, code: code)

            // 1. Retrouver ou créer le cours.
            var course: Course?
            if let code {
                course = courses.first { $0.code.caseInsensitiveCompare(code) == .orderedSame }
            }
            // Replier sur le nom, comparé sans accents ni ponctuation : un ICS qui
            // écrit « Algèbre linéaire » doit retrouver « Algebre lineaire ».
            // La comparaison exacte échouait et créait un cours en double.
            if course == nil, !name.isEmpty {
                let key = nameKey(name)
                course = courses.first { nameKey($0.name) == key }
            }

            // Un code officiel vient d'être retrouvé alors que le cours portait un
            // code fabriqué par un import précédent : on le corrige. C'est le seul
            // moyen de réparer les cours déjà importés sans code.
            if let code, let existing = course, !isOfficialCode(existing.code) {
                existing.code = code
            }

            if course == nil {
                let resolvedCode = code ?? derivedCode(from: name, existing: courses.map(\.code))
                let created = Course(code: resolvedCode,
                                     name: name.isEmpty ? resolvedCode : name,
                                     credits: 4,
                                     colorHex: Theme.coursePalette[courses.count % Theme.coursePalette.count],
                                     term: term,
                                     weeklyLectureHours: 2,
                                     weeklyExerciseHours: 1,
                                     hasLectures: false,
                                     sectionCode: sectionCode)
                context.insert(created)
                courses.append(created)
                course = created
                createdCourses.insert(created.id)
            } else if let existing = course {
                matchedCourses.insert(existing.id)
            }

            guard let course else { continue }

            // Un cours retrouvé mais sans semestre (import d'une version
            // antérieure) est rattaché au passage.
            if course.term == nil { course.term = term }

            // Renseigner la section du cours existant si elle est vide.
            if !sectionCode.isEmpty, course.sectionCode.isEmpty {
                course.sectionCode = sectionCode
                result.sectionApplied += 1
            }

            // 2. Créer la séance si elle n'existe pas déjà.
            let identifier = "ics:\(event.uid):\(Int(event.start.timeIntervalSince1970))"
            if existingEventIDs.contains(identifier) {
                result.eventsSkipped += 1
                continue
            }

            // `CATEGORIES` tranche quand il se prononce : un événement marqué
            // « Cours » est un cours magistral, quoi que dise son intitulé. Sinon on
            // retombe sur l'analyse du titre.
            let kind = ICSParser.isLectureCategory(event.categories) == true
                ? CalendarEventKind.lecture
                : CalendarSync.classify(title: event.summary, course: course)
            if kind == .lecture, !course.hasLectures {
                // Le cours a des heures d'amphi : c'est exactement ce que la question
                // « cette classe a-t-elle cours ? » cherche à savoir.
                course.hasLectures = true
                result.lecturesDetected += 1
            }
            let linked = LinkedCalendarEvent(externalEventID: identifier,
                                             sourceCalendarID: "ics",
                                             title: event.summary,
                                             startsAt: event.start,
                                             endsAt: event.end,
                                             location: event.location,
                                             kind: kind)
            linked.course = course
            linked.lastSyncedAt = Date()
            context.insert(linked)
            existingEventIDs.insert(identifier)
            result.eventsCreated += 1

            if kind == .lecture, !lectureCourses.contains(course.id) {
                lectureCourses.insert(course.id)
                if !course.hasLectures {
                    course.hasLectures = true
                }
                result.lecturesDetected += 1
            }
        }

        result.coursesCreated = createdCourses.count
        result.coursesMatched = matchedCourses.count

        try? context.save()
        return result
    }

    // MARK: Extraction d'informations

    /// Repère un code de cours EPFL dans un intitulé (« CS-250 Algorithms I », « MATH-101 »…).
    static func detectCourseCode(in summary: String) -> String? {
        let pattern = "\\b([A-Z]{2,5})[-\\s]?(\\d{3})\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(summary.startIndex..<summary.endIndex, in: summary)
        guard let match = regex.firstMatch(in: summary, range: range),
              let letterRange = Range(match.range(at: 1), in: summary),
              let digitRange = Range(match.range(at: 2), in: summary) else { return nil }
        return "\(summary[letterRange])-\(summary[digitRange])"
    }

    /// Retire le code et les suffixes de type de séance de l'intitulé.
    static func cleanedName(_ summary: String, code: String?) -> String {
        var name = summary
        if let code {
            name = name.replacingOccurrences(of: code, with: "")
            name = name.replacingOccurrences(of: code.replacingOccurrences(of: "-", with: " "), with: "")
        }
        let noise = ["cours", "exercices", "exercise session", "lecture", "amphi",
                     "série", "serie", "tp", "labo", "laboratoire", "projet", "test",
                     "contrôle", "controle", "midterm", "examen", "exam"]
        var tokens = name
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map(String.init)

        tokens = tokens.filter { token in
            !noise.contains(token.lowercased())
        }

        let cleaned = tokens.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? summary : cleaned
    }

    /// Un code EPFL officiel : deux à cinq lettres, puis trois chiffres.
    ///
    /// Sert à distinguer « CS-250 » d'un code fabriqué par `derivedCode`
    /// (« ANALYSE ») quand un import ultérieur retrouve le vrai.
    static func isOfficialCode(_ value: String) -> Bool {
        detectCourseCode(in: value) != nil
    }

    /// Clé de comparaison d'un intitulé : sans accents, sans casse, sans ponctuation,
    /// espaces normalisés.
    ///
    /// « Algèbre linéaire » et « Algebre lineaire » doivent désigner le même cours :
    /// un ICS et la saisie manuelle ne s'accordent pas sur les accents.
    static func nameKey(_ raw: String) -> String {
        raw.folding(options: [.diacriticInsensitive, .caseInsensitive],
                    locale: Locale(identifier: "fr_CH"))
            .map { $0.isLetter || $0.isNumber ? String($0) : " " }
            .joined()
            .split(separator: " ")
            .joined(separator: " ")
    }

    /// Fabrique un code court et unique quand l'intitulé n'en contient pas.
    static func derivedCode(from name: String, existing: [String]) -> String {
        let letters = name.uppercased().filter { $0.isLetter }
        var base = String(letters.prefix(7))
        if base.isEmpty { base = "COURS" }
        if !existing.contains(base) { return base }

        var index = 2
        while existing.contains("\(base)-\(index)") { index += 1 }
        return "\(base)-\(index)"
    }
}
