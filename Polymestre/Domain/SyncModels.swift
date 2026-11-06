import Foundation
import SwiftData

// Les `@Model` synchronisés, et de quoi en fabriquer un vide : la synchronisation
// crée l'objet puis écrase tous ses champs avec ceux du serveur, donc les valeurs
// d'initialisation n'ont aucune importance. Les modèles absents (groupes, balise
// du relais) sont exclus par `excludedModels` de schema.ts.

extension AcademicTerm: SyncModel { static func syncBlank() -> AcademicTerm { AcademicTerm(year: 0, season: .autumn, startDate: Date(), endDate: Date()) } }
extension Course: SyncModel { static func syncBlank() -> Course { Course(code: "", name: "") } }
extension TheoryItem: SyncModel { static func syncBlank() -> TheoryItem { TheoryItem(sectionNumber: 0, number: "") } }
extension ExerciseSeries: SyncModel { static func syncBlank() -> ExerciseSeries { ExerciseSeries(seriesNumber: 0) } }
extension Exercise: SyncModel { static func syncBlank() -> Exercise { Exercise(exerciseNumber: "") } }
extension SubQuestion: SyncModel { static func syncBlank() -> SubQuestion { SubQuestion(label: "") } }
extension StudySession: SyncModel { static func syncBlank() -> StudySession { StudySession() } }
extension Exam: SyncModel { static func syncBlank() -> Exam { Exam() } }
extension PlannedSession: SyncModel { static func syncBlank() -> PlannedSession { PlannedSession() } }
extension LinkedTask: SyncModel { static func syncBlank() -> LinkedTask { LinkedTask(title: "") } }
extension LinkedCalendarEvent: SyncModel { static func syncBlank() -> LinkedCalendarEvent { LinkedCalendarEvent(title: "", startsAt: Date(), endsAt: Date()) } }
extension AcademicMilestone: SyncModel { static func syncBlank() -> AcademicMilestone { AcademicMilestone(externalID: "", title: "", date: Date(), kind: .teachingStart) } }
extension PastExam: SyncModel { static func syncBlank() -> PastExam { PastExam() } }
extension Mistake: SyncModel { static func syncBlank() -> Mistake { Mistake(exercise: nil, kind: .method, summary: "") } }
extension SavedResource: SyncModel { static func syncBlank() -> SavedResource { SavedResource(course: nil, title: "", kind: .web) } }
