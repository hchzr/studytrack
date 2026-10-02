import Foundation

/// Amphi, exercices ou autre : le type d'une séance de l'horaire, décidé une
/// fois pour toutes au même endroit.
///
/// Le bilan affichait 35 h d'amphi pour une semaine qui en compte une douzaine.
/// Deux causes, cumulées :
///   • l'horaire était lu **deux fois** — l'import `.ics` (qui connaît le type
///     de séance par `CATEGORIES`) et le calendrier de l'iPhone abonné au même
///     flux (qui ne le connaît pas) ;
///   • le calendrier de l'iPhone ne transmet pas `CATEGORIES` : toute séance
///     d'un cours sans mot-clé dans l'intitulé (« Analyse I (classe
///     inversée) ») devenait un cours magistral, exercices compris.
///
/// Les signaux, du plus sûr au moins sûr :
///   1. un choix fait à la main pour ce créneau (« c'est une séance
///      d'exercices ») ;
///   2. `CATEGORIES` de l'horaire EPFL (`Cours`, `Exercices`, `Labo`) ;
///   3. ce que l'horaire importé dit **du même créneau** (même cours, même jour,
///      même heure) — c'est ainsi qu'un événement du calendrier de l'iPhone
///      hérite du type que l'`.ics` connaissait ;
///   4. les mots de l'intitulé (« exercices », « TP », « midterm ») ;
///   5. **le nombre de salles** : une séance d'exercices de l'EPFL se tient
///      dans plusieurs salles à la fois (« CE1101, CE1105, CO010… »), un cours
///      magistral dans une seule. Vérifié sur tout un horaire de BA1 : aucune
///      exception sur 165 séances ;
///   6. à défaut, un événement rattaché à un cours reste un cours.
enum TimetableClassifier {

    /// Le nombre de salles d'un lieu (« CE1106, CE1515 » → 2, « » → 0).
    static func roomCount(_ location: String) -> Int {
        location
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "/" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .count
    }

    /// Le type d'une séance sans indication explicite : intitulé, puis salles.
    ///
    /// `hasCourse` : l'événement est rattaché à un cours suivi. Sans cours, un
    /// intitulé sans mot-clé n'est pas un cours de l'EPFL — c'est l'agenda
    /// personnel.
    static func kind(title: String, location: String, hasCourse: Bool) -> CalendarEventKind {
        let haystack = title.lowercased()
        if haystack.contains("midterm") || haystack.contains("mid-term") || haystack.contains("contrôle") {
            return .midterm
        }
        if haystack.contains("examen") || haystack.contains("exam") || haystack.contains("final") {
            return .exam
        }
        // L'agenda **personnel** qui cite un cours n'est pas l'horaire : un bloc
        // « 🧠 MATH-111 — finir la série », une échéance « [CS-107] Rendu du
        // projet ». Rattachés au cours par leur code, ils devenaient des cours
        // magistraux, et leurs heures s'ajoutaient au travail de la semaine.
        if isDeadline(title) { return .other }
        if isPersonal(title) { return .study }
        if haystack.contains("exercice") || haystack.contains("exercise") || haystack.contains("série")
            || haystack.contains("serie") || haystack.contains(" tp") || haystack.contains("labo") {
            return .exerciseSession
        }
        // Plusieurs salles : des groupes d'exercices, jamais un amphi.
        if roomCount(location) >= 2 { return .exerciseSession }
        if haystack.contains("cours") || haystack.contains("lecture") || haystack.contains("amphi") {
            return .lecture
        }
        if haystack.contains("révision") || haystack.contains("revision") || haystack.contains("étude") {
            return .study
        }
        return hasCourse ? .lecture : .other
    }

    /// Un intitulé d'agenda personnel : il commence par un symbole (émoji, « ✓ »,
    /// « [ ») — l'horaire EPFL commence toujours par le nom du cours.
    static func isPersonal(_ title: String) -> Bool {
        guard let first = title.trimmingCharacters(in: .whitespaces).first else { return false }
        return !(first.isLetter || first.isNumber)
    }

    /// Une échéance, pas une séance : rendu, remise, défense, deadline.
    static func isDeadline(_ title: String) -> Bool {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return ["rendu", "remise", "deadline", "due ", "defense", "soumission", "a rendre"].contains { folded.contains($0) }
    }

    /// Le type d'une séance de l'horaire EPFL : `CATEGORIES` d'abord, puis le
    /// reste.
    static func kind(categories: String, title: String, location: String, hasCourse: Bool) -> CalendarEventKind {
        switch ICSParser.isLectureCategory(categories) {
        case true?: return .lecture
        case false?: return .exerciseSession
        case nil: return kind(title: title, location: location, hasCourse: hasCourse)
        }
    }

    // MARK: Créneaux

    /// Un créneau hebdomadaire : le même cours, le même jour, à la même heure.
    ///
    /// C'est l'unité qu'on corrige : dire « le lundi 8 h 15 d'Analyse est une
    /// séance d'exercices » vaut pour tout le semestre, pas pour une occurrence.
    struct Slot: Hashable {
        /// Le cours (son identifiant), sinon l'intitulé replié.
        var owner: String
        /// 1 = dimanche … 7 = samedi.
        var weekday: Int
        /// Minutes depuis minuit.
        var minute: Int
    }

    static func slot(owner: String, start: Date, calendar: Calendar = .current) -> Slot {
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: start)
        return Slot(owner: owner,
                    weekday: parts.weekday ?? 0,
                    minute: (parts.hour ?? 0) * 60 + (parts.minute ?? 0))
    }

    /// Le propriétaire d'un créneau : le cours quand on le connaît.
    static func owner(courseID: UUID?, title: String) -> String {
        if let courseID { return courseID.uuidString }
        return title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Deux événements sont-ils la **même** séance, lue par deux sources ?
    ///
    /// Même cours, même début à la minute près. L'horaire `.ics` et le
    /// calendrier abonné au même flux ne donnent pas le même identifiant : on
    /// ne peut comparer que ce qu'ils décrivent.
    static func isSameSession(courseA: UUID?, startA: Date, courseB: UUID?, startB: Date) -> Bool {
        guard let courseA, let courseB, courseA == courseB else { return false }
        return abs(startA.timeIntervalSince(startB)) < 90
    }

    /// Ce que les séances connues disent de chaque créneau.
    ///
    /// Un choix manuel l'emporte ; sinon le type le plus fréquent parmi les
    /// séances au type **sûr** (`.ics` ou manuel). Un créneau où les sources se
    /// contredisent à égalité n'est pas tranché.
    struct KnownSession {
        var slot: Slot
        var kind: CalendarEventKind
        var isManual: Bool
    }

    static func learnedKinds(_ sessions: [KnownSession]) -> [Slot: CalendarEventKind] {
        var manual: [Slot: CalendarEventKind] = [:]
        var votes: [Slot: [CalendarEventKind: Int]] = [:]
        for session in sessions {
            if session.isManual {
                manual[session.slot] = session.kind
            } else {
                votes[session.slot, default: [:]][session.kind, default: 0] += 1
            }
        }
        var result: [Slot: CalendarEventKind] = [:]
        for (slot, counts) in votes {
            let sorted = counts.sorted { $0.value > $1.value }
            guard let best = sorted.first else { continue }
            if sorted.count > 1, sorted[1].value == best.value { continue }
            result[slot] = best.key
        }
        for (slot, kind) in manual { result[slot] = kind }
        return result
    }

    // MARK: Heures hebdomadaires

    /// Les heures d'amphi et d'exercices d'une semaine type, lues dans l'horaire.
    ///
    /// Les cours créés par l'import recevaient « 2 h de cours, 1 h
    /// d'exercices » quel que soit l'horaire : la charge attendue d'Analyse
    /// (3 h 45 + 1 h 45 par semaine) était donc fausse dès le premier jour.
    /// On prend la **médiane** des semaines où le cours a lieu : une semaine
    /// tronquée (jour férié, rentrée) ne fait pas la règle. Arrondi au quart
    /// d'heure.
    static func weeklyHours(_ sessions: [(start: Date, seconds: Int, kind: CalendarEventKind)],
                            calendar: Calendar = .current) -> (lecture: Double, exercise: Double) {
        var lecture: [Date: Int] = [:]
        var exercise: [Date: Int] = [:]
        var weeks = Set<Date>()
        for session in sessions {
            guard let week = calendar.dateInterval(of: .weekOfYear, for: session.start)?.start else { continue }
            weeks.insert(week)
            switch session.kind {
            case .lecture: lecture[week, default: 0] += session.seconds
            case .exerciseSession: exercise[week, default: 0] += session.seconds
            default: break
            }
        }
        func median(_ totals: [Date: Int]) -> Double {
            let values = weeks.map { totals[$0] ?? 0 }.sorted()
            guard !values.isEmpty else { return 0 }
            let middle = values.count / 2
            let seconds = values.count % 2 == 0 ? Double(values[middle - 1] + values[middle]) / 2 : Double(values[middle])
            return (seconds / 3600 * 4).rounded() / 4
        }
        return (median(lecture), median(exercise))
    }
}
