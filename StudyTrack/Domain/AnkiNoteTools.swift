import Foundation

/// Petits outils des notes Anki, purs : numéros des trous, identifiant global.
enum AnkiNoteTools {
    static func clozeNumbers(in text: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #"\{\{c(\d+)::"#) else { return [] }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let numbers = matches.compactMap { match in
            Range(match.range(at: 1), in: text).flatMap { Int(text[$0]) }
        }
        return Array(Set(numbers)).filter { $0 > 0 }.sorted()
    }

    /// Un identifiant global de note, comme Anki (base 91, dix caractères).
    static func guid() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&()*+,-./:;<=>?@[]^_`{|}~")
        var value = UInt64.random(in: 1...UInt64.max)
        var result = ""
        while value > 0 {
            result.append(alphabet[Int(value % UInt64(alphabet.count))])
            value /= UInt64(alphabet.count)
        }
        return result
    }
}
