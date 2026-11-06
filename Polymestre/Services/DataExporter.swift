import Foundation
import SwiftData

/// Sauvegarde JSON de toutes les données locales.
///
/// Le fichier produit est **réimportable** : c'est exactement la structure que
/// `CourseImporter.importJSON` accepte, avec en plus l'avancement (dates de
/// visionnage, sureté, corrections…) et les sessions de travail. L'export précédent
/// avait son propre format, que rien ne savait relire : une sauvegarde qu'on ne
/// peut pas restaurer n'en est pas une.
enum DataExporter {

    static func makePayload(courses: [Course], sessions: [StudySession]) -> CourseImportPayload {
        let iso = DateUtils.iso8601
        let term = courses.compactMap(\.term).first
        let termSpec = term.map {
            TermSpec(year: $0.year,
                     season: $0.seasonRaw,
                     startDate: iso.string(from: $0.startDate),
                     endDate: iso.string(from: $0.endDate),
                     totalWeeks: $0.totalWeeks,
                     name: $0.name)
        }

        let courseSpecs = courses.map { course in
            CourseSpec(
                code: course.code,
                name: course.name,
                shortName: course.shortName,
                credits: course.credits,
                weeklySelfStudyHours: course.weeklySelfStudyHours,
                isTracked: course.isTracked,
                weeklyLectureHours: course.weeklyLectureHours,
                weeklyExerciseHours: course.weeklyExerciseHours,
                hasLectures: course.hasLectures,
                sectionCode: course.sectionCode,
                colorHex: course.colorHex,
                lecturer: course.lecturer,
                moodleURL: course.moodleURLString,
                videos: course.sortedTheoryItems.map {
                    VideoSpec(section: $0.sectionNumber,
                              number: $0.number,
                              title: $0.title,
                              kind: $0.kindRaw,
                              durationSeconds: $0.durationSeconds,
                              week: $0.plannedWeek,
                              url: $0.urlString.isEmpty ? nil : $0.urlString,
                              watchedAt: $0.watchedAt.map(iso.string(from:)),
                              summarizedAt: $0.summarizedAt.map(iso.string(from:)),
                              summaryText: $0.summaryText)
                },
                series: course.sortedSeries.map { series in
                    SeriesSpec(number: series.seriesNumber,
                               title: series.title,
                               week: series.plannedWeek,
                               url: series.urlString.isEmpty ? nil : series.urlString,
                               exercises: series.sortedExercises.map {
                                   ExerciseSpec(number: $0.exerciseNumber,
                                                title: $0.title,
                                                isBonus: $0.isBonus,
                                                doneAt: $0.doneAt.map(iso.string(from:)),
                                                confidence: $0.confidenceRaw,
                                                correctedAt: $0.correctedAt.map(iso.string(from:)),
                                                correctness: $0.correctnessRaw,
                                                redoRequired: $0.redoRequired,
                                                correctionNote: $0.correctionNote,
                                                score: $0.score,
                                                maxScore: $0.maxScore)
                               })
                },
                exams: course.sortedExams.map {
                    ExamSpec(kind: $0.kindRaw,
                             title: $0.title,
                             date: iso.string(from: $0.date),
                             weightPercent: $0.weightPercent,
                             location: $0.location.isEmpty ? nil : $0.location)
                })
        }

        let sessionSpecs = sessions.map {
            SessionSpec(courseCode: $0.course?.code,
                        taskType: $0.taskTypeRaw,
                        startedAt: iso.string(from: $0.startedAt),
                        durationSeconds: $0.durationSeconds,
                        isManual: $0.isManual,
                        note: $0.note.isEmpty ? nil : $0.note,
                        exerciseNumber: $0.exercise?.exerciseNumber,
                        theoryNumber: $0.theoryItem?.number)
        }

        return CourseImportPayload(term: termSpec, courses: courseSpecs, sessions: sessionSpecs)
    }

    static func makeJSON(courses: [Course], sessions: [StudySession]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(makePayload(courses: courses, sessions: sessions))
    }

    /// Écrit la sauvegarde dans un fichier temporaire daté et renvoie son URL.
    static func writeFile(courses: [Course], sessions: [StudySession]) -> URL? {
        guard let data = makeJSON(courses: courses, sessions: sessions) else { return nil }
        let stamp = DateUtils.dateOnly.string(from: Date())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("polymestre-\(stamp).json")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    // MARK: CSV des sessions

    /// Les sessions en CSV, pour un tableur : une ligne par session.
    static func sessionsCSV(_ sessions: [StudySession]) -> String {
        var lines = ["date,heure,cours,type,cible,minutes,note"]
        for session in sessions.sorted(by: { $0.startedAt < $1.startedAt }) {
            let fields = [
                DateUtils.dateOnly.string(from: session.startedAt),
                DateUtils.time.string(from: session.startedAt),
                session.course?.code ?? "",
                session.taskType.label,
                session.targetLabel ?? "",
                "\(session.durationMinutes)",
                session.note
            ]
            lines.append(fields.map(csvEscape).joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    static func writeSessionsCSV(_ sessions: [StudySession]) -> URL? {
        let stamp = DateUtils.dateOnly.string(from: Date())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("polymestre-sessions-\(stamp).csv")
        do {
            try sessionsCSV(sessions).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private static func csvEscape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
