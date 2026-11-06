import Foundation

/// **Avec mesure** : le temps passé avec Claude Code, et les règles qu'on s'y donne.
///
/// Deux moitiés, un contrat de fichiers (`~/Library/Application Support/Polymestre/Claude/`) :
///
/// - le mod Claude Code (`ClaudePlugin/mesure`) compte chaque séance
///   (`sessions/<jour>/<séance>.json`), note les passes (`passes/<jour>/…`) et
///   applique les règles à chaque demande ;
/// - Polymestre écrit les règles et le contexte (`policy.json` : mode étude,
///   cours de la semaine, temps étudié) et montre le bilan.
///
/// Le calcul est le même des deux côtés : `ClaudePlugin/mesure/hooks/policy.ts` en
/// est la version du mod, ses tests et ceux de `Validation` portent les mêmes cas.
/// Les instants du contrat sont en **millisecondes** depuis 1970 (ceux du mod).
///
/// Ce qui ne vit qu'ici : **durcir s'applique tout de suite, assouplir le
/// lendemain** (`apply(desired:to:now:)`). On ne lâche pas ses limites sur un
/// coup de tête — c'est tout l'intérêt de se les donner à froid.
enum ClaudeMeasure {
    static let idle: TimeInterval = 5 * 60
    static let turnCap: TimeInterval = 20 * 60

    /// Étude (les dossiers d'étude, `~/EPFL` par défaut), projets (le reste), libre (exempté).
    enum Category: String, Codable, CaseIterable {
        case etude, projets, libre
        var label: String {
            switch self {
            case .etude: return String(localized: "étude")
            case .projets: return String(localized: "projets")
            case .libre: return String(localized: "libre")
            }
        }
    }

    enum EventKind: String, Codable { case s, p, d, e }

    struct Event: Codable, Equatable {
        var t: Double
        var k: EventKind
    }

    enum RuleID: String, Codable, CaseIterable {
        case lock, studyMode, lesson = "class", curfew, studyFirst, pause, budget
        var label: String {
            switch self {
            case .lock: return String(localized: "verrou du mode étude")
            case .studyMode: return String(localized: "mode étude")
            case .lesson: return String(localized: "cours")
            case .curfew: return String(localized: "couvre-feu")
            case .studyFirst: return String(localized: "d'abord étudier")
            case .pause: return String(localized: "pause")
            case .budget: return String(localized: "budget")
            }
        }
    }

    struct Blocked: Codable, Equatable {
        var t: Double
        var rule: RuleID
    }

    struct SessionRecord: Codable, Equatable {
        var v = 1
        var session: String
        var cwd: String
        var category: Category
        var headless: Bool
        var events: [Event]
        var blocks: [Blocked]
    }

    struct Pass: Codable, Equatable, Identifiable {
        var v = 1
        var at: Double
        var from: Double
        var until: Double
        var reason: String
        var rule: RuleID?
        var session: String
        var id: Double { at }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(v, forKey: .v); try c.encode(at, forKey: .at); try c.encode(from, forKey: .from)
            try c.encode(until, forKey: .until); try c.encode(reason, forKey: .reason)
            try c.encode(rule, forKey: .rule); try c.encode(session, forKey: .session)
        }
    }

    struct Curfew: Codable, Equatable {
        var start: String
        var end: String
    }

    /// Les règles. Les clés sont celles du mod : un `nil` s'écrit `null` (le mod
    /// lit « sans limite »), jamais omis — l'encodeur synthétisé les omettrait.
    struct Rules: Codable, Equatable {
        var budgetWeekday: Int? = 90
        var budgetWeekend: Int? = 180
        var curfew: Curfew? = Curfew(start: "23:30", end: "07:00")
        var curfewAll = false
        var studyFirstWeekday = 60
        var studyFirstWeekend = 0
        var duringClasses = true
        var duringStudyMode = true
        var streak: Int? = 50
        var pause = 10
        var passes = 2
        var passMinutes = 15
        var passDelay = 2
        var studyFolders = ["~/EPFL"]
        var freeFolders: [String] = []

        static let standard = Rules()

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Rules()
            budgetWeekday = c.contains(.budgetWeekday) ? try c.decodeIfPresent(Int.self, forKey: .budgetWeekday) : d.budgetWeekday
            budgetWeekend = c.contains(.budgetWeekend) ? try c.decodeIfPresent(Int.self, forKey: .budgetWeekend) : d.budgetWeekend
            curfew = c.contains(.curfew) ? try c.decodeIfPresent(Curfew.self, forKey: .curfew) : d.curfew
            curfewAll = try c.decodeIfPresent(Bool.self, forKey: .curfewAll) ?? d.curfewAll
            studyFirstWeekday = try c.decodeIfPresent(Int.self, forKey: .studyFirstWeekday) ?? d.studyFirstWeekday
            studyFirstWeekend = try c.decodeIfPresent(Int.self, forKey: .studyFirstWeekend) ?? d.studyFirstWeekend
            duringClasses = try c.decodeIfPresent(Bool.self, forKey: .duringClasses) ?? d.duringClasses
            duringStudyMode = try c.decodeIfPresent(Bool.self, forKey: .duringStudyMode) ?? d.duringStudyMode
            streak = c.contains(.streak) ? try c.decodeIfPresent(Int.self, forKey: .streak) : d.streak
            pause = try c.decodeIfPresent(Int.self, forKey: .pause) ?? d.pause
            passes = try c.decodeIfPresent(Int.self, forKey: .passes) ?? d.passes
            passMinutes = try c.decodeIfPresent(Int.self, forKey: .passMinutes) ?? d.passMinutes
            passDelay = try c.decodeIfPresent(Int.self, forKey: .passDelay) ?? d.passDelay
            studyFolders = try c.decodeIfPresent([String].self, forKey: .studyFolders) ?? d.studyFolders
            freeFolders = try c.decodeIfPresent([String].self, forKey: .freeFolders) ?? d.freeFolders
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(budgetWeekday, forKey: .budgetWeekday); try c.encode(budgetWeekend, forKey: .budgetWeekend)
            try c.encode(curfew, forKey: .curfew); try c.encode(curfewAll, forKey: .curfewAll)
            try c.encode(studyFirstWeekday, forKey: .studyFirstWeekday); try c.encode(studyFirstWeekend, forKey: .studyFirstWeekend)
            try c.encode(duringClasses, forKey: .duringClasses); try c.encode(duringStudyMode, forKey: .duringStudyMode)
            try c.encode(streak, forKey: .streak); try c.encode(pause, forKey: .pause)
            try c.encode(passes, forKey: .passes); try c.encode(passMinutes, forKey: .passMinutes)
            try c.encode(passDelay, forKey: .passDelay)
            try c.encode(studyFolders, forKey: .studyFolders); try c.encode(freeFolders, forKey: .freeFolders)
        }

        enum CodingKeys: String, CodingKey {
            case budgetWeekday, budgetWeekend, curfew, curfewAll, studyFirstWeekday, studyFirstWeekend
            case duringClasses, duringStudyMode, streak, pause, passes, passMinutes, passDelay, studyFolders, freeFolders
        }
    }

    struct StudyModeInfo: Codable, Equatable {
        var since: Double
        var until: Double
        var blocks: Bool
        var locks: Bool
    }

    struct Lesson: Codable, Equatable {
        var start: Double
        var end: Double
        var title: String
    }

    /// Le temps d'étude du jour : `seconds` déjà enregistré (sessions et cours
    /// suivis, `StudyTime`), plus le chrono ouvert (`accumulated`, `runningSince`).
    struct Studied: Codable, Equatable {
        var day: String
        var seconds: Double
        var accumulated: Double
        var runningSince: Double?

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(day, forKey: .day); try c.encode(seconds, forKey: .seconds)
            try c.encode(accumulated, forKey: .accumulated); try c.encode(runningSince, forKey: .runningSince)
        }
    }

    struct Context: Codable, Equatable {
        var studyMode: StudyModeInfo?
        var classes: [Lesson]
        var studied: Studied?

        static let empty = Context(studyMode: nil, classes: [], studied: nil)

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(studyMode, forKey: .studyMode); try c.encode(classes, forKey: .classes)
            try c.encode(studied, forKey: .studied)
        }
    }

    /// Ce qui attend le lendemain : les règles voulues, et l'état voulu (couper
    /// Avec mesure attend aussi). Le mod l'applique de lui-même à l'heure dite.
    struct Pending: Codable, Equatable {
        var rules: Rules
        var from: Double
        var enabled = true
    }

    struct Policy: Codable, Equatable {
        var v = 1
        var writtenAt: Double
        var enabled: Bool
        var enforceFrom: Double
        var rules: Rules
        var pending: Pending?
        var context: Context

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(v, forKey: .v); try c.encode(writtenAt, forKey: .writtenAt)
            try c.encode(enabled, forKey: .enabled); try c.encode(enforceFrom, forKey: .enforceFrom)
            try c.encode(rules, forKey: .rules); try c.encode(pending, forKey: .pending)
            try c.encode(context, forKey: .context)
        }

        /// Les règles voulues : celles qui attendent, sinon celles en vigueur.
        var desired: Rules { pending?.rules ?? rules }
    }

    // MARK: Instants

    static func ms(_ date: Date) -> Double { (date.timeIntervalSince1970 * 1000).rounded() }
    static func date(_ ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1000) }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func isWeekend(_ date: Date, calendar: Calendar = .current) -> Bool {
        calendar.isDateInWeekend(date)
    }

    private static func minutes(_ hhmm: String) -> Int {
        let parts = hhmm.split(separator: ":").map { Int($0) ?? 0 }
        return ((parts.first ?? 0) % 24) * 60 + (parts.count > 1 ? parts[1] : 0)
    }

    private static func at(_ day: Date, _ hhmm: String, calendar: Calendar) -> Date {
        calendar.startOfDay(for: day).addingTimeInterval(TimeInterval(minutes(hhmm) * 60))
    }

    /// Le couvre-feu en cours à `now` : sa fin, ou `nil`. Il peut passer minuit.
    static func curfewEnd(_ curfew: Curfew?, now: Date, calendar: Calendar = .current) -> Date? {
        guard let curfew else { return nil }
        let start = minutes(curfew.start), end = minutes(curfew.end)
        guard start != end else { return nil }
        let c = calendar.dateComponents([.hour, .minute], from: now)
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        if start < end { return minute >= start && minute < end ? at(now, curfew.end, calendar: calendar) : nil }
        if minute >= start { return at(calendar.date(byAdding: .day, value: 1, to: now) ?? now, curfew.end, calendar: calendar) }
        if minute < end { return at(now, curfew.end, calendar: calendar) }
        return nil
    }

    // MARK: Classement

    static func expand(_ path: String, home: String) -> String {
        var p = path.hasPrefix("~") ? home + path.dropFirst() : path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    static func categorize(_ cwd: String, rules: Rules, home: String) -> Category {
        var dir = cwd
        while dir.count > 1, dir.hasSuffix("/") { dir.removeLast() }
        func inside(_ folder: String) -> Bool { !folder.isEmpty && (dir == folder || dir.hasPrefix(folder + "/")) }
        if rules.freeFolders.contains(where: { inside(expand($0, home: home)) }) { return .libre }
        if rules.studyFolders.contains(where: { inside(expand($0, home: home)) }) { return .etude }
        return .projets
    }

    // MARK: Le temps compté

    typealias Span = (start: Double, end: Double)

    /// Les intervalles comptés d'une séance, bornés à [from, to) : d'une demande à
    /// la réponse (20 min au plus), d'une réponse à la demande suivante sous 5 min.
    static func intervals(_ record: SessionRecord, from: Double, to: Double, now: Double, live: Bool) -> [Span] {
        var events = record.events.sorted { $0.t < $1.t }
        if live, let last = events.last, last.k != .e { events.append(Event(t: now, k: .e)) }
        var out: [Span] = []
        for (a, b) in zip(events, events.dropFirst()) {
            let gap = b.t - a.t
            let credit: Double
            switch a.k {
            case .p: credit = min(gap, turnCap * 1000)
            case .d, .s: credit = gap <= idle * 1000 ? gap : 0
            case .e: credit = 0
            }
            let start = max(a.t, from), end = min(a.t + credit, to)
            if end > start { out.append((start, end)) }
        }
        return out
    }

    static func union(_ list: [Span], join: Double = 0) -> [Span] {
        var out: [Span] = []
        for span in list.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, span.start - last.end <= join {
                out[out.count - 1].end = max(last.end, span.end)
            } else {
                out.append(span)
            }
        }
        return out
    }

    private static func total(_ list: [Span]) -> Double { list.reduce(0) { $0 + $1.end - $1.start } }

    struct Usage: Equatable {
        var projets: TimeInterval = 0
        var etude: TimeInterval = 0
        var libre: TimeInterval = 0
        /// La série en cours sur les projets (ms), pauses courtes comprises.
        var streak: (start: Double, end: Double)?

        static func == (a: Usage, b: Usage) -> Bool {
            a.projets == b.projets && a.etude == b.etude && a.libre == b.libre
                && a.streak?.start == b.streak?.start && a.streak?.end == b.streak?.end
        }

        func seconds(_ category: Category) -> TimeInterval {
            switch category { case .etude: return etude; case .projets: return projets; case .libre: return libre }
        }
    }

    /// Le temps du jour de `now`, par catégorie ; `day` pour un autre jour (fini).
    static func usage(_ records: [SessionRecord], now: Date, rules: Rules, liveSession: String? = nil,
                      calendar: Calendar = .current) -> Usage {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? now
        let from = ms(start), to = ms(end), t = ms(now)
        var by: [Category: [Span]] = [:]
        var recorded: [Span] = []
        for record in records where !record.headless {
            by[record.category, default: []] += intervals(record, from: from, to: to, now: t, live: record.session == liveSession)
            if record.category == .projets { recorded += intervals(record, from: from, to: to, now: t, live: false) }
        }
        let blocks = union(recorded, join: Double(rules.pause) * 60_000)
        var use = Usage()
        use.projets = total(union(by[.projets] ?? [])) / 1000
        use.etude = total(union(by[.etude] ?? [])) / 1000
        use.libre = total(union(by[.libre] ?? [])) / 1000
        if let last = blocks.last, t - last.end < Double(rules.pause) * 60_000 { use.streak = (last.start, last.end) }
        return use
    }

    static func studiedKnown(_ context: Context, now: Date) -> Bool {
        context.studied?.day == dayKey(now)
    }

    static func studiedSeconds(_ context: Context, now: Date) -> Double {
        guard let s = context.studied, s.day == dayKey(now) else { return 0 }
        let live = s.runningSince.map { max(0, (ms(now) - $0) / 1000) } ?? 0
        return s.seconds + s.accumulated + live
    }

    // MARK: La règle du moment

    static func effectiveRules(_ policy: Policy, now: Date) -> Rules {
        if let pending = policy.pending, ms(now) >= pending.from { return pending.rules }
        return policy.rules
    }

    static func effectiveEnabled(_ policy: Policy, now: Date) -> Bool {
        if let pending = policy.pending, ms(now) >= pending.from { return pending.enabled }
        return policy.enabled
    }

    static func budgetMinutes(_ rules: Rules, now: Date) -> Int? {
        isWeekend(now) ? rules.budgetWeekend : rules.budgetWeekday
    }

    static func activePass(_ passes: [Pass], now: Date) -> Pass? {
        let t = ms(now)
        return passes.first { t >= $0.from && t < $0.until }
    }

    static func waitingPass(_ passes: [Pass], now: Date) -> Pass? {
        let t = ms(now)
        return passes.first { t >= $0.at && t < $0.from }
    }

    static func passesLeft(_ rules: Rules, _ passes: [Pass], now: Date) -> Int {
        let today = dayKey(now)
        return max(0, rules.passes - passes.filter { dayKey(date($0.at)) == today }.count)
    }

    struct Verdict: Equatable {
        var allow = true
        var rule: RuleID?
        var until: Date?
        var message = ""
        var passable = false
        var observing = false
        var warn: String?
        var remainingMinutes: Int?
    }

    static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%d h %02d", c.hour ?? 0, c.minute ?? 0)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded()))
        return minutes < 60 ? "\(minutes) min" : String(format: "%d h %02d", minutes / 60, minutes % 60)
    }

    private struct Block { var rule: RuleID; var until: Date?; var message: String; var passable: Bool }

    private static func firstBlock(_ category: Category, rules: Rules, context: Context, use: Usage, now: Date) -> Block? {
        let t = ms(now)
        let mode = context.studyMode.flatMap { t >= $0.since && t < $0.until ? $0 : nil }
        if let mode, mode.locks, category != .etude {
            return Block(rule: .lock, until: date(mode.until),
                         message: "Verrou du mode étude jusqu'à \(clock(date(mode.until))) : ici, Claude ne sert qu'à étudier.", passable: false)
        }
        let curfew = curfewEnd(rules.curfew, now: now)
        if let curfew, rules.curfewAll, category != .libre {
            return Block(rule: .curfew, until: curfew, message: "Couvre-feu jusqu'à \(clock(curfew)). Dors : tout sera là demain.", passable: true)
        }
        guard category == .projets else { return nil }
        if let mode, mode.blocks, rules.duringStudyMode {
            return Block(rule: .studyMode, until: date(mode.until),
                         message: "Mode étude en cours jusqu'à \(clock(date(mode.until))) : les projets attendent.", passable: false)
        }
        if rules.duringClasses, let lesson = context.classes.first(where: { t >= $0.start && t < $0.end }) {
            return Block(rule: .lesson, until: date(lesson.end),
                         message: "Cours en ce moment (\(lesson.title), jusqu'à \(clock(date(lesson.end)))) : les projets attendent.", passable: false)
        }
        if let curfew {
            return Block(rule: .curfew, until: curfew, message: "Couvre-feu jusqu'à \(clock(curfew)). Dors : le code sera là demain.", passable: true)
        }
        // Le temps étudié n'est connu que si Polymestre l'a écrit aujourd'hui : sinon
        // (l'app fermée depuis hier), la règle ne peut pas se vérifier et ne bloque pas.
        let needed = Double((isWeekend(now) ? rules.studyFirstWeekend : rules.studyFirstWeekday) * 60)
        let studied = studiedSeconds(context, now: now)
        if needed > 0, studiedKnown(context, now: now), studied < needed {
            return Block(rule: .studyFirst, until: nil,
                         message: "D'abord étudier : encore \(duration(needed - studied)) dans Polymestre (\(duration(studied)) sur \(duration(needed)) aujourd'hui).",
                         passable: true)
        }
        if let streak = rules.streak, let run = use.streak, run.end - run.start >= Double(streak) * 60_000 {
            let until = date(run.end + Double(rules.pause) * 60_000)
            return Block(rule: .pause, until: until,
                         message: "Pause : \(duration((run.end - run.start) / 1000)) d'affilée sur les projets. Reprends à \(clock(until)).", passable: true)
        }
        if let budget = budgetMinutes(rules, now: now), use.projets >= Double(budget * 60) {
            return Block(rule: .budget, until: Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)),
                         message: "Budget du jour atteint : \(duration(use.projets)) sur \(duration(Double(budget * 60))) de projets.", passable: true)
        }
        return nil
    }

    static func evaluate(_ category: Category, headless: Bool, policy: Policy?, use: Usage, passes: [Pass], now: Date) -> Verdict {
        guard let policy, effectiveEnabled(policy, now: now), !headless else { return Verdict() }
        let rules = effectiveRules(policy, now: now)
        let budget = budgetMinutes(rules, now: now)
        let remaining = category == .projets ? budget.map { max(0, Int((Double($0) - use.projets / 60).rounded())) } : nil
        let pass = activePass(passes, now: now)
        if let block = firstBlock(category, rules: rules, context: policy.context, use: use, now: now), !(block.passable && pass != nil) {
            let left = passesLeft(rules, passes, now: now)
            let hint: String
            if !block.passable { hint = "" }
            else if let waiting = waitingPass(passes, now: now) { hint = " Ton pass s'ouvre à \(clock(date(waiting.from)))." }
            else if left > 0 { hint = " /mesure encore <raison> : \(left) pass \(left > 1 ? "restants" : "restant")." }
            else { hint = " Plus de pass aujourd'hui." }
            if ms(now) < policy.enforceFrom {
                return Verdict(allow: true, rule: block.rule, until: block.until, message: "Observation : " + block.message + hint,
                               observing: true, remainingMinutes: remaining)
            }
            return Verdict(allow: false, rule: block.rule, until: block.until, message: block.message + hint,
                           passable: block.passable, remainingMinutes: remaining)
        }
        var verdict = Verdict(remainingMinutes: remaining)
        if let pass {
            verdict.warn = "Pass ouvert jusqu'à \(clock(date(pass.until))) (\(pass.reason))."
        } else if category == .projets, let budget, use.projets >= Double(budget * 60) * 0.8 {
            verdict.warn = "Projets : \(duration(use.projets)) sur \(duration(Double(budget * 60))) aujourd'hui."
        } else if category == .projets, let streak = rules.streak, let run = use.streak,
                  run.end - run.start >= Double(streak - 10) * 60_000 {
            verdict.warn = "\(duration((run.end - run.start) / 1000)) d'affilée : une pause arrive à \(streak) min."
        }
        return verdict
    }

    // MARK: Durcir tout de suite, assouplir le lendemain

    /// Le premier 4 h du matin au moins douze heures après `now` : un assouplissement
    /// demandé le soir ne s'applique pas dans la nuit même.
    static func nextMorning(after now: Date, calendar: Calendar = .current) -> Date {
        var day = calendar.startOfDay(for: now)
        while true {
            let candidate = day.addingTimeInterval(4 * 3600)
            if candidate.timeIntervalSince(now) >= 12 * 3600 { return candidate }
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        }
    }

    /// Les minutes d'un créneau (couvre-feu) comme ensemble, pour comparer deux couvre-feux.
    private static func curfewMinutes(_ curfew: Curfew?) -> Set<Int> {
        guard let curfew else { return [] }
        let start = minutes(curfew.start), end = minutes(curfew.end)
        guard start != end else { return [] }
        return start < end ? Set(start..<end) : Set(start..<1440).union(0..<end)
    }

    /// `nil` (sans limite) est le plus lâche ; sinon le plus petit est le plus strict.
    private static func stricterLimit(_ a: Int?, _ b: Int?) -> Int? {
        switch (a, b) {
        case let (x?, y?): return min(x, y)
        case let (x?, nil): return x
        case let (nil, y?): return y
        default: return nil
        }
    }

    /// Règle par règle, la plus stricte des deux.
    static func stricter(_ a: Rules, _ b: Rules) -> Rules {
        var r = a
        r.budgetWeekday = stricterLimit(a.budgetWeekday, b.budgetWeekday)
        r.budgetWeekend = stricterLimit(a.budgetWeekend, b.budgetWeekend)
        let ca = curfewMinutes(a.curfew), cb = curfewMinutes(b.curfew)
        r.curfew = cb.isSuperset(of: ca) ? b.curfew : ca.isSuperset(of: cb) ? a.curfew : (ca.count >= cb.count ? a.curfew : b.curfew)
        r.curfewAll = a.curfewAll || b.curfewAll
        r.studyFirstWeekday = max(a.studyFirstWeekday, b.studyFirstWeekday)
        r.studyFirstWeekend = max(a.studyFirstWeekend, b.studyFirstWeekend)
        r.duringClasses = a.duringClasses || b.duringClasses
        r.duringStudyMode = a.duringStudyMode || b.duringStudyMode
        r.streak = stricterLimit(a.streak, b.streak)
        r.pause = max(a.pause, b.pause)
        r.passes = min(a.passes, b.passes)
        r.passMinutes = min(a.passMinutes, b.passMinutes)
        r.passDelay = max(a.passDelay, b.passDelay)
        // Un dossier exempté ou d'étude de plus, c'est plus lâche : on garde ceux des deux qui sont communs.
        r.studyFolders = a.studyFolders.filter(b.studyFolders.contains)
        r.freeFolders = a.freeFolders.filter(b.freeFolders.contains)
        return r
    }

    /// Les réglages voulus appliqués à la règle écrite : ce qui durcit vaut tout
    /// de suite, ce qui assouplit attend le lendemain matin (`pending`). Couper
    /// Avec mesure est un assouplissement comme un autre.
    static func apply(desired: Rules, enabled: Bool, to policy: Policy?, now: Date) -> Policy {
        let t = ms(now)
        guard var policy, policy.enabled else {
            // Première mise en route (ou reprise) : une journée d'observation, rien ne bloque.
            return Policy(writtenAt: t, enabled: enabled, enforceFrom: ms(nextMorning(after: now)),
                          rules: desired, pending: nil, context: policy?.context ?? .empty)
        }
        let current = effectiveRules(policy, now: now)
        policy.rules = stricter(current, desired)
        policy.writtenAt = t
        if policy.rules != desired || !enabled {
            // Une demande déjà en attente garde son heure : y revenir ne la repousse pas.
            let from = policy.pending?.from ?? ms(nextMorning(after: now))
            policy.pending = Pending(rules: desired, from: from, enabled: enabled)
        } else {
            policy.pending = nil
        }
        return policy
    }

    /// Ce qui attend son heure : à la relecture, une demande échue s'applique.
    static func settle(_ policy: Policy, now: Date) -> Policy {
        var p = policy
        let t = ms(now)
        if let pending = p.pending, t >= pending.from {
            p.rules = pending.rules
            p.enabled = pending.enabled
            p.pending = nil
        }
        return p
    }

    // MARK: Le bilan

    struct DaySummary: Codable, Equatable, Identifiable {
        var day: String
        var projets: TimeInterval
        var etude: TimeInterval
        var libre: TimeInterval
        var passes: Int
        var blocks: Int
        var id: String { day }
    }

    /// Un jour, des séances lues dans les dossiers du jour et de la veille.
    static func summary(day: Date, records: [SessionRecord], passes: [Pass], rules: Rules, now: Date,
                        calendar: Calendar = .current) -> DaySummary {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? day
        let moment = min(now, end.addingTimeInterval(-1))
        let use = usage(records, now: moment, rules: rules, calendar: calendar)
        let key = dayKey(start)
        let from = ms(start), to = ms(end)
        let blocks = records.reduce(0) { $0 + $1.blocks.filter { $0.t >= from && $0.t < to }.count }
        return DaySummary(day: key, projets: use.projets, etude: use.etude, libre: use.libre,
                          passes: passes.filter { dayKey(date($0.at)) == key }.count, blocks: blocks)
    }
}

