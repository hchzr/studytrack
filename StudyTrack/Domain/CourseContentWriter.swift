import Foundation
import SwiftData

/// Ce qu'un import a changé, pour le dire en une phrase.
struct ContentImportResult: Equatable {
    var theoryAdded = 0
    var theoryUpdated = 0
    var seriesAdded = 0
    var seriesUpdated = 0

    var isEmpty: Bool { theoryAdded + theoryUpdated + seriesAdded + seriesUpdated == 0 }

    var message: String {
        var parts: [String] = []
        if theoryAdded > 0 { parts.append("\(theoryAdded) élément\(theoryAdded > 1 ? "s" : "") de théorie") }
        if seriesAdded > 0 { parts.append("\(seriesAdded) série\(seriesAdded > 1 ? "s" : "")") }
        let updated = theoryUpdated + seriesUpdated
        if parts.isEmpty {
            return updated > 0 ? "Déjà à jour · \(updated) élément\(updated > 1 ? "s" : "") rafraîchi\(updated > 1 ? "s" : "")." : "Rien de nouveau."
        }
        return "Ajouté : " + parts.joined(separator: " et ") + (updated > 0 ? " · \(updated) mis à jour." : ".")
    }
}

/// Écrit un brouillon relu dans un cours.
///
/// **Ne supprime jamais rien** : réimporter Moodle en semaine 8 doit ajouter la
/// série 8, pas effacer l'avancement des sept premières. Un élément déjà présent
/// — même adresse, ou même numéro — est mis à jour (titre, semaine, vidéos) et
/// garde ce qui a été coché.
enum ContentDraftWriter {

    @discardableResult
    static func apply(_ draft: ContentDraft, to course: Course, context: ModelContext) -> ContentImportResult {
        var result = ContentImportResult()
        var nextSort = (course.theoryItems.map(\.sortOrder).max() ?? -1) + 1

        for (sectionIndex, section) in draft.sections.enumerated() where section.isIncluded {
            let chapter = ContentDraftBuilder.leadingNumber(in: section.title).flatMap { Int($0.number) }
            for item in section.items {
                switch item.kind {
                case .ignore:
                    continue
                case .theory:
                    let existing = course.theoryItems.first { existing in
                        (!item.url.isEmpty && existing.urlString == item.url) || existing.number == item.number
                    }
                    let sectionNumber = Int(item.number.split(separator: ".").first ?? "") ?? chapter ?? (sectionIndex + 1)
                    if let existing {
                        existing.title = item.title
                        existing.plannedWeek = section.week
                        existing.videoCount = item.videoCount
                        existing.sectionTitle = section.title
                        existing.kind = item.theoryKind
                        if existing.urlString.isEmpty { existing.urlString = item.url }
                        existing.sourceRaw = draft.source.rawValue
                        result.theoryUpdated += 1
                    } else {
                        let theory = TheoryItem(course: course,
                                                sectionNumber: sectionNumber,
                                                number: item.number,
                                                title: item.title,
                                                kind: item.theoryKind,
                                                plannedWeek: section.week,
                                                sortOrder: nextSort,
                                                urlString: item.url)
                        theory.videoCount = item.videoCount
                        theory.sectionTitle = section.title
                        theory.sourceRaw = draft.source.rawValue
                        context.insert(theory)
                        nextSort += 1
                        result.theoryAdded += 1
                    }
                case .series:
                    guard let number = item.seriesNumber ?? Int(item.number) else { continue }
                    if let existing = course.series.first(where: { $0.seriesNumber == number }) {
                        existing.plannedWeek = section.week
                        if existing.urlString.isEmpty { existing.urlString = item.url }
                        result.seriesUpdated += 1
                    } else {
                        let series = ExerciseSeries(course: course,
                                                    seriesNumber: number,
                                                    plannedWeek: section.week,
                                                    urlString: item.url)
                        context.insert(series)
                        result.seriesAdded += 1
                    }
                }
            }
        }

        var sources = course.contentSources
        if !draft.url.isEmpty, !sources.contains(draft.url) {
            sources.append(draft.url)
            course.contentSources = sources
        }
        return result
    }
}
