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

        // **Seulement ce que le cours demande.** Un MOOC entier n'est pas le
        // travail de la semaine : CS-107 cite quelques vidéos par semaine, et
        // ses exercices en ligne ne sont pas à faire. Une leçon est gardée si
        // Moodle la cite (ou cite son chapitre), si son chapitre porte une
        // semaine (« Semaine 3 »), ou si Moodle traite ce chapitre une semaine
        // donnée (« 04-Espaces-vectoriels » ↔ « 4. Espaces vectoriels », la
        // classe inversée où le MOOC **est** le cours).
        var videos: [CourseVideos.Video] = []
        var order = 0
        for chapter in mooc.sections {
            let title = ContentDraftBuilder.cleanTitle(chapter.title)
            guard !title.isEmpty, !chapter.items.isEmpty else { continue }
            let chapterCited = chapter.id.flatMap { blockWeeks[$0] }
            let chapterWeek = chapterCited
                ?? weekInTitle(title)
                ?? ContentDraftBuilder.leadingNumber(in: title).flatMap { Int($0.number) }.flatMap { chapterWeeks[$0] }
            for lesson in chapter.items {
                guard !lesson.url.isEmpty, !isExercise(lesson) else { continue }
                let ids = [lesson.id].compactMap { $0 } + (lesson.blockIDs ?? [])
                guard let week = ids.compactMap({ blockWeeks[$0] }).min() ?? chapterWeek, week > 0 else { continue }
                let lessonTitle = ContentDraftBuilder.cleanTitle(lesson.title)
                let videoLinks = (lesson.links ?? []).filter { $0.kind == .video }
                if videoLinks.isEmpty {
                    order += 1
                    videos.append(CourseVideos.Video(title: lessonTitle.isEmpty ? title : lessonTitle, url: lesson.url,
                                                     week: min(week, max(totalWeeks, 1)),
                                                     kind: (lesson.videoCount ?? 0) > 0 ? .video : .page, order: order))
                } else {
                    for link in videoLinks {
                        order += 1
                        let name = ContentDraftBuilder.cleanTitle(link.title)
                        videos.append(CourseVideos.Video(title: name.isEmpty || name == lessonTitle ? lessonTitle : "\(lessonTitle) — \(name)",
                                                         url: link.url, week: min(week, max(totalWeeks, 1)), order: order))
                    }
                }
            }
        }
        result = CourseVideos.merge(videos, into: result, totalWeeks: totalWeeks, sourceLabel: "MOOC").draft
        // Le MOOC lui-même reste à portée, pour le reste (facultatif).
        if !mooc.url.isEmpty {
            var item = ContentDraftItem(kind: .resource, number: "", title: "MOOC · \(mooc.title)", url: mooc.url,
                                        videoCount: 0, seriesNumber: nil, theoryKind: .reading)
            item.links = [ContentLink(title: mooc.title, url: mooc.url, kind: .page)]
            item.group = "Cours en ligne"
            if let index = result.sections.firstIndex(where: { $0.title.hasPrefix("Documents") }) {
                if !result.sections[index].items.contains(where: { $0.url == mooc.url }) { result.sections[index].items.append(item) }
            } else {
                result.sections.append(ContentDraftSection(title: "Documents du cours (non suivis)", week: 0,
                                                           weekIsInferred: false, isIncluded: true, items: [item]))
            }
        }
        return result
    }

    /// Une leçon d'exercices, de quiz ou d'évaluation du MOOC : pas à faire ici.
    static func isExercise(_ lesson: ScrapedItem) -> Bool {
        guard (lesson.videoCount ?? 0) == 0, !(lesson.links ?? []).contains(where: { $0.kind == .video }) else { return false }
        let folded = ContentDraftBuilder.fold(lesson.title)
        return folded.range(of: #"\b(exercices?|exercises?|quiz+|quizzes|problemes?|problems?|series?|evaluation|assessment|test|devoir|homework|graded)\b"#,
                            options: .regularExpression) != nil
    }

    /// « Semaine 3 — Les boucles » / « Week 3 » → 3.
    static func weekInTitle(_ title: String) -> Int? {
        let folded = ContentDraftBuilder.fold(title)
        guard let range = folded.range(of: #"\b(semaine|week|sem\.?)\s*0*(\d{1,2})\b"#, options: .regularExpression) else { return nil }
        let digits = folded[range].filter(\.isNumber)
        return Int(digits)
    }
}
