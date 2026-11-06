import Foundation
import SwiftData

// MARK: - Modèle iCalendar

/// Un événement iCalendar, éventuellement issu d'une récurrence.
struct ICSEvent {
    var uid: String
    var summary: String
    var start: Date
    var end: Date
    var location: String
    var notes: String
    var isRecurring: Bool
    /// Valeurs de `CATEGORIES`, concaténées. Porte le **type de séance**.
    var categories: String = ""

    var durationSeconds: Int { max(0, Int(end.timeIntervalSince(start))) }
}

/// Analyseur iCalendar (RFC 5545), volontairement autonome et sans dépendance.
///
/// EPFL publie l'horaire personnel des étudiant·e·s au format `.ics`
/// (« Mon horaire »). C'est la seule intégration d'emploi du temps réaliste :
/// aucune API n'est ouverte aux étudiant·e·s. Ce parseur couvre ce que produit
/// un emploi du temps universitaire : `VEVENT`, `DTSTART`/`DTEND` (UTC, local,
/// `TZID`, journée entière), `RRULE` hebdomadaire/quotidienne, `EXDATE`.
enum ICSParser {

    /// Nombre maximal d'occurrences générées par événement récurrent.
    private static let occurrenceCap = 400

    static func parse(_ text: String, horizon: Date = DateUtils.addDays(365, to: Date())) -> [ICSEvent] {
        let lines = unfold(text)
        var events: [ICSEvent] = []

        var current: [String: (value: String, params: [String: String])]?
        var inEvent = false

        for line in lines {
            let upper = line.uppercased()
            if upper.hasPrefix("BEGIN:VEVENT") {
                current = [:]
                inEvent = true
                continue
            }
            if upper.hasPrefix("END:VEVENT") {
                if let fields = current {
                    events.append(contentsOf: expand(fields, horizon: horizon))
                }
                current = nil
                inEvent = false
                continue
            }
            guard inEvent, var fields = current else { continue }
            if let parsed = parseLine(line) {
                // Un champ peut apparaître plusieurs fois (EXDATE) : on concatène.
                if let existing = fields[parsed.key] {
                    fields[parsed.key] = (existing.value + "," + parsed.value.value, parsed.value.params)
                } else {
                    fields[parsed.key] = parsed.value
                }
                current = fields
            }
        }

        return events.sorted { $0.start < $1.start }
    }

    // MARK: Dépliage des lignes

    /// RFC 5545 §3.1 : une ligne repliée commence par un espace ou une tabulation.
    private static func unfold(_ text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var result: [String] = []
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                if !result.isEmpty {
                    result[result.count - 1] += String(line.dropFirst())
                }
            } else {
                result.append(line)
            }
        }
        return result.filter { !$0.isEmpty }
    }

    /// `KEY;PARAM=VALUE:VALUE` → (clé, valeur, paramètres)
    private static func parseLine(_ line: String) -> (key: String, value: (value: String, params: [String: String]))? {
        guard let colon = firstUnquotedColon(in: line) else { return nil }
        let head = String(line[line.startIndex..<colon])
        let value = String(line[line.index(after: colon)...])
        let parts = head.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard let key = parts.first else { return nil }

        var params: [String: String] = [:]
        for part in parts.dropFirst() {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { params[kv[0].uppercased()] = kv[1] }
        }
        return (key.uppercased(), (unescape(value), params))
    }

    private static func firstUnquotedColon(in line: String) -> String.Index? {
        var inQuotes = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"" { inQuotes.toggle() }
            if character == ":" && !inQuotes { return index }
            index = line.index(after: index)
        }
        return nil
    }

    private static func unescape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    // MARK: Dates

    private static func parseDate(_ raw: String, params: [String: String]) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        let timeZone = params["TZID"].flatMap { TimeZone(identifier: $0) } ?? .current

        if value.hasSuffix("Z") {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            return formatter.date(from: value)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone

        for format in ["yyyyMMdd'T'HHmmss", "yyyyMMdd'T'HHmm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }

        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = timeZone
        return formatter.date(from: value)
    }

    /// Le type de séance est-il celui d'un **cours magistral** ?
    ///
    /// Le « Mon horaire » de l'EPFL le dit explicitement dans `CATEGORIES` :
    /// `Cours`, `Exercices`, `Labo`. C'est infiniment plus fiable que de le deviner
    /// depuis l'intitulé, où « Algèbre linéaire (classe inversée) » ne contient
    /// aucun mot-clé.
    ///
    /// Renvoie `nil` quand `CATEGORIES` ne se prononce pas — l'appelant retombe
    /// alors sur l'ancienne heuristique.
    static func isLectureCategory(_ categories: String) -> Bool? {
        let values = categories
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        if values.contains("cours") { return true }
        if values.contains("exercices") || values.contains("labo") { return false }
        return nil
    }

    // MARK: Expansion des récurrences

    /// Durée ISO 8601 d'un `DURATION` iCalendar : « PT105M », « PT1H30M », « P1D ».
    ///
    /// Fonction pure, testée : c'est le seul format de durée que produisent les
    /// horaires universitaires, et il n'a rien à voir avec une date.
    static func parseDuration(_ value: String) -> TimeInterval? {
        let raw = value.trimmingCharacters(in: .whitespaces).uppercased()
        guard raw.hasPrefix("P") else { return nil }

        var seconds: Double = 0
        var digits = ""
        for character in raw.dropFirst() {
            if character.isNumber {
                digits.append(character)
                continue
            }
            guard let amount = Double(digits) else { digits = ""; continue }
            switch character {
            case "W": seconds += amount * 7 * 86_400
            case "D": seconds += amount * 86_400
            case "H": seconds += amount * 3_600
            case "M": seconds += amount * 60
            case "S": seconds += amount
            default: break
            }
            digits = ""
        }
        return seconds > 0 ? seconds : nil
    }

    private static func expand(_ fields: [String: (value: String, params: [String: String])],
                               horizon: Date) -> [ICSEvent] {
        guard let summaryField = fields["SUMMARY"],
              let startField = fields["DTSTART"],
              let start = parseDate(startField.value, params: startField.params) else { return [] }

        // `DTEND` est une date, `DURATION` une durée ISO 8601 (« PT105M »). Le
        // « Mon horaire » de l'EPFL n'émet **que** `DURATION` : sans ce décodage,
        // chaque séance retombait sur le défaut d'une heure — 105 min devenaient 60.
        let end: Date
        if let endField = fields["DTEND"], let parsedEnd = parseDate(endField.value, params: endField.params) {
            end = parsedEnd
        } else if let durationField = fields["DURATION"],
                  let seconds = parseDuration(durationField.value) {
            end = start.addingTimeInterval(seconds)
        } else {
            end = start.addingTimeInterval(3600)
        }

        let uid = fields["UID"]?.value ?? UUID().uuidString
        let location = fields["LOCATION"]?.value ?? ""
        let notes = fields["DESCRIPTION"]?.value ?? ""
        let summary = summaryField.value
        let categories = fields["CATEGORIES"]?.value ?? ""

        guard let rrule = fields["RRULE"]?.value else {
            return [ICSEvent(uid: uid, summary: summary, start: start, end: end,
                             location: location, notes: notes, isRecurring: false,
                             categories: categories)]
        }

        let rule = parseRule(rrule)
        let excluded = Set(
            (fields["EXDATE"]?.value ?? "")
                .split(separator: ",")
                .compactMap { parseDate(String($0), params: fields["EXDATE"]?.params ?? [:]) }
        )

        let duration = end.timeIntervalSince(start)
        let timeZone = startField.params["TZID"].flatMap { TimeZone(identifier: $0) } ?? .current
        var occurrences: [ICSEvent] = []
        var generated = 0

        outer: for date in occurrenceDates(start: start, rule: rule, horizon: horizon, timeZone: timeZone) {
            guard generated < occurrenceCap else { break outer }
            guard date <= horizon else { break outer }
            generated += 1
            if excluded.contains(date) { continue }
            occurrences.append(ICSEvent(uid: uid, summary: summary, start: date,
                                        end: date.addingTimeInterval(duration),
                                        location: location, notes: notes, isRecurring: true,
                                         categories: categories))
        }
        return occurrences
    }

    private struct RecurrenceRule {
        var frequency: String = "WEEKLY"
        var interval: Int = 1
        var count: Int?
        var until: Date?
        var byDay: [Int] = []   // 1 = dimanche … 7 = samedi (convention iCalendar)
    }

    private static func parseRule(_ raw: String) -> RecurrenceRule {
        var rule = RecurrenceRule()
        for component in raw.split(separator: ";") {
            let parts = component.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].uppercased()
            let value = parts[1]
            switch key {
            case "FREQ": rule.frequency = value.uppercased()
            case "INTERVAL": rule.interval = max(1, Int(value) ?? 1)
            case "COUNT": rule.count = Int(value)
            case "UNTIL": rule.until = parseDate(value, params: [:])
            case "BYDAY":
                let map = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]
                rule.byDay = value.split(separator: ",").compactMap { token in
                    let name = String(token).suffix(2).uppercased()
                    return map[name]
                }
            default: break
            }
        }
        return rule
    }

    /// Génère les occurrences.
    ///
    /// L'expansion se fait **dans le fuseau de l'événement** : sinon un cours de
    /// 08:15 à Zurich deviendrait un autre jour pour un appareil réglé ailleurs.
    /// L'heure de DTSTART est conservée pour les règles `BYDAY`.
    private static func occurrenceDates(start: Date,
                                        rule: RecurrenceRule,
                                        horizon: Date,
                                        timeZone: TimeZone) -> [Date] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // Numérotation iCalendar : 1 = dimanche … 7 = samedi. On fixe le premier
        // jour de la semaine en conséquence, sinon `dateInterval(of: .weekOfYear:)`
        // dépend de la locale de l'appareil et décale les occurrences d'un jour.
        calendar.firstWeekday = 1

        var dates: [Date] = []
        let maxCount = rule.count ?? occurrenceCap

        switch rule.frequency {
        case "DAILY":
            var cursor = start
            while dates.count < maxCount, cursor <= horizon {
                dates.append(cursor)
                if let until = rule.until, cursor > until { break }
                guard let next = calendar.date(byAdding: .day, value: rule.interval, to: cursor) else { break }
                cursor = next
            }

        case "WEEKLY":
            if rule.byDay.isEmpty {
                var cursor = start
                while dates.count < maxCount, cursor <= horizon {
                    dates.append(cursor)
                    if let until = rule.until, cursor > until { break }
                    guard let next = calendar.date(byAdding: .day, value: 7 * rule.interval, to: cursor) else { break }
                    cursor = next
                }
            } else {
                guard let weekAnchor = calendar.dateInterval(of: .weekOfYear, for: start)?.start else {
                    return [start]
                }
                // Heure de la journée à conserver (08:15 dans « 08:15–10:00 »).
                let timeOfDay = start.timeIntervalSince(calendar.startOfDay(for: start))

                var weekOffset = 0
                while dates.count < maxCount {
                    guard let base = calendar.date(byAdding: .weekOfYear,
                                                   value: weekOffset * rule.interval,
                                                   to: weekAnchor) else { break }
                    if base > horizon { break }

                    var producedThisWeek = 0
                    for weekday in rule.byDay.sorted() {
                        let delta = weekday - 1 // Calendar : 1 = dimanche
                        guard let day = calendar.date(byAdding: .day, value: delta, to: base) else { continue }
                        let candidate = day.addingTimeInterval(timeOfDay)
                        guard candidate >= start else { continue }
                        if let until = rule.until, candidate > until { continue }
                        guard candidate <= horizon else { continue }
                        dates.append(candidate)
                        producedThisWeek += 1
                        if dates.count >= maxCount { break }
                    }

                    // Sécurité : si une semaine ne produit rien et qu'on est déjà loin, on s'arrête.
                    if producedThisWeek == 0 && weekOffset > 1 && base > horizon { break }
                    weekOffset += 1
                }
            }

        default:
            dates = [start]
        }

        return dates.sorted()
    }
}
