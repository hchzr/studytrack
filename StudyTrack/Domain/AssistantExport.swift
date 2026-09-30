import Foundation

/// Produit un instantané de l'état d'étude, lisible par un **assistant**.
///
/// C'est la source du serveur MCP (`mcp/`). Le format est volontairement plat et
/// documenté : un assistant doit pouvoir le lire sans rien connaître de SwiftData,
/// et sans qu'on ait à maintenir un schéma binaire.
///
/// Ce que l'export contient — et ce qu'il ne contient **pas** est un choix : les
/// notes de correction et les résumés y sont (ils servent à réviser), mais aucune
/// donnée de compte, aucun jeton, aucune adhésion de groupe. Un fichier qu'on
/// partage ne doit pas transporter d'identités.
enum AssistantExport {

    static let fileName = "studytrack-assistant.json"
    /// v2 : identifiants partout (cours, séries, exercices, questions,
    /// théorie, sessions) et étape de chaque exercice — un assistant qui
    /// **agit** doit désigner exactement ce qu'il modifie.
    static let formatVersion = 2

    /// Construit l'instantané.
    static func make(courses: [Course],
                     sessions: [StudySession],
                     milestones: [AcademicMilestone],
                     groups: [StudyGroup],
                     hoursPerCredit: Double,
                     displayName: String) -> [String: Any] {
        let tracked = courses.filter(\.isTracked)

        var payload: [String: Any] = [
            "format": "studytrack.assistant",
            "version": formatVersion,
            "generatedAt": ISO8601DateFormatter().string(from: Date())
        ]

        payload["settings"] = [
            "hoursPerCredit": hoursPerCredit,
            "displayName": displayName
        ]

        payload["courses"] = tracked.map { course in
            coursePayload(course)
        }

        payload["sessions"] = sessions.prefix(2000).map { session in
            var entry: [String: Any] = [
                "id": session.id.uuidString,
                "taskType": session.taskTypeRaw,
                "startedAt": ISO8601DateFormatter().string(from: session.startedAt),
                "durationSeconds": session.durationSeconds,
                "manual": session.isManual
            ]
            if let course = session.course { entry["course"] = course.displayCode }
            if let target = session.targetLabel { entry["target"] = target }
            if let exercise = session.exercise { entry["exerciseId"] = exercise.id.uuidString }
            if let item = session.theoryItem { entry["theoryId"] = item.id.uuidString }
            if !session.sourceRaw.isEmpty { entry["source"] = session.sourceRaw }
            if !session.note.isEmpty { entry["note"] = session.note }
            return entry
        }

        payload["calendar"] = milestones.map { milestone in
            [
                "title": milestone.title,
                "date": ISO8601DateFormatter().string(from: milestone.date),
                "kind": milestone.kindRaw,
                "approximate": milestone.isApproximate,
                "term": milestone.termLabel
            ]
        }

        payload["groups"] = groups.map { group in
            [
                "name": group.name,
                "subjects": group.subjectCodes,
                "members": group.members.count
            ]
        }

        return payload
    }

    /// L'instantané sérialisé, prêt à être partagé.
    static func data(courses: [Course],
                     sessions: [StudySession],
                     milestones: [AcademicMilestone],
                     groups: [StudyGroup],
                     hoursPerCredit: Double,
                     displayName: String) -> Data? {
        let payload = make(courses: courses,
                           sessions: sessions,
                           milestones: milestones,
                           groups: groups,
                           hoursPerCredit: hoursPerCredit,
                           displayName: displayName)
        return try? JSONSerialization.data(withJSONObject: payload,
                                           options: [.prettyPrinted, .sortedKeys])
    }

    private static func coursePayload(_ course: Course) -> [String: Any] {
        var payload: [String: Any] = [
            "id": course.id.uuidString,
            "code": course.displayCode,
            "officialCode": course.code,
            "name": course.name,
            "credits": course.credits,
            "hasLectures": course.hasLectures,
            "weeklyLectureHours": course.weeklyLectureHours,
            "weeklyExerciseHours": course.weeklyExerciseHours,
            "currentWeek": course.currentWeek
        ]
        if let term = course.term {
            payload["term"] = term.displayName
            payload["termWeeks"] = term.totalWeeks
        }
        if !course.lecturer.isEmpty { payload["lecturer"] = course.lecturer }

        payload["series"] = course.sortedSeries.map { series in
            [
                "id": series.id.uuidString,
                "number": series.seriesNumber,
                "title": series.title,
                "plannedWeek": series.plannedWeek,
                "complete": series.isComplete,
                "exercises": series.sortedExercises.map { exercise in
                    var entry: [String: Any] = [
                        "id": exercise.id.uuidString,
                        "number": exercise.exerciseNumber,
                        "title": exercise.title,
                        "stage": ExerciseStage(exercise).label,
                        "bonus": exercise.isBonus,
                        "done": exercise.isDone,
                        "corrected": exercise.isCorrected,
                        "redo": exercise.redoRequired
                    ]
                    if let correctness = exercise.correctness { entry["correctness"] = correctness.rawValue }
                    if let note = exercise.correctionNote, !note.isEmpty { entry["correctionNote"] = note }
                    if !exercise.statement.isEmpty { entry["statement"] = exercise.statement }
                    if exercise.hasSubQuestions {
                        entry["questions"] = exercise.leafSubQuestions.map { question in
                            [
                                "path": question.path,
                                "label": question.parent.map { "\($0.displayLabel) \(question.displayLabel)" } ?? question.displayLabel,
                                "text": question.text,
                                "done": question.isDone
                            ] as [String: Any]
                        }
                    }
                    return entry
                }
            ]
        }

        payload["theory"] = course.sortedTheoryItems.map { item in
            var entry: [String: Any] = [
                "id": item.id.uuidString,
                "number": item.number,
                "title": item.title,
                "kind": item.kindRaw,
                "watched": item.isWatched,
                "summarized": item.isSummarized,
                "plannedWeek": item.plannedWeek
            ]
            if item.durationSeconds > 0 { entry["durationSeconds"] = item.durationSeconds }
            if let summary = item.summaryText, !summary.isEmpty { entry["summary"] = summary }
            return entry
        }

        payload["exams"] = course.sortedExams.map { exam in
            var entry: [String: Any] = [
                "id": exam.id.uuidString,
                "title": exam.title,
                "kind": exam.kindRaw,
                "date": ISO8601DateFormatter().string(from: exam.date),
                "past": exam.isPast
            ]
            if let weight = exam.weightPercent { entry["weightPercent"] = weight }
            if !exam.location.isEmpty { entry["location"] = exam.location }
            return entry
        }

        return payload
    }
}
