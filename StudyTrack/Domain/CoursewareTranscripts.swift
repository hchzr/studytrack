import Foundation

/// Les transcriptions des vidéos Courseware : ce que dit chaque vidéo, phrase
/// par phrase, avec son instant. « Où a-t-il défini la convergence absolue ? »
/// ouvre la vidéo à cette minute. Pur, testé dans `validate.sh`.
enum CoursewareTranscripts {

    struct Cue: Codable, Equatable {
        var start: Double
        var text: String
    }

    /// Une vidéo et ce qu'elle dit.
    struct Video: Codable, Equatable {
        var block: String
        var unit: String
        var title: String
        var cues: [Cue]
    }

    struct Hit: Equatable, Identifiable {
        var block: String
        var unit: String
        var title: String
        var start: Double
        /// La phrase trouvée, avec un peu de ce qui l'entoure.
        var snippet: String
        var id: String { block + "@" + String(Int(start)) }
    }

    // MARK: Lire

    /// SRT (`1\n00:01:02,500 --> …\ntexte`) ou le JSON d'edX
    /// (`{"start":[ms…],"end":[…],"text":[…]}`).
    static func cues(from raw: String) -> [Cue] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any],
           let starts = object["start"] as? [Double], let texts = object["text"] as? [String] {
            return zip(starts, texts).compactMap { start, text in
                let clean = tidy(text)
                return clean.isEmpty ? nil : Cue(start: start / 1000, text: clean)
            }
        }
        var result: [Cue] = []
        let blocks = trimmed.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }),
                  let start = seconds(lines[timing].components(separatedBy: "-->")[0]) else { continue }
            let text = tidy(lines[(timing + 1)...].joined(separator: " "))
            if !text.isEmpty { result.append(Cue(start: start, text: text)) }
        }
        return result
    }

    /// `00:01:02,500` → 62.5.
    static func seconds(_ stamp: String) -> Double? {
        let parts = stamp.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    private static func tidy(_ text: String) -> String {
        text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Les adresses des transcriptions d'un bloc vidéo (`student_view_data`),
    /// la langue préférée d'abord (fr, puis en, puis le reste).
    static func transcriptURLs(_ data: [String: Any], preferred: [String] = ["fr", "en"]) -> [String] {
        let transcripts = data["transcripts"] as? [String: String] ?? [:]
        let ordered = preferred.compactMap { transcripts[$0] } + transcripts.filter { !preferred.contains($0.key) }.sorted { $0.key < $1.key }.map(\.value)
        return ordered.filter { !$0.isEmpty }
    }

    // MARK: Chercher

    /// Les passages qui contiennent tous les mots cherchés (sans accents ni
    /// casse), lus sur trois phrases de suite pour ne pas manquer une idée
    /// coupée en deux. Un passage par vidéo et par minute, au plus.
    static func search(_ query: String, in videos: [Video], limit: Int = 40) -> [Hit] {
        let words = fold(query).split(separator: " ").map(String.init).filter { $0.count >= 2 }
        guard !words.isEmpty else { return [] }
        var hits: [Hit] = []
        for video in videos {
            var lastMinute = -1
            for index in video.cues.indices {
                let window = video.cues[index..<min(index + 3, video.cues.count)]
                let text = window.map(\.text).joined(separator: " ")
                let folded = fold(text)
                guard words.allSatisfy(folded.contains) else { continue }
                // La phrase qui porte le premier mot, plutôt que le début de la fenêtre.
                let anchor = window.first { fold($0.text).contains(words[0]) } ?? video.cues[index]
                let minute = Int(anchor.start / 60)
                guard minute != lastMinute else { continue }
                lastMinute = minute
                hits.append(Hit(block: video.block, unit: video.unit, title: video.title, start: anchor.start,
                                snippet: String(text.prefix(220))))
                if hits.count >= limit { return hits }
            }
        }
        return hits
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr"))
    }
}
