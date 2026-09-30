import Foundation

/// Lit et écrit une durée courte, telle qu'on la tape.
///
/// Un champ éditable doit accepter ce que les gens écrivent vraiment : « 90 »,
/// « 1:30 », « 1h30 », « 1 h 30 », « 45m ». Refuser tout sauf un format imposé
/// rendrait le champ plus pénible que les boutons qu'il remplace.
///
/// Fonction **pure** : elle se teste sur des chaînes, y compris celles qui ne
/// doivent **pas** passer.
enum TimerText {

    /// Borne haute : douze heures. Au-delà, ce n'est plus une session d'étude.
    static let maximumHours = 12

    /// « 07:42 », « 1:02:09 » — l'affichage d'un chrono.
    ///
    /// Tronqué à la seconde : un compte à rebours passe `rounded(.up)` pour
    /// afficher « 25:00 » au départ et « 00:01 » à la dernière seconde, pas
    /// « 24:59 » puis « 00:00 » une seconde trop tôt.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }

    /// « 12:07 », « 1h05 » : un chrono qui tient dans un petit rond.
    static func compact(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total >= 3600 {
            return String(format: "%dh%02d", total / 3600, (total % 3600) / 60)
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// « 1:30 », « 90 », « 1h30 », « 45m », « 1,5h » → secondes.
    ///
    /// `nil` quand rien n'est lisible — l'appelant garde alors la valeur en place
    /// plutôt que de mettre zéro.
    static func seconds(from raw: String) -> TimeInterval? {
        var text = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "\u{00A0}", with: "")

        // La virgule décimale, en français.
        text = text.replacingOccurrences(of: ",", with: ".")
        // Les séparateurs « h » et « : » sont interchangeables.
        text = text.replacingOccurrences(of: "heures", with: "h")
        text = text.replacingOccurrences(of: "heure", with: "h")
        text = text.replacingOccurrences(of: "minutes", with: "m")
        text = text.replacingOccurrences(of: "minute", with: "m")
        text = text.replacingOccurrences(of: "min", with: "m")
        text = text.replacingOccurrences(of: " ", with: "")

        guard !text.isEmpty else { return nil }

        // « 1h30 » ou « 1.5h » ou « 1h ».
        if text.contains("h") {
            let parts = text.split(separator: "h", maxSplits: 1, omittingEmptySubsequences: false)
            let hours = parts.first.flatMap { Double($0) } ?? 0
            let minutes = parts.count > 1 ? minutesValue(String(parts[1])) : 0
            guard hours.isFinite, let minutes else { return nil }
            return clamp(hours * 3600 + minutes * 60)
        }

        // « 1:30 » — et c'est **heures:minutes**.
        //
        // Un champ de temps d'étude n'est pas un chronomètre : taper « 1:30 »
        // veut dire une heure et demie, jamais une minute et demie. Le format
        // affiché est le même, pour qu'écrire et relire se répondent.
        // Trois segments — « 1:30:15 » — restent des heures, minutes, secondes.
        if text.contains(":") {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count >= 2, parts.count <= 3 else { return nil }
            // « :30 » se lit comme « 0:30 » : on ne refuse pas une saisie dont le
            // sens est évident.
            let parsed = parts.map { Double($0.isEmpty ? "0" : String($0)) }
            guard parsed.allSatisfy({ $0 != nil }) else { return nil }
            let values = parsed.compactMap { $0 }
            if values.count == 3 {
                return clamp(values[0] * 3600 + values[1] * 60 + values[2])
            }
            return clamp(values[0] * 3600 + values[1] * 60)
        }

        // « 45m », « 30s », ou un nombre nu — qui veut dire des **minutes** :
        // taper « 90 » pour quatre-vingt-dix minutes est le geste naturel.
        if text.hasSuffix("m") {
            guard let minutes = Double(text.dropLast()) else { return nil }
            return clamp(minutes * 60)
        }
        if text.hasSuffix("s") {
            guard let value = Double(text.dropLast()) else { return nil }
            return clamp(value)
        }
        guard let minutes = Double(text) else { return nil }
        return clamp(minutes * 60)
    }

    /// « 1:30 » pour une heure et demie, « 0:45 » pour quarante-cinq minutes.
    ///
    /// Le format du champ, et celui que `seconds(from:)` relit : écrire et relire
    /// se répondent. Les secondes sont arrondies — on ajuste un temps d'étude à la
    /// minute, pas au dixième.
    static func text(from seconds: TimeInterval) -> String {
        let total = max(0, Int((seconds / 60).rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// « 1 h 30 », pour l'affichage long.
    static func longText(from seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours == 0 { return "\(total / 60) min" }
        return minutes == 0 ? "\(hours) h" : "\(hours) h \(String(format: "%02d", minutes))"
    }

    /// Les minutes d'un fragment : « 30 », « 30m », « 30.5 ».
    private static func minutesValue(_ raw: String) -> Double? {
        var text = raw
        if text.hasSuffix("m") { text.removeLast() }
        if text.hasPrefix(".") { text = "0" + text }
        guard !text.isEmpty else { return 0 }
        return Double(text)
    }

    private static func clamp(_ seconds: Double) -> TimeInterval {
        guard seconds.isFinite, seconds >= 0 else { return 0 }
        return min(seconds, Double(maximumHours) * 3600)
    }
}
