import Foundation

/// Range le MOOC d'un cours dans les semaines de son Moodle.
///
/// Plusieurs cours EPFL renvoient, depuis Moodle, à un MOOC sur Courseware :
/// l'algèbre linéaire en classe inversée (les vidéos **sont** le cours), CS-107
/// (« Matériel MOOC de la semaine »). Importer Moodle seul laissait ce travail
/// hors de l'app ; importer le MOOC seul le posait sans semaines. Ici, chaque
/// leçon du MOOC reçoit la semaine où Moodle la cite :
///   1. un lien Moodle qui pointe **dans** la leçon (ou son chapitre) : la
///      semaine de la section Moodle où il apparaît ;
///   2. sinon, « Semaine 3 » / « Week 3 » dans le titre du chapitre ;
///   3. sinon, le numéro du chapitre (« 4. Espaces vectoriels ») : la semaine
///      où Moodle traite ce chapitre (« 04-Espaces-vectoriels ») ;
///   4. sinon, sans semaine : à placer à la relecture.
enum MoocMerger {

    static func merge(mooc: ScrapedCourse,
                      references: [MoocReference],
                      snapshot: MoodleCourseSnapshot,
                      into draft: ContentDraft,
                      termStart: Date?,
                      totalWeeks: Int = 14,
                      calendar: Calendar = .current) -> ContentDraft {
        var result = draft
        let sectionWeeks = Dictionary(snapshot.sections.compactMap { section -> (Int, Int)? in
            guard let week = MoodleCourseAnalyzer.week(of: section, termStart: termStart,
                                                       totalWeeks: totalWeeks, calendar: calendar) else { return nil }
            return (section.number, week)
        }, uniquingKeysWith: { first, _ in first })

        // La semaine de chaque bloc cité depuis Moodle.
        var blockWeeks: [String: Int] = [:]
        for reference in references {
            guard let block = reference.blockID, let number = reference.sectionNumber,
                  let week = sectionWeeks[number] else { continue }
            blockWeeks[block] = min(blockWeeks[block] ?? week, week)
        }

        // La semaine où Moodle traite chaque chapitre (« 4 · Espaces vectoriels »).
        var chapterWeeks: [Int: Int] = [:]
        for section in draft.sections where section.week > 0 {
            for item in section.items where item.kind == .theory {
                guard let chapter = Int(item.number.split(separator: ".").first ?? "") else { continue }
                let week = item.week ?? section.week
                chapterWeeks[chapter] = min(chapterWeeks[chapter] ?? week, week)
            }
        }

        let known = Set(draft.sections.flatMap(\.items).map(\.url).filter { !$0.isEmpty })
        var added: [ContentDraftSection] = []
        for (chapterIndex, chapter) in mooc.sections.enumerated() {
            let title = ContentDraftBuilder.cleanTitle(chapter.title)
            guard !title.isEmpty, !chapter.items.isEmpty else { continue }
            let chapterWeek = chapter.id.flatMap { blockWeeks[$0] }
                ?? weekInTitle(title)
                ?? ContentDraftBuilder.leadingNumber(in: title).flatMap { Int($0.number) }.flatMap { chapterWeeks[$0] }

            var byWeek: [(week: Int, items: [ContentDraftItem])] = []
            for (index, lesson) in chapter.items.enumerated() {
                guard !lesson.url.isEmpty, !known.contains(lesson.url) else { continue }
                let lessonTitle = ContentDraftBuilder.cleanTitle(lesson.title)
                let ids = [lesson.id].compactMap { $0 } + (lesson.blockIDs ?? [])
                let week = ids.compactMap { blockWeeks[$0] }.min() ?? chapterWeek ?? 0
                let videos = lesson.videoCount ?? (lesson.links ?? []).filter { $0.kind == .video }.count
                var item = ContentDraftItem(kind: .theory,
                                            number: "M\(chapterIndex + 1).\(index + 1)",
                                            title: lessonTitle.isEmpty ? title : lessonTitle,
                                            url: lesson.url,
                                            videoCount: videos,
                                            seriesNumber: nil,
                                            theoryKind: videos > 0 ? .video : .reading,
                                            week: week > 0 ? min(week, max(totalWeeks, 1)) : nil)
                item.links = (lesson.links ?? []).map { link in
                    ContentLink(title: link.title.isEmpty ? item.title : ContentDraftBuilder.cleanTitle(link.title),
                                url: link.url, kind: link.kind)
                }
                if let slot = byWeek.firstIndex(where: { $0.week == week }) {
                    byWeek[slot].items.append(item)
                } else {
                    byWeek.append((week, [item]))
                }
            }
            for group in byWeek {
                added.append(ContentDraftSection(title: "MOOC · \(title)",
                                                 week: group.week,
                                                 weekIsInferred: group.week == 0,
                                                 isIncluded: true,
                                                 items: group.items))
            }
        }
        result.sections.append(contentsOf: added.sorted { lhs, rhs in
            (lhs.week == 0 ? Int.max : lhs.week) < (rhs.week == 0 ? Int.max : rhs.week)
        })
        return result
    }

    /// « Semaine 3 — Les boucles » / « Week 3 » → 3.
    static func weekInTitle(_ title: String) -> Int? {
        let folded = ContentDraftBuilder.fold(title)
        guard let range = folded.range(of: #"\b(semaine|week|sem\.?)\s*0*(\d{1,2})\b"#, options: .regularExpression) else { return nil }
        let digits = folded[range].filter(\.isNumber)
        return Int(digits)
    }
}
