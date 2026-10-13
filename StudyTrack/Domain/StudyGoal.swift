import Foundation
import SwiftData

/// L'objectif d'étude : **un seul**, de la semaine, sur tous les appareils.
///
/// Réglé à la main (Réglages, iPhone ou Mac), ou, à défaut, la charge EPFL des
/// cours suivis pour la semaine (heures cadrées + travail personnel,
/// `WorkloadEngine`). Le jour en vise le septième : le Mac avait son objectif
/// du jour, l'iPhone une charge de la semaine, et rien ne les reliait.
enum StudyGoal {
    static func weeklySeconds(goalMinutes: Int, courses: [Course], hoursPerCredit: Double, now: Date = Date()) -> Int {
        if goalMinutes > 0 { return goalMinutes * 60 }
        let start = DateUtils.startOfWeek(now)
        return WorkloadEngine.aggregateWeekly(courses: courses.filter(\.isTracked), hoursPerCredit: hoursPerCredit,
                                              from: start, to: DateUtils.addDays(7, to: start)).expectedSeconds
    }

    static func dailySeconds(weekly: Int) -> Int {
        max(15 * 60, weekly / 7)
    }

    static func weeklySeconds(in context: ModelContext, goalMinutes: Int, hoursPerCredit: Double) -> Int {
        let courses = (try? context.fetch(FetchDescriptor<Course>())) ?? []
        return weeklySeconds(goalMinutes: goalMinutes, courses: courses, hoursPerCredit: hoursPerCredit)
    }
}
