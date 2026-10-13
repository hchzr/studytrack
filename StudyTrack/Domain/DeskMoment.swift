import Foundation

/// Le bureau prend la forme du moment.
///
/// Le mode étude ne savait faire qu'une chose : une série. En amphi, il n'y
/// avait rien pour suivre le cours ; avant un examen, rien pour réviser ; en
/// groupe, rien du groupe. Le bureau garde ses outils (le cours, la série,
/// Claude, le calcul, le web) mais son accueil — ce qu'on voit en entrant —
/// dépend de ce qu'on fait : l'horaire, le travail choisi, l'examen qui
/// approche, la session de groupe. Une décision pure, ici, testée.
enum DeskMoment: String, Codable, CaseIterable, Identifiable {
    /// En cours (amphi ou séance) : le contenu de la semaine, l'horloge du cours.
    case lecture
    /// Une série : l'exercice, la suite.
    case series
    /// Un examen approche : annales, théorie à revoir, exercices à refaire.
    case revision
    /// Une session de groupe : le chrono commun, chacun son travail.
    case together

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lecture: return String(localized: "En cours")
        case .series: return String(localized: "Séries")
        case .revision: return String(localized: "Révision")
        case .together: return String(localized: "Ensemble")
        }
    }

    var icon: String {
        switch self {
        case .lecture: return "person.wave.2"
        case .series: return "doc.text"
        case .revision: return "checklist"
        case .together: return "person.2"
        }
    }

    /// Un examen à moins de deux semaines fait passer le bureau en révision
    /// (sauf pour une série, qui reste une série — avec l'examen en tête).
    static let revisionWindowDays = 14

    static func resolve(taskType: TaskType, inGroup: Bool, daysToExam: Int?) -> DeskMoment {
        if inGroup { return .together }
        if taskType == .lecture { return .lecture }
        if let days = daysToExam, days >= 0, days <= revisionWindowDays, taskType.canonical != .exercise {
            return .revision
        }
        return .series
    }
}

/// Le cours de l'horaire, vu du bureau : où on en est, la pause, la suite.
enum LectureClock {
    /// On ouvre le bureau du cours dix minutes avant qu'il commence.
    static let lead: TimeInterval = 10 * 60

    /// Le cours (ou la séance) en cours à `now`, ou qui commence dans les dix
    /// minutes. Le plus proche s'il y en a deux.
    static func current(at now: Date, in slots: [FocusContext.Slot]) -> FocusContext.Slot? {
        let open = slots.filter { slot in
            let inClass = slot.kind == .lecture || slot.kind == .exerciseSession
            return inClass && slot.start.addingTimeInterval(-lead) <= now && now < slot.end
        }
        return open.min { first, second in
            abs(first.start.timeIntervalSince(now)) < abs(second.start.timeIntervalSince(now))
        }
    }

    /// Le prochain créneau du jour après `now`.
    static func next(after now: Date, in slots: [FocusContext.Slot], calendar: Calendar = .current) -> FocusContext.Slot? {
        slots.filter { $0.start > now && calendar.isDate($0.start, inSameDayAs: now) && $0.kind != .personal }
            .min { $0.start < $1.start }
    }

    /// La pause : à l'EPFL, deux fois 45 minutes et un quart d'heure entre
    /// les deux. Un créneau d'au moins 1 h 45 a sa pause à +45 min.
    static func breakWindow(of slot: FocusContext.Slot) -> DateInterval? {
        guard slot.end.timeIntervalSince(slot.start) >= 105 * 60 else { return nil }
        return DateInterval(start: slot.start.addingTimeInterval(45 * 60), duration: 15 * 60)
    }

    enum Phase: Equatable {
        /// Pas encore commencé : dans `minutes`.
        case before(minutes: Int)
        case running
        case pause(untilMinutes: Int)
        case over
    }

    static func phase(of slot: FocusContext.Slot, at now: Date) -> Phase {
        if now < slot.start { return .before(minutes: Int((slot.start.timeIntervalSince(now) / 60).rounded(.up))) }
        if now >= slot.end { return .over }
        if let pause = breakWindow(of: slot), pause.contains(now) {
            return .pause(untilMinutes: Int((pause.end.timeIntervalSince(now) / 60).rounded(.up)))
        }
        return .running
    }

    /// La fraction écoulée du créneau (0 → 1).
    static func progress(of slot: FocusContext.Slot, at now: Date) -> Double {
        let total = slot.end.timeIntervalSince(slot.start)
        guard total > 0 else { return 1 }
        return min(1, max(0, now.timeIntervalSince(slot.start) / total))
    }

    /// Les minutes du mode étude pour tenir jusqu'à la fin du créneau.
    static func studyMinutes(for slot: FocusContext.Slot, now: Date) -> Int {
        let minutes = Int((slot.end.timeIntervalSince(now) / 60).rounded(.up))
        return min(max(minutes, StudyMode.minuteRange.lowerBound), StudyMode.minuteRange.upperBound)
    }
}

/// Un repère : un instant du cours à revoir, d'un toucher, sans rien écrire.
///
/// On décroche, une démonstration passe trop vite : on touche « Repère ». Une
/// fois l'enregistrement en ligne, chaque repère l'ouvre à cette minute-là.
/// Ce n'est pas une prise de notes — les notes restent dans GoodNotes.
struct LectureMark: Codable, Equatable, Identifiable {
    var id = UUID()
    var courseID: UUID
    /// Le début du créneau : l'origine de l'enregistrement.
    var classStart: Date
    var at: Date

    /// Le moment dans l'enregistrement (qui commence avec le cours).
    var offset: TimeInterval { max(0, at.timeIntervalSince(classStart)) }

    /// « 12:34 », « 1:02:03 ».
    var offsetLabel: String {
        let total = Int(offset)
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%d:%02d", minutes, seconds)
    }
}

enum LectureMarks {
    /// On garde un mois de repères, deux cents au plus.
    static let keepDays = 30
    static let limit = 200
    /// Deux touchers à moins de 20 s : un seul repère.
    static let debounce: TimeInterval = 20

    static func adding(_ mark: LectureMark, to marks: [LectureMark], now: Date = Date()) -> [LectureMark] {
        let cutoff = now.addingTimeInterval(-Double(keepDays) * 86_400)
        var kept = marks.filter { $0.at >= cutoff }
        if let last = kept.last(where: { $0.courseID == mark.courseID }), abs(mark.at.timeIntervalSince(last.at)) < debounce {
            return kept
        }
        kept.append(mark)
        return Array(kept.suffix(limit))
    }

    /// Les repères d'un créneau.
    static func of(courseID: UUID, classStart: Date, in marks: [LectureMark]) -> [LectureMark] {
        marks.filter { $0.courseID == courseID && abs($0.classStart.timeIntervalSince(classStart)) < 60 }
            .sorted { $0.at < $1.at }
    }

    /// Les derniers créneaux qui ont des repères, du plus récent au plus ancien.
    static func classes(of courseID: UUID, in marks: [LectureMark]) -> [Date] {
        var seen: [Date] = []
        for mark in marks.filter({ $0.courseID == courseID }).sorted(by: { $0.classStart > $1.classStart })
        where !seen.contains(where: { abs($0.timeIntervalSince(mark.classStart)) < 60 }) {
            seen.append(mark.classStart)
        }
        return seen
    }

    /// L'adresse d'un enregistrement ouverte à `offset` : `st=` pour MediaSpace
    /// (Kaltura), `t=` pour YouTube, `#t=` sinon (lecteurs HTML5).
    static func seekURL(_ url: URL, offset: TimeInterval) -> URL {
        let seconds = Int(offset)
        guard seconds > 0, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let host = components.host?.lowercased() ?? ""
        var items = components.queryItems ?? []
        if host.contains("mediaspace") || host.contains("kaltura") || host.contains("switch.ch") {
            items.removeAll { $0.name == "st" }
            items.append(URLQueryItem(name: "st", value: "\(seconds)"))
            components.queryItems = items
        } else if host.contains("youtu") {
            items.removeAll { $0.name == "t" }
            items.append(URLQueryItem(name: "t", value: "\(seconds)"))
            components.queryItems = items
        } else {
            components.fragment = "t=\(seconds)"
        }
        return components.url ?? url
    }

    /// `…?st=754` ou `…#t=754` → 754 (le lecteur natif s'y place).
    static func startOffset(in address: String) -> TimeInterval? {
        guard let components = URLComponents(string: address) else { return nil }
        if let value = components.queryItems?.first(where: { $0.name == "st" || $0.name == "t" })?.value, let seconds = Double(value) {
            return seconds
        }
        if let fragment = components.fragment, fragment.hasPrefix("t="), let seconds = Double(fragment.dropFirst(2)) {
            return seconds
        }
        return nil
    }

    static func encode(_ marks: [LectureMark]) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try? encoder.encode(marks)
    }

    static func decode(_ data: Data?) -> [LectureMark] {
        guard let data else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode([LectureMark].self, from: data)) ?? []
    }
}

/// Avant un examen : par quoi commencer.
enum RevisionFocus {
    /// Les annales dans l'ordre où les travailler : jamais faites d'abord (les
    /// plus récentes en tête), puis celles qu'on ne sait pas (rouge, orange),
    /// les sues en dernier.
    static func pastExamOrder(_ items: [(id: UUID, year: Int, worked: Bool, confidence: ConfidenceLevel?)]) -> [UUID] {
        func rank(_ item: (id: UUID, year: Int, worked: Bool, confidence: ConfidenceLevel?)) -> Int {
            guard item.worked else { return 0 }
            switch item.confidence {
            case .some(.low): return 1
            case .some(.medium), .none: return 2
            case .some(.high): return 3
            }
        }
        return items.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            return ra != rb ? ra < rb : a.year > b.year
        }.map(\.id)
    }
}
