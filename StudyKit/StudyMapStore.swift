import Foundation
import Observation

/// Lire et écrire ce qui rend la fiche compréhensible (`Course.studyMap`) — liens, maîtrise, notes,
/// idées, schémas — et la faire écrire par Claude (sur le Mac : l'iPhone montre ce que le Mac a
/// produit, par iCloud). Ce qui est à l'étudiant·e ne se perd jamais dans une nouvelle fiche
/// (`StudyMapAI.rebased`).
@MainActor
@Observable
final class StudyMapStore {
    static let shared = StudyMapStore()

    enum State: Equatable {
        case working(String)
        case failed(String)
    }

    private(set) var states: [UUID: State] = [:]

    /// La dernière lecture de chaque carte : décoder un JSON à chaque tour d'écran coûterait.
    @ObservationIgnored private var cache: [UUID: (raw: String, map: StudyMap)] = [:]

    func state(_ course: Course) -> State? { states[course.id] }

    var canEnrich: Bool { RevisionSheetMaker.shared.writer != nil }

    // MARK: Lire, changer

    func map(_ course: Course) -> StudyMap {
        let raw = course.studyMapRaw
        if let cached = cache[course.id], cached.raw == raw { return cached.map }
        var decoded = course.studyMap
        // Une fiche sans carte : les liens qu'on déduit des citations, sans rien écrire (écrire dans
        // le modèle pendant l'affichage d'une vue le faisait tomber). Ils sont rangés dès le premier
        // vrai changement (une maîtrise, une note, Claude).
        if decoded.links.isEmpty, let sheet = course.revisionSheet { decoded.links = StudyLinks.cited(in: sheet) }
        cache[course.id] = (raw, decoded)
        return decoded
    }

    /// Change la carte d'un cours et la range (iCloud la fait suivre).
    func update(_ course: Course, _ change: (inout StudyMap) -> Void) {
        var map = self.map(course)
        change(&map)
        course.studyMap = map
        cache[course.id] = (course.studyMapRaw, map)
        try? course.modelContext?.save()
    }

    // MARK: Où j'en suis

    func setMastery(_ level: StudyMap.Mastery, for key: String, in course: Course) {
        update(course) { map in
            if level == .unknown { map.progress[key] = nil } else { map.progress[key] = .init(level: level, at: Date()) }
        }
    }

    func setNote(_ text: String, for key: String, in course: Course) {
        update(course) { map in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            map.notes[key] = trimmed.isEmpty ? nil : text
        }
    }

    // MARK: Une nouvelle fiche

    /// La fiche vient d'être refaite : ce qui est à toi reste, les liens qu'on déduit des citations
    /// sont recalculés.
    func sheetChanged(_ course: Course, sheet: RevisionSheet) {
        update(course) { map in
            map = StudyMapAI.rebased(map, onto: sheet)
            let keys = Set(sheet.keyed.map(\.key))
            map.links = StudyLinks.merged(existing: map.links,
                                          generated: StudyLinks.cited(in: sheet) + map.links.filter { !$0.userMade },
                                          keys: keys)
        }
    }

    // MARK: Claude écrit

    func enrich(_ course: Course) async {
        guard states[course.id].map({ if case .working = $0 { return false }; return true }) ?? true else { return }
        guard let writer = RevisionSheetMaker.shared.writer else {
            states[course.id] = .failed(String(localized: "Claude relie les notions sur le Mac ; ça arrive ici par iCloud."))
            return
        }
        guard let sheet = course.revisionSheet, !sheet.isEmpty else {
            states[course.id] = .failed(String(localized: "Fais d'abord la fiche du cours."))
            return
        }
        states[course.id] = .working(String(localized: "Claude relie les notions et dessine les schémas…"))
        do {
            let (prompt, ids) = StudyMapAI.prompt(course: course.name, sheet: sheet)
            let answer = try await writer(StudyMapAI.instructions, prompt)
            guard let enriched = StudyMapAI.apply(answer: answer, sheet: sheet, ids: ids, to: map(course)) else {
                throw RevisionSheetMaker.Failure(String(localized: "Claude n'a pas rendu de réponse lisible. Réessaie."))
            }
            update(course) { $0 = enriched }
            states[course.id] = nil
            AppLog.record(.info, "fiche", "Carte de la fiche écrite",
                          detail: "\(course.displayCode) : \(enriched.links.count) liens, \(enriched.diagrams.count) schémas, \(enriched.enrichment.count) notions expliquées")
        } catch {
            states[course.id] = .failed((error as? RevisionSheetMaker.Failure)?.message ?? error.localizedDescription)
            AppLog.record(.info, "fiche", "Carte de la fiche impossible", detail: "\(course.displayCode) : \(error.localizedDescription)")
        }
    }
}
