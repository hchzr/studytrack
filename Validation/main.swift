import Foundation
import SwiftData
import PDFKit

// Stub minimal : remplace App/SettingsStore.swift pour la validation hors app iOS.
final class SettingsStore {
    var hasSeededSampleData = false
}

var failures = 0

func check(_ condition: Bool, _ label: String) {
    if condition {
        print("  ✅ \(label)")
    } else {
        print("  ❌ \(label)")
        failures += 1
    }
}

func pct(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
}

// Le conteneur de test utilise le schéma **de l'app**, pas une copie :
// c'est ce qui garantit que le test porte sur la vraie définition.
let schema = StudyTrackSchema.current

print("== Conteneur SwiftData (en mémoire) ==")
let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
let container = try ModelContainer(for: schema, configurations: [configuration])
let context = ModelContext(container)
check(schema.entities.count == declaredModelNames.count,
      "schéma : \(schema.entities.count) entités pour \(declaredModelNames.count) modèles déclarés")

print("== Données d'exemple ==")
let term = SeedData.seed(context)
let courses = try context.fetch(FetchDescriptor<Course>())
let videos = try context.fetch(FetchDescriptor<TheoryItem>())
let series = try context.fetch(FetchDescriptor<ExerciseSeries>())
let exercises = try context.fetch(FetchDescriptor<Exercise>())
let sessions = try context.fetch(FetchDescriptor<StudySession>())
let exams = try context.fetch(FetchDescriptor<Exam>())

check(courses.count == 4, "4 cours (\(courses.count))")
check(!term.displayName.isEmpty, "semestre « \(term.displayName) »")
check(videos.count == 17, "vidéos (\(videos.count))")
check(series.count == 10, "séries (\(series.count))")
check(exercises.count == 23, "exercices (\(exercises.count))")
check(sessions.count == 17, "sessions (\(sessions.count))")
check(exams.count == 5, "évaluations (\(exams.count))")

print("== Relations inverses SwiftData ==")
for course in courses.sorted(by: { $0.code < $1.code }) {
    check(!course.theoryItems.isEmpty, "\(course.code) : videos peuplé (\(course.theoryItems.count))")
    check(course.theoryItems.allSatisfy { $0.course?.code == course.code },
          "\(course.code) : inverse vidéo→cours cohérent")
    check(!course.series.isEmpty, "\(course.code) : series peuplé (\(course.series.count))")
    check(course.series.allSatisfy { !$0.exercises.isEmpty },
          "\(course.code) : chaque série a des exercices")
    check(course.series.allSatisfy { s in s.exercises.allSatisfy { $0.series?.id == s.id } },
          "\(course.code) : inverse exercice→série cohérent")
}

print("== ProgressEngine ==")
for course in courses.sorted(by: { $0.code < $1.code }) {
    let p = ProgressEngine.progress(for: course)
    print("  \(course.code) : théorie \(pct(p.theoryPercent)) [\(p.watchedCount)/\(p.videoCount)] · exos \(pct(p.exercisePercent)) [\(p.doneCount)/\(p.exerciseCount)] · corr \(pct(p.correctionPercent)) [\(p.correctedCount)/\(p.doneCount)] · bonus \(p.bonusDoneCount)/\(p.bonusCount)")
    check((0...1).contains(p.theoryPercent), "\(course.code) théorie ∈ [0,1]")
    check((0...1).contains(p.exercisePercent), "\(course.code) exos ∈ [0,1]")
    check((0...1).contains(p.correctionPercent), "\(course.code) corrections ∈ [0,1]")
    check(p.exerciseCount == course.allExercises.filter { !$0.isBonus }.count,
          "\(course.code) : les bonus sont exclus du dénominateur")
    let weeks = ProgressEngine.weeklyProgress(for: course)
    check(!weeks.isEmpty, "\(course.code) : \(weeks.count) semaines planifiées")
    check(weeks.allSatisfy { (0...1).contains($0.overallPercent) },
          "\(course.code) : pourcentages hebdo valides")
}

print("== WorkloadEngine (EPFL) ==")
for course in courses.sorted(by: { $0.code < $1.code }) {
    let d = WorkloadEngine.delta(for: course, hoursPerCredit: 30)
    print("  \(course.code) : attendu \(d.expectedLabel) = cours \(DateUtils.hoursLabel(seconds: d.lectureSeconds)) + perso \(DateUtils.hoursLabel(seconds: d.exerciseSeconds)) · réel \(d.actualLabel) (dont amphi \(d.classLabel)) · écart \(d.deltaLabel)")
    check(d.expectedSeconds > 0, "\(course.code) charge attendue > 0")
    check(d.lectureSeconds + d.exerciseSeconds == d.expectedSeconds,
          "\(course.code) split cours+perso = attendu")
    check(d.actualSeconds >= WorkloadEngine.studySeconds(for: course),
          "\(course.code) le réel inclut les heures de cours")
    check(abs(d.expectedSeconds - Int(course.credits * 30 * 3600)) <= 1,
          "\(course.code) formule crédits × 30 h")
}
let aggregate = WorkloadEngine.aggregate(courses: courses, hoursPerCredit: 30)

print("== Charge attendue hebdomadaire ==")
for course in courses {
    let framed = WorkloadEngine.framedWeeklyHours(for: course)
    let personal = WorkloadEngine.weeklySelfStudyHours(for: course, hoursPerCredit: 30)
    let weekly = WorkloadEngine.expectedWeeklySeconds(for: course, hoursPerCredit: 30)
    check(weekly > 0, "\(course.code) : attendu hebdo > 0 (\(weekly / 3600) h)")
    check(abs(Double(weekly) - (framed + personal) * 3600) < 1,
          "\(course.code) : attendu hebdo = encadré (\(framed) h) + personnel (\(personal) h)")
    check(personal >= 0, "\(course.code) : travail personnel ≥ 0")
}

let weekStart = DateUtils.startOfWeek(Date())
let weeklyAggregate = WorkloadEngine.aggregateWeekly(courses: courses,
                                                     hoursPerCredit: 30,
                                                     from: weekStart,
                                                     to: DateUtils.addWeeks(1, to: weekStart))
check(weeklyAggregate.expectedSeconds == courses.reduce(0) {
    $0 + WorkloadEngine.expectedWeeklySeconds(for: $1, hoursPerCredit: 30)
}, "agrégat hebdo = somme des attendus par cours")
check(weeklyAggregate.lectureSeconds + weeklyAggregate.exerciseSeconds
      == weeklyAggregate.expectedSeconds,
      "agrégat hebdo : amphi + personnel = total")
check(weeklyAggregate.expectedSeconds < aggregate.expectedSeconds,
      "l'attendu hebdo est bien plus petit que le total semestriel "
      + "(\(weeklyAggregate.expectedSeconds / 3600) h vs \(aggregate.expectedSeconds / 3600) h)")

// Un objectif explicite doit remplacer la déduction ECTS, pas s'y ajouter.
if let sample = courses.first {
    let implied = WorkloadEngine.weeklySelfStudyHours(for: sample, hoursPerCredit: 30)
    let saved = sample.weeklySelfStudyHours
    sample.weeklySelfStudyHours = implied + 3
    check(abs(WorkloadEngine.weeklySelfStudyHours(for: sample, hoursPerCredit: 30) - (implied + 3)) < 0.001,
          "\(sample.code) : l'objectif explicite remplace la déduction ECTS")
    // `expectedWeeklySeconds` arrondit : comparer avec le même arrondi, sinon le
    // test dépend du hasard des décimales.
    let expected = Int(((WorkloadEngine.framedWeeklyHours(for: sample) + implied + 3) * 3600).rounded())
    check(WorkloadEngine.expectedWeeklySeconds(for: sample, hoursPerCredit: 30) == expected,
          "\(sample.code) : l'attendu hebdo suit l'objectif explicite")
    sample.weeklySelfStudyHours = saved
}
check(aggregate.expectedSeconds > 0 && aggregate.actualSeconds > 0,
      "agrégat : attendu \(aggregate.expectedLabel) / réel \(aggregate.actualLabel) / écart \(aggregate.deltaLabel)")

print("== Théorie typée (cours sans vidéo) ==")
let projectCourse = courses.first { $0.code == "PROJ-101" }
check(projectCourse != nil, "le cours sans vidéo existe dans les données d'exemple")
if let projectCourse {
    check(!projectCourse.theoryItems.isEmpty, "il a bien de la théorie")
    check(projectCourse.theoryItems.allSatisfy { $0.kind != .video },
          "aucun de ses éléments n'est une vidéo")
    check(projectCourse.theoryItems.allSatisfy { !$0.hasDuration },
          "ses chapitres n'ont pas de durée inventée")
    if let chapter = projectCourse.theoryItems.first {
        check(chapter.displayNumber.hasPrefix("Chapitre"),
              "le libellé suit le support : « \(chapter.displayNumber) »")
        check(chapter.kind.icon != TheoryKind.video.icon,
              "l'icône suit le support")
        check(ProgressEngine.remainingVideos(for: projectCourse, week: chapter.plannedWeek).count == 1,
              "un chapitre compte comme théorie restante")
    }
}
check(courses.contains { $0.theoryItems.contains { $0.kind == .video } },
      "les autres cours ont bien des vidéos")
check(Set(TheoryKind.allCases.map(\.label)).count == 4,
      "quatre supports distincts : \(TheoryKind.allCases.map(\.label).joined(separator: ", "))")

print("== Durée de vidéo par semaine ==")
let cs = courses.first { $0.code == "CS-250" }!
let week1 = ProgressEngine.plannedVideoSeconds(for: cs, week: 1)
check(week1 == 2700 + 3120 + 2400, "CS-250 semaine 1 = \(DateUtils.durationLabel(seconds: week1))")
check(!ProgressEngine.remainingVideos(for: cs, week: 2).isEmpty,
      "CS-250 semaine 2 : vidéos restantes (\(ProgressEngine.remainingVideos(for: cs, week: 2).count))")

print("== GamificationEngine ==")
let xp = GamificationEngine.totalXP(courses: courses, sessions: sessions)
let streak = GamificationEngine.currentStreak(sessions: sessions)
let badges = GamificationEngine.earnedBadges(courses: courses, sessions: sessions)
print("  XP \(xp) · niveau \(GamificationEngine.level(forXP: xp)) · série \(streak) j · badges \(badges.count)")
check(xp > 0, "XP > 0")
check(streak >= 1, "série ≥ 1 j (\(streak))")
check(!badges.isEmpty, "badges obtenus (\(badges.count))")
check(GamificationEngine.level(forXP: 0) == 1, "niveau initial = 1")
check((0...1).contains(GamificationEngine.levelProgress(forXP: xp)), "progression de niveau ∈ [0,1]")

print("== Entités sociales ==")
let group = StudyGroup(name: "Groupe test", courseCode: "CS-250")
context.insert(group)
context.insert(GroupMember(group: group, userID: "u1", displayName: "Alice Moreau", weeklySeconds: 12 * 3600, totalSeconds: 96 * 3600, completedSeriesCount: 4))
context.insert(GroupSeriesCompletion(group: group, userID: "u1", displayName: "Alice Moreau", courseCode: "CS-250", seriesNumber: 1))
try context.save()
let groups = try context.fetch(FetchDescriptor<StudyGroup>())
check(groups.count == 1, "groupe persisté")
check(groups.first?.members.count == 1, "membre lié au groupe (\(groups.first?.members.count ?? 0))")
check(groups.first?.completions.count == 1, "complétion liée au groupe")
check(groups.first?.inviteCode.hasPrefix("EPFL-") == true, "code d'invitation : \(groups.first?.inviteCode ?? "-")")
check(GroupMember(group: groups.first, userID: "u9", displayName: "Bob Favre").initials == "BF", "initiales calculées")

print("== Matières multiples d'un groupe ==")
let subjectGroup = StudyGroup(name: "Promo",
                              courseCodes: ["cs-250", " MATH-101 ", "CS-250", ""])
check(subjectGroup.subjectCodes == ["CS-250", "MATH-101"],
      "normalisation : majuscules, espaces retirés, sans doublon — \(subjectGroup.subjectCodes)")
check(StudyGroup.normalize(["a", "A", " b "]) == ["A", "B"], "liste de codes normalisée")
check(StudyGroup.normalize([]).isEmpty, "liste vide reste vide")

let legacyGroup = StudyGroup(name: "Ancien", courseCode: "PHYS-101")
check(legacyGroup.subjectCodes == ["PHYS-101"], "repli sur l'ancien champ mono-matière")
check(legacyGroup.tracks("phys-101"), "tracks() ignore la casse")
check(!legacyGroup.tracks("BIO-101"), "tracks() rejette une matière absente")

let bothGroup = StudyGroup(name: "Mixte", courseCode: "CS-250", courseCodes: ["CS-250", "MATH-101"])
check(bothGroup.subjectCodes == ["CS-250", "MATH-101"],
      "ancien et nouveau champ fusionnés sans doublon — \(bothGroup.subjectCodes)")
check(bothGroup.mySubjectCodes(myTrackedCourses: ["MATH-101"]) == ["MATH-101"],
      "mes matières : seulement celles que je suis")
check(bothGroup.mySubjectCodes(myTrackedCourses: []).isEmpty, "sans cours suivi, aucune matière commune")

bothGroup.addSubject("bio-101")
check(bothGroup.subjectCodes.count == 3, "ajout d'une matière")
bothGroup.removeSubject("CS-250")
check(bothGroup.subjectCodes == ["MATH-101", "BIO-101"],
      "retrait d'une matière, ancien champ compris — \(bothGroup.subjectCodes)")
check(bothGroup.courseCode.isEmpty, "le champ historique est vidé au retrait")

let absorbed = StudyGroup(name: "Absorbé", courseCode: "CS-250")
absorbed.subjectCodes = ["MATH-101"]
check(absorbed.subjectCodes == ["MATH-101"],
      "définir la liste absorbe le champ historique — \(absorbed.subjectCodes)")
check(absorbed.courseCode.isEmpty,
      "le champ historique ne peut plus ressusciter une matière retirée")
absorbed.subjectCodes = ["CS-250", "cs-250", " PHYS-101 "]
check(absorbed.subjectCodes == ["CS-250", "PHYS-101"],
      "affectation normalisée et dédupliquée — \(absorbed.subjectCodes)")

let invitationGroup = StudyGroup(name: "Buddies", courseCodes: ["CS-250"], inviteCode: "EPFL-4F2A")
check(invitationGroup.inviteLink == "studytrack://join?code=EPFL-4F2A",
      "lien d'invitation — \(invitationGroup.inviteLink)")
check(StudyGroup.normalizeInviteCode(" epfl-4f2a ") == "EPFL-4F2A",
      "code d'invitation reçu par lien, normalisé")
check(StudyGroup.normalizeInviteCode("EPFL 4F2A") == "EPFL4F2A", "espaces internes retirés")
check(invitationGroup.inviteMessage.contains("EPFL-4F2A")
      && invitationGroup.inviteMessage.contains("CS-250")
      && invitationGroup.inviteMessage.contains("studytrack://"),
      "message d'invitation : nom, matières, code et lien")

print("== Rôles dans un groupe ==")
check(GroupMember(userID: "u2", displayName: "Bob").role == .member, "rôle par défaut = membre")
let adminMember = GroupMember(userID: "u1", displayName: "Alice", role: .admin)
check(adminMember.isAdmin, "rôle admin reconnu")
adminMember.role = .member
check(!adminMember.isAdmin, "rétrogradation effective")
adminMember.roleRaw = "valeur inconnue"
check(adminMember.role == .member, "rôle illisible retombe sur membre")
check(GroupRole.admin.label == "Admin" && GroupRole.member.label == "Membre", "libellés de rôle")

let scopedMember = GroupMember(userID: "u3", displayName: "Chloé", courseCodes: ["MATH-101"])
check(scopedMember.follows("math-101"), "un membre suit sa matière, quelle que soit la casse")
check(!scopedMember.follows("CS-250"), "un membre ne suit pas les autres")
check(GroupMember(userID: "u4", displayName: "Dan").follows("CS-250"),
      "sans liste explicite, un membre suit tout le groupe")


/// Une échéance isolée pour les tests de recherche.
let builderMilestone = AcademicMilestone(externalID: "test.fin-examens",
                                         title: "Fin des examens",
                                         date: DateUtils.addDays(30, to: Date()),
                                         kind: .examEnd)

print("== Sous-questions ==")
// Un polycopié numérote ses exercices 1, 2, 3 dans chaque section, et regroupe
// souvent plusieurs questions sous un seul numéro. Les compter comme des
// exercices séparés gonfle la liste et fausse la progression.
let subSeries = ExerciseSeries(course: courses.first { $0.code == "CS-250" }, seriesNumber: 9)
let subExercise = Exercise(series: subSeries, exerciseNumber: "9.3", title: "Suites d'ensembles")
check(!subExercise.hasSubQuestions, "un exercice neuf n'a pas de question")
check(subExercise.subQuestionLabel == nil, "…et n'affiche pas de compteur")
check(subExercise.isDone == false, "…et n'est pas fait")

let q1 = SubQuestion(exercise: subExercise, label: "1", text: "L'intersection est bornée ?", sortOrder: 0)
let q2 = SubQuestion(exercise: subExercise, label: "2", text: "L'union est bornée ?", sortOrder: 1)
subExercise.subQuestions = [q1, q2]
check(subExercise.hasSubQuestions, "l'exercice a maintenant des questions")
check(subExercise.subQuestionLabel == "0/2", "compteur — \(subExercise.subQuestionLabel ?? "-")")

q1.toggle()
check(subExercise.subQuestionDoneCount == 1, "une question cochée")
check(!subExercise.isDone, "l'exercice n'est pas fait tant qu'elles ne le sont pas toutes")
check(subExercise.subQuestionLabel == "1/2", "compteur intermédiaire")

q2.toggle()
check(subExercise.isDone, "toutes cochées : l'exercice devient fait")
check(subExercise.subQuestionLabel == "2/2", "compteur complet")

q1.toggle()
check(!subExercise.isDone, "décocher une question défait l'exercice")
check(subExercise.doneAt == nil, "…et la date de réalisation est retirée")

// Cocher l'exercice entier coche ses questions : c'est le geste courant.
subExercise.setSubQuestions(done: true)
check(subExercise.isDone, "cocher l'exercice le marque fait")
check(subExercise.subQuestions.allSatisfy(\.isDone), "…et coche toutes ses questions")
subExercise.setSubQuestions(done: false)
check(!subExercise.isDone, "décocher l'exercice le défait")
check(subExercise.subQuestions.allSatisfy { !$0.isDone }, "…et décoche toutes ses questions")

// Deux niveaux : « 1) (a) (b) » et « 2) » font trois cases, pas cinq.
let nestedExercise = Exercise(series: subSeries, exerciseNumber: "9.4")
nestedExercise.replaceSubQuestions(with: [
    DetectedSubQuestion(label: "1", children: [DetectedSubQuestion(label: "a"), DetectedSubQuestion(label: "b")]),
    DetectedSubQuestion(label: "2"),
    DetectedSubQuestion(label: "", text: "Ensuite, représenter", kind: .part)
], in: nil)
check(nestedExercise.subQuestions.count == 5, "cinq nœuds enregistrés — \(nestedExercise.subQuestions.count)")
check(nestedExercise.sortedSubQuestions.map(\.label) == ["1", "2", ""], "trois au premier niveau")
check(nestedExercise.subQuestionLabel == "0/4", "quatre cases réelles — \(nestedExercise.subQuestionLabel ?? "-")")
let pointA = nestedExercise.sortedSubQuestions[0].sortedChildren[0]
check(pointA.path == "1.a", "chemin d'un point — \(pointA.path)")
pointA.toggle()
check(!nestedExercise.sortedSubQuestions[0].isDone, "une question à moitié faite ne l'est pas")
nestedExercise.sortedSubQuestions[0].sortedChildren[1].toggle()
check(nestedExercise.sortedSubQuestions[0].isDone, "tous ses points faits : la question l'est")
check(nestedExercise.subQuestionLabel == "2/4", "compteur par les points — \(nestedExercise.subQuestionLabel ?? "-")")
nestedExercise.sortedSubQuestions[0].toggle()
check(nestedExercise.subQuestionLabel == "0/4", "décocher la question décoche ses points")
nestedExercise.sortedSubQuestions[0].toggle()
nestedExercise.sortedSubQuestions[1].toggle()
nestedExercise.sortedSubQuestions[2].toggle()
check(nestedExercise.isDone, "toutes les cases faites : l'exercice l'est")

// Un réimport remplace l'arbre et garde ce qui était coché, par chemin.
nestedExercise.sortedSubQuestions[1].toggle()
nestedExercise.replaceSubQuestions(with: [
    DetectedSubQuestion(label: "1", children: [DetectedSubQuestion(label: "a"), DetectedSubQuestion(label: "b"),
                                               DetectedSubQuestion(label: "c")]),
    DetectedSubQuestion(label: "2")
], in: nil)
check(nestedExercise.subQuestionLabel == "2/4", "1.a et 1.b restent cochés, 1.c est neuf — \(nestedExercise.subQuestionLabel ?? "-")")
check(!nestedExercise.isDone, "…et l'exercice n'est plus fait")
check(nestedExercise.detectedSubQuestions.map(\.label) == ["1", "2"], "l'arbre se relit pour être modifié")

// L'étiquette s'écrit comme le polycopié.
check(SubQuestion(exercise: nil, label: "1").displayLabel == "1.", "étiquette numérique")
check(SubQuestion(exercise: nil, label: "a").displayLabel == "(a)", "étiquette alphabétique")
check(SubQuestion(exercise: nil, label: "(b)").displayLabel == "(b)", "déjà ponctuée : inchangée")
check(SubQuestion(exercise: nil, label: "1.").displayLabel == "1.", "idem pour un point")
check(SubQuestion(exercise: nil, label: "").displayLabel == "", "étiquette vide")

// Une série dont les exercices ont des questions reste comptée par exercices.
let subSeries2 = ExerciseSeries(course: nil, seriesNumber: 10)
let e1 = Exercise(series: subSeries2, exerciseNumber: "10.1")
let e1q = SubQuestion(exercise: e1, label: "1")
e1.subQuestions = [e1q]
let e2 = Exercise(series: subSeries2, exerciseNumber: "10.2")
subSeries2.exercises = [e1, e2]
e1.setSubQuestions(done: true)
e2.doneAt = Date()
check(subSeries2.doneCount == 2,
      "la série compte les exercices, pas les questions (\(subSeries2.doneCount)/\(subSeries2.requiredExercises.count))")
check(subSeries2.isComplete, "…et elle est complète")

// La réponse du modèle porte les questions, sous les deux formes acceptées.
let withLabels = #"{"series":[{"number":4,"title":"Suites","exercises":[{"number":"4.2","title":"Bornes","questions":["1","2"]}]}]}"#
let parsedLabels = SeriesAIParsing.parse(withLabels)
check(parsedLabels.first?.exercises.first?.subQuestions.map(\.label) == ["1", "2"],
      "questions écrites comme de simples étiquettes")
let withObjects = #"{"series":[{"number":4,"title":"Suites","exercises":[{"number":"4.2","title":"Bornes","questions":[{"label":"a","text":"Première"},{"label":"b"}]}]}]}"#
let parsedObjects = SeriesAIParsing.parse(withObjects)
check(parsedObjects.first?.exercises.first?.subQuestions.map(\.label) == ["a", "b"],
      "…ou comme des objets")
check(parsedObjects.first?.exercises.first?.subQuestions.first?.text == "Première",
      "le texte est conservé quand il est donné")
let noLabels = #"{"series":[{"number":4,"title":"Suites","exercises":[{"number":"4.2","title":"Bornes","questions":["",""]}]}]}"#
check(SeriesAIParsing.parse(noLabels).first?.exercises.first?.subQuestions.map(\.label) == ["1", "2"],
      "une étiquette vide reçoit son rang")
let duplicated = #"{"series":[{"number":4,"title":"Suites","exercises":[{"number":"4.2","title":"Bornes","questions":["1","1","2"]}]}]}"#
check(SeriesAIParsing.parse(duplicated).first?.exercises.first?.subQuestions.count == 2,
      "les étiquettes en double sont écartées")
let visionAnswer = #"{"series":[{"number":3,"exercises":[{"number":"3.1","page":1,"parts":[{"label":"1)","kind":"question","children":[{"label":"(a)"},{"label":"(b)"}]},{"label":"2","children":[{"label":"a"},{"label":"b"},{"label":"c"}]}]},{"number":"3.11","parts":[{"label":null,"kind":"part","text":"Calculer lim a_n"},{"label":"1"},{"label":"2"}]}]}]}"#
let visionParsed = SeriesAIParsing.parse(visionAnswer).first?.exercises
check(DetectedSubQuestion.outline(visionParsed?.first?.subQuestions ?? []) == "1(a,b),2(a,b,c)",
      "réponse « vision » : arbre lu, ponctuation retirée — \(DetectedSubQuestion.outline(visionParsed?.first?.subQuestions ?? []))")
check(visionParsed?.first?.pageIndex == 0, "la page du modèle (1…) devient un index (0…)")
let withStatement = SeriesAIParsing.parse(#"{"series":[{"number":3,"exercises":[{"number":"3.2","title":"Monotonie","statement":"Montrer que x_n est croissante ⇔ ad − bc ≥ 0"}]}]}"#)
check(withStatement.first?.exercises.first?.statement == "Montrer que x_n est croissante ⇔ ad − bc ≥ 0",
      "l'énoncé d'un exercice sans questions est lu")
check(DetectedSubQuestion.outline(visionParsed?.last?.subQuestions ?? []) == "part,1,2", "une partie sans numéro est gardée")

// La fusion ne mélange jamais deux numérotations : la plus complète gagne.
let heuristicSide = [DetectedSeries(number: 4, title: "Suites",
                                    exercises: [DetectedExercise(number: "4.2", title: "Bornes", isBonus: false)])]
let aiSide = [DetectedSeries(number: 4, title: "Suites",
                             exercises: [DetectedExercise(number: "4.2", title: "Bornes", isBonus: false,
                                                          subQuestions: [DetectedSubQuestion(label: "1", text: ""),
                                                                         DetectedSubQuestion(label: "2", text: "")])])]
let merged = SeriesAIParsing.merge(heuristic: heuristicSide, ai: aiSide)
check(merged.first?.exercises.first?.subQuestions.count == 2,
      "la fusion apporte les questions — \(merged.first?.exercises.first?.subQuestions.count ?? 0)")
let mergedBack = SeriesAIParsing.merge(heuristic: aiSide, ai: heuristicSide)
check(mergedBack.first?.exercises.first?.subQuestions.count == 2,
      "…et ne les retire jamais")

print("== Lecture de la réponse d'un modèle ==")
// Le JSON d'un modèle n'est pas un contrat : il écrit `2` là où on attend `"2"`,
// `"02a"` là où on attend un entier, `"oui"` là où on attend un booléen. Un
// décodeur strict rejetait **toute** la réponse pour un seul champ, et
// l'utilisateur voyait une extraction vide sans savoir pourquoi.

// Le cas réel : un PDF dont les exercices sont numérotés 1,2,3 dans chaque section,
// sans intitulé individuel. Le modèle renvoie des titres qu'il a lui-même écrits.
let realAnswer = """
{"series":[{"number":2,"title":"Sommes, bornes et densité","exercises":[
{"number":"2.1","title":"Inégalité des suprema","isBonus":false},
{"number":"2.2","title":"Suite d'intervalles ouverts","isBonus":false},
{"number":"2.5","title":"Infimum de ⌊x⌋ + ⌊x−1⌋","isBonus":false}]}]}
"""
let parsedReal = SeriesAIParsing.parse(realAnswer)
check(parsedReal.count == 1, "une série lue (\(parsedReal.count))")
check(parsedReal.first?.number == 2, "numéro de série entier")
check(parsedReal.first?.title == "Sommes, bornes et densité", "titre de série conservé")
check(parsedReal.first?.exercises.count == 3, "trois exercices")
check(parsedReal.first?.exercises.first?.number == "2.1",
      "numéro qualifié par la série — \(parsedReal.first?.exercises.first?.number ?? "-")")
check(parsedReal.first?.exercises.first?.title == "Inégalité des suprema",
      "titre français conservé")

// Les formes que le modèle peut produire et qui faisaient tout échouer.
let messyAnswer = """
{"series":[{"number":"02a","title":"Sommes","exercises":[
{"number":3,"title":"Trois","isBonus":"oui"},
{"number":"2.4","title":"Quatre","isBonus":"non"}]}]}
"""
let parsedMessy = SeriesAIParsing.parse(messyAnswer)
check(parsedMessy.count == 1,
      "« number » en texte « 02a » ne fait plus perdre la série (\(parsedMessy.count))")
check(parsedMessy.first?.number == 2, "…et donne 2")
check(parsedMessy.first?.exercises.count == 2, "les deux exercices survivent")
check(parsedMessy.first?.exercises.first?.number == "2.3",
      "un numéro écrit en nombre est qualifié — \(parsedMessy.first?.exercises.first?.number ?? "-")")
check(parsedMessy.first?.exercises.first?.isBonus == true, "« oui » vaut true")
check(parsedMessy.first?.exercises.last?.isBonus == false, "« non » vaut false")

// Un exercice sans numéro reçoit le suivant dans l'ordre.
let unnumbered = """
{"series":[{"number":5,"title":"Densité","exercises":[
{"title":"Un"},{"title":"Deux"}]}]}
"""
let parsedUnnumbered = SeriesAIParsing.parse(unnumbered)
check(parsedUnnumbered.first?.exercises.count == 2,
      "un exercice sans numéro n'est pas jeté (\(parsedUnnumbered.first?.exercises.count ?? 0))")
check(parsedUnnumbered.first?.exercises.map(\.number) == ["5.1", "5.2"],
      "…il reçoit le numéro suivant — \(parsedUnnumbered.first?.exercises.map(\.number) ?? [])")
check(parsedUnnumbered.first?.exercises.first?.title == "Un", "…et garde son titre")

// Une liste d'exercices absente ne doit pas faire perdre la série.
let noExercises = #"{"series":[{"number":7,"title":"Vide"}]}"#
let parsedEmpty = SeriesAIParsing.parse(noExercises)
check(parsedEmpty.count == 1 && parsedEmpty.first?.exercises.isEmpty == true,
      "une série sans exercices reste une série")

// Les réponses manifestement illisibles sont refusées, pas devinées.
check(SeriesAIParsing.parse("pas de json").isEmpty, "sans JSON, rien")
check(SeriesAIParsing.parse(#"{"series":[]}"#).isEmpty, "liste vide")
check(SeriesAIParsing.parse(#"{"series":[{"number":99,"title":"Trop grand"}]}"#).isEmpty,
      "un numéro de série hors bornes est refusé")

// La qualification d'un numéro, cas par cas.
check(SeriesAIParsing.normalizeNumber("1", series: 2) == "2.1",
      "un numéro nu est préfixé par la série")
check(SeriesAIParsing.normalizeNumber("2.3", series: 2) == "2.3", "un numéro déjà qualifié reste")
check(SeriesAIParsing.normalizeNumber("Ex 3.2", series: 2) == "2.2",
      "la série de l'objet parent fait foi")
check(SeriesAIParsing.normalizeNumber("02a", series: 2) == "2.2",
      "« 02a » se lit 2 — cas réel d'un en-tête de série EPFL")
check(SeriesAIParsing.normalizeNumber("", series: 2) == nil, "un numéro vide ne donne rien")
check(SeriesAIParsing.normalizeNumber(nil, series: 2) == nil, "un numéro absent non plus")

print("== Ordre des moteurs d'analyse ==")
// Cet ordre a déjà été inversé une fois sans que rien ne le signale : le modèle
// embarqué passait avant le modèle servi, et lisait nettement moins bien.
func engines(_ shared: Bool, _ device: Bool, _ remote: Bool) -> [String] {
    SeriesEngineOrder.engines(sharedAvailable: shared,
                              onDeviceAvailable: device,
                              remoteConfigured: remote).map(\.rawValue)
}
check(engines(true, true, true) == ["shared", "onDevice", "remote"],
      "le service passé avant le modèle embarqué — \(engines(true, true, true))")
check(engines(true, true, false) == ["shared", "onDevice"], "sans service perso")
check(engines(false, true, false) == ["onDevice"],
      "sans fonction déployée, le modèle embarqué prend le relais")
check(engines(false, false, true) == ["remote"],
      "sans fonction ni modèle embarqué, le service perso reste")
check(engines(false, false, false).isEmpty, "aucun moteur : la lecture par motifs seule")
check(engines(true, false, false) == ["shared"], "le service seul suffit")
check(engines(false, true, true) == ["onDevice", "remote"],
      "embarqué puis perso quand la fonction manque")

print("== Saisie d'un temps au clavier ==")
// On accepte ce que les gens tapent vraiment : refuser tout sauf « 1:30 »
// rendrait le champ plus pénible que les boutons qu'il remplace.
check(TimerText.seconds(from: "1:30") == 5400, "« 1:30 » = 1 h 30")
check(TimerText.seconds(from: "90") == 5400, "« 90 » = 90 minutes, le geste naturel")
check(TimerText.seconds(from: "1h30") == 5400, "« 1h30 »")
check(TimerText.seconds(from: "1 h 30") == 5400, "« 1 h 30 », avec des espaces")
check(TimerText.seconds(from: "1,5h") == 5400, "« 1,5h », virgule française")
check(TimerText.seconds(from: "1.5h") == 5400, "« 1.5h », point")
check(TimerText.seconds(from: "45m") == 2700, "« 45m »")
check(TimerText.seconds(from: "0:45") == 2700, "« 0:45 » = 45 minutes, comme le champ les écrit")
check(TimerText.seconds(from: ":30") == 1800, "« :30 » se lit comme « 0:30 » = 30 minutes")
check(TimerText.seconds(from: "1:30:15") == 5415, "« 1:30:15 »")
check(TimerText.seconds(from: "2 heures") == 7200, "« 2 heures » en toutes lettres")
check(TimerText.seconds(from: "1 h") == 3600, "« 1 h » seule")

check(TimerText.seconds(from: "") == nil, "une saisie vide ne donne rien")
check(TimerText.seconds(from: "   ") == nil, "une saisie blanche non plus")
check(TimerText.seconds(from: "abc") == nil, "un texte sans nombre est refusé")
check(TimerText.seconds(from: "1:2:3:4") == nil, "trop de segments est refusé")

// Bornes : au-delà de douze heures, ce n'est plus une session d'étude.
check(TimerText.seconds(from: "999") == Double(TimerText.maximumHours) * 3600,
      "une saisie démesurée est bornée à \(TimerText.maximumHours) h")
check(TimerText.seconds(from: "-30") == 0, "une saisie négative vaut zéro")
check(TimerText.seconds(from: "0") == 0, "zéro est une valeur valide")

// L'affichage.
check(TimerText.text(from: 5400) == "1:30", "écriture heures:minutes — \(TimerText.text(from: 5400))")
check(TimerText.text(from: 2700) == "0:45", "moins d'une heure")
check(TimerText.text(from: 0) == "0:00", "zéro")
check(TimerText.text(from: -10) == "0:00", "un négatif s'affiche zéro")
check(TimerText.longText(from: 5400) == "1 h 30", "écriture longue — \(TimerText.longText(from: 5400))")
check(TimerText.longText(from: 3600) == "1 h", "une heure pile")
check(TimerText.longText(from: 2700) == "45 min", "moins d'une heure")

// Aller-retour : ce que le champ écrit doit se relire tel quel.
for seconds in [0.0, 60.0, 600.0, 2700.0, 5400.0, 7200.0] {
    check(TimerText.seconds(from: TimerText.text(from: seconds)) == seconds,
          "aller-retour à \(Int(seconds)) s")
}

print("== Plan de révision ==")
func revisionItem(_ id: String, _ kind: RevisionItem.Kind, week: Int = 1) -> RevisionItem {
    RevisionItem(id: id, label: id, kind: kind, week: week)
}
let revCalendar = Calendar(identifier: .gregorian)
func revDay(_ offset: Int) -> Date {
    revCalendar.date(byAdding: .day, value: offset,
                     to: revCalendar.startOfDay(for: Date()))!
}

// Douze éléments, un examen dans douze jours.
let revItems = (1...6).map { revisionItem("T\($0)", .theory, week: $0) }
    + (1...4).map { revisionItem("E\($0)", .exercise, week: $0) }
    + (1...2).map { revisionItem("C\($0)", .correction, week: $0) }
let revWorkload = RevisionWorkload(courseCode: "CS-250", examTitle: "Final",
                                   examDate: revDay(12), items: revItems)
let revPlan = RevisionEngine.plan(revWorkload, from: revDay(0), calendar: revCalendar)

check(revPlan.totalItems == 12, "douze éléments dans la charge (\(revPlan.totalItems))")
check(revPlan.usableDays == 12, "douze jours avant l'évaluation (\(revPlan.usableDays))")
check(revPlan.days.count == 12, "le plan couvre chaque jour (\(revPlan.days.count))")
check(RevisionEngine.reviewDayCount(usableDays: 12) == 2,
      "un cinquième des jours est réservé à la relecture (\(RevisionEngine.reviewDayCount(usableDays: 12)))")
check(revPlan.days.suffix(2).allSatisfy(\.isReview),
      "les deux derniers jours sont de la relecture")
check(revPlan.days.prefix(10).allSatisfy { !$0.isReview },
      "les dix premiers portent du contenu")
check(revPlan.days.prefix(10).reduce(0) { $0 + $1.items.count } == 12,
      "tous les éléments sont répartis sur les jours de travail")

// L'ordre est **contigu** : on avance dans le cours, on ne mélange pas.
let flat = revPlan.days.flatMap(\.items)
check(flat == flat.sorted { lhs, rhs in
    lhs.week != rhs.week ? lhs.week < rhs.week : lhs.kind.rank < rhs.kind.rank
}, "les éléments restent dans l'ordre du cours")
check(flat.first?.kind == .theory, "la théorie vient en premier, dans la première semaine")
check(flat.first?.week == 1, "…et c'est bien la semaine 1")
// La priorité est la **semaine** : on termine une semaine avant d'attaquer la
// suivante. Au sein d'une semaine, l'ordre est théorie, exercices, corrections.
for week in Set(flat.map(\.week)) {
    let weekItems = flat.filter { $0.week == week }
    check(weekItems == weekItems.sorted { $0.kind.rank < $1.kind.rank },
          "semaine \(week) : théorie, puis exercices, puis corrections")
}
check(revPlan.days.allSatisfy { $0.items.count >= 1 } || revPlan.days.prefix(10).allSatisfy { !$0.items.isEmpty },
      "aucun jour de travail n'est vide (\(revPlan.days.prefix(10).map(\.items.count)))")

// Un examen **demain** : un seul jour, et il est utilisé.
let tomorrow = RevisionEngine.plan(
    RevisionWorkload(courseCode: "X", examTitle: "Quiz", examDate: revDay(1), items: revItems),
    from: revDay(0), calendar: revCalendar)
check(tomorrow.usableDays == 1, "un examen demain laisse un jour (\(tomorrow.usableDays))")
check(tomorrow.days.count == 1 && tomorrow.days[0].items.count == 12,
      "tout tient sur ce jour (\(tomorrow.days.first?.items.count ?? 0))")
check(tomorrow.perDay == 12, "…soit douze éléments ce jour-là (\(tomorrow.perDay))")
check(RevisionEngine.plan(
    RevisionWorkload(courseCode: "X", examTitle: "Quiz", examDate: revDay(1), items: revItems),
    from: revDay(0), calendar: revCalendar, minutesPerDay: 60).warning != nil,
      "avec une heure disponible, le plan prévient que c'est serré")

// Un examen **aujourd'hui ou passé** : plus rien à planifier, et on le dit.
let today = RevisionEngine.plan(
    RevisionWorkload(courseCode: "X", examTitle: "Final", examDate: revDay(0), items: revItems),
    from: revDay(0), calendar: revCalendar)
check(today.usableDays == 0, "aucun jour disponible")
check(today.days.isEmpty, "aucun jour planifié")
check(today.warning?.contains("passée") == true, "…et l'écran explique pourquoi")

// Plus rien à faire : le plan est vide, mais valide.
let nothing = RevisionEngine.plan(
    RevisionWorkload(courseCode: "X", examTitle: "Final", examDate: revDay(5), items: []),
    from: revDay(0), calendar: revCalendar)
check(nothing.isEmpty, "aucun élément à réviser")
check(nothing.days.count == 5, "…mais les jours existent quand même")
check(nothing.days.allSatisfy(\.isEmpty), "…et ils sont vides")

// Le budget de temps rend le plan réaliste ou non.
let tight = RevisionEngine.plan(revWorkload, from: revDay(0), calendar: revCalendar, minutesPerDay: 5)
check(tight.warning?.contains("serré") == true,
      "un budget trop court est signalé — \(tight.warning ?? "aucun")")
let loose = RevisionEngine.plan(revWorkload, from: revDay(0), calendar: revCalendar, minutesPerDay: 240)
check(loose.warning == nil, "un budget large ne produit pas d'avertissement")

// La charge se construit depuis les modèles.
if let revisionCourse = courses.first(where: { $0.code == "CS-250" }),
   let revisionExam = revisionCourse.sortedExams.first {
    let modelWorkload = RevisionBuilder.workload(course: revisionCourse, exam: revisionExam)
    check(modelWorkload.courseCode == revisionCourse.displayCode, "le code du cours est repris")
    check(modelWorkload.items.allSatisfy { !$0.id.isEmpty }, "chaque élément a un identifiant")
    check(modelWorkload.items.contains { $0.kind == .theory || $0.kind == .exercise || $0.kind == .correction },
          "…et une nature connue")
}

print("== Annales ==")
let pastSummary = PastExamProgress.summary([
    (2024, false), (2023, true), (2022, true), (2021, false)
])
check(pastSummary.total == 4, "quatre annales")
check(pastSummary.worked == 2, "deux travaillées")
check(pastSummary.label == "2/4 travaillées", "libellé du bilan — \(pastSummary.label)")
check(pastSummary.pendingYears == [2024, 2021], "les années restantes, de la plus récente à la plus ancienne")
check(!pastSummary.isComplete, "le jeu n'est pas complet")

let doneSummary = PastExamProgress.summary([(2024, true), (2023, true)])
check(doneSummary.isComplete, "tout est travaillé")
check(doneSummary.label == "2/2 travaillées", "libellé quand tout est fait")
check(PastExamProgress.summary([]).label == "Aucune annale", "aucune annale : le libellé le dit")
check(PastExamProgress.summary([]).ratio == 0, "…sans division par zéro")

check(PastExamProgress.priority([(2020, false), (2024, false), (2022, true), (2023, false)])
        == [2024, 2023, 2020],
      "priorité aux années récentes non travaillées")
check(PastExamProgress.priority([(2024, false), (2023, false)], limit: 1) == [2024],
      "la priorité est bornée")
check(PastExamProgress.priority([(2024, true)]).isEmpty, "rien à prioriser quand tout est fait")

let pastCourse = courses.first { $0.code == "CS-250" }!
let past = PastExam(course: pastCourse, title: "Examen final 2024", year: 2024)
check(past.title == "Examen final 2024", "titre conservé")
check(!past.isWorked, "une annale neuve n'est pas travaillée")
check(past.statusLabel == "Pas encore travaillé", "…et le dit — \(past.statusLabel)")
past.workedAt = Date()
past.confidence = .medium
check(past.isWorked, "cochée, elle est travaillée")
check(past.statusLabel.contains("Travaillé le"), "…avec sa date — \(past.statusLabel)")
check(past.url == nil, "sans lien, aucune URL inventée")
past.urlString = "https://example.org/sujet.pdf"
check(past.url != nil, "un lien valide donne une URL")
past.urlString = "   "
check(past.url == nil, "un lien blanc n'en donne pas")
let untitled = PastExam(course: pastCourse, year: 2023, kind: .midterm)
check(untitled.title == "Midterm 2023", "sans titre, un intitulé par défaut — \(untitled.title)")

print("== Journal local ==")
var logEntries: [LogEntry] = []
for index in 0..<10 {
    logEntries = LogBuffer.append(LogEntry(level: .info, category: "test", message: "ligne \(index)"),
                                  to: logEntries)
}
check(logEntries.count == 10, "dix lignes ajoutées (\(logEntries.count))")
check(logEntries.first?.message == "ligne 9", "la plus récente est en tête")

// Le tampon est borné.
var bounded: [LogEntry] = []
for index in 0..<(LogBuffer.limit + 50) {
    bounded = LogBuffer.append(LogEntry(level: .info, category: "test", message: "\(index)"), to: bounded)
}
check(bounded.count == LogBuffer.limit,
      "le journal est borné à \(LogBuffer.limit) lignes (\(bounded.count))")

// Quand la place manque, on garde ce qui explique un problème.
var mixed: [LogEntry] = []
mixed = LogBuffer.append(LogEntry(level: .error, category: "test", message: "erreur ancienne"), to: mixed)
for index in 0..<LogBuffer.limit {
    mixed = LogBuffer.append(LogEntry(level: .info, category: "test", message: "\(index)"), to: mixed)
}
check(mixed.contains { $0.message == "erreur ancienne" },
      "une erreur survit à l'éviction des informations")
check(mixed.count <= LogBuffer.limit, "et le tampon reste borné (\(mixed.count))")

check(LogBuffer.filtered(mixed, level: nil).count == mixed.count, "sans filtre, tout passe")
check(LogBuffer.filtered(mixed, level: .error).count == 1, "le filtre par niveau isole les erreurs")
check(LogBuffer.count(mixed, level: .info) == mixed.count - 1, "le comptage par niveau est juste")
check(LogBuffer.text([], formatter: ISO8601DateFormatter()) == "Journal vide.",
      "un journal vide se dit vide")
check(LogBuffer.text([LogEntry(level: .warning, category: "sync", message: "échec",
                               detail: "détail")]).contains("AVERTISSEMENT"),
      "le texte porte le niveau en clair")
check(LogBuffer.text([LogEntry(level: .info, category: "import", message: "ok",
                               detail: "deuxième ligne")]).contains("deuxième ligne"),
      "le détail est repris dans l'export")

print("== Export pour un assistant (source du serveur MCP) ==")
let exportCourses = courses.filter(\.isTracked)
let exportData = AssistantExport.make(courses: exportCourses,
                                      sessions: sessions,
                                      milestones: [],
                                      groups: [],
                                      hoursPerCredit: 30,
                                      displayName: "Test")
check(exportData["format"] as? String == "studytrack.assistant",
      "le format est annoncé — \(exportData["format"] ?? "-")")
check(exportData["version"] as? Int == AssistantExport.formatVersion,
      "la version du format est portée")
check(exportData["generatedAt"] is String, "l'horodatage est présent")

let exportedCourses = exportData["courses"] as? [[String: Any]] ?? []
check(exportedCourses.count == exportCourses.count,
      "tous les cours suivis sont exportés (\(exportedCourses.count))")
check(exportedCourses.allSatisfy { $0["code"] is String && $0["name"] is String },
      "chaque cours a un code et un nom")

if let firstCourse = exportedCourses.first,
   let series = firstCourse["series"] as? [[String: Any]],
   let firstSeries = series.first,
   let exercises = firstSeries["exercises"] as? [[String: Any]],
   let firstExercise = exercises.first {
    check(firstExercise["number"] is String, "un exercice porte son numéro")
    check(firstExercise["done"] is Bool, "…et son état")
    check(firstExercise["bonus"] is Bool, "…et s'il est facultatif")
} else {
    check(false, "le cours d'exemple a des séries et des exercices exportés")
}

// Le JSON doit être sérialisable : c'est ce que le serveur MCP lit.
let exportJSON = AssistantExport.data(courses: exportCourses,
                                      sessions: sessions,
                                      milestones: [],
                                      groups: [],
                                      hoursPerCredit: 30,
                                      displayName: "Test")
check(exportJSON != nil, "l'instantané est sérialisable")
if let exportJSON,
   let reparsed = try? JSONSerialization.jsonObject(with: exportJSON) as? [String: Any] {
    check(reparsed["format"] as? String == "studytrack.assistant",
          "…et se relit après un aller-retour JSON")
    check((reparsed["courses"] as? [[String: Any]])?.isEmpty == false, "les cours survivent")
}
// Un export sans cours ne doit pas produire un objet vide mais valide.
let emptyExport = AssistantExport.make(courses: [], sessions: [], milestones: [],
                                       groups: [], hoursPerCredit: 25, displayName: "")
check(emptyExport["format"] as? String == "studytrack.assistant",
      "un export vide garde son format")
check((emptyExport["courses"] as? [[String: Any]])?.isEmpty == true,
      "…et une liste de cours vide plutôt qu'absente")

print("== Anki : AnkiConnect ==")
// L'adresse : on accepte ce que les gens tapent vraiment.
check(AnkiConnect.normalizeEndpoint("192.168.1.42:8765") == "http://192.168.1.42:8765",
      "un hôte sans schéma reçoit « http:// »")
check(AnkiConnect.normalizeEndpoint("http://127.0.0.1:8765/") == "http://127.0.0.1:8765",
      "la barre finale est retirée")
check(AnkiConnect.normalizeEndpoint("  http://mac.local:8765  ") == "http://mac.local:8765",
      "les espaces sont ignorés")
check(AnkiConnect.normalizeEndpoint("") == nil, "une adresse vide ne donne rien")
check(AnkiConnect.normalizeEndpoint("   ") == nil, "une adresse blanche non plus")
check(AnkiConnect.normalizeEndpoint("http://pas une url") == nil, "une adresse invalide est refusée")

// La requête : le format exact attendu par AnkiConnect.
let ankiRequest = AnkiConnect.requestData(action: "deckNames")
check(ankiRequest != nil, "la requête est sérialisable")
if let ankiRequest,
   let object = try? JSONSerialization.jsonObject(with: ankiRequest) as? [String: Any] {
    check(object["action"] as? String == "deckNames", "l'action est portée telle quelle")
    check(object["version"] as? Int == AnkiConnect.protocolVersion,
          "la version du protocole est annoncée (\(object["version"] ?? "-"))")
    check(object["params"] != nil, "les paramètres sont présents, même vides")
}
let addRequest = AnkiConnect.requestData(action: "addNote",
                                         params: ["note": ["deckName": "Test"]])
if let addRequest,
   let object = try? JSONSerialization.jsonObject(with: addRequest) as? [String: Any],
   let params = object["params"] as? [String: Any] {
    check(params["note"] != nil, "les paramètres sont imbriqués sous « params »")
}

// La réponse : AnkiConnect signale ses erreurs **dans** un corps HTTP 200.
func ankiOutcome(_ json: String) -> AnkiOutcome {
    AnkiConnect.outcome(from: Data(json.utf8))
}
check(ankiOutcome(#"{"result": 6, "error": null}"#).isSuccess, "une réponse sans erreur réussit")
check(ankiOutcome(#"{"result": ["Default", "StudyTrack"], "error": null}"#).stringList
        == ["Default", "StudyTrack"],
      "une liste de paquets est lue")
check(ankiOutcome(#"{"result": null, "error": null}"#).isSuccess, "un résultat nul est valide")
check(ankiOutcome(#"{"result": null, "error": "collection is not available"}"#).errorMessage != nil,
      "une erreur non vide est retenue")
check(ankiOutcome(#"{"result": null, "error": ""}"#).isSuccess,
      "une erreur vide n'est pas une erreur")
check(ankiOutcome("pas du json").errorMessage != nil, "une réponse illisible est signalée")
check(ankiOutcome(#"{"autre": 1}"#).errorMessage != nil, "une réponse sans résultat est signalée")

// Les booléens arrivent en `1` dans `NSNumber` : il ne faut pas les confondre.
check(AnyJSON(raw: true) == .bool(true), "un vrai booléen est un booléen")
check(AnyJSON(raw: 1) == .number(1), "un nombre reste un nombre")
check(AnyJSON(raw: 1.5) == .number(1.5), "un décimal aussi")

// Les messages d'Anki supposent qu'on sait de quoi ils parlent.
check(AnkiConnect.explain("collection is not available").contains("collection"),
      "« collection is not available » est expliqué")
check(AnkiConnect.explain("deck was not found: Test").contains("paquet"),
      "« deck was not found » est expliqué")
check(AnkiConnect.explain("cannot create note because it is a duplicate").contains("existe déjà"),
      "un doublon est expliqué")
check(AnkiConnect.explain("erreur inconnue") == "erreur inconnue",
      "un message inconnu est rendu tel quel, sans invention")

// ── Les cartes ──────────────────────────────────────────────────────────────
let noteSeries = ExerciseSeries(course: courses.first { $0.code == "CS-250" }, seriesNumber: 3)
let noteExercise = Exercise(series: noteSeries, exerciseNumber: "3.2", title: "Tri fusion")
noteExercise.redoRequired = true
noteExercise.correctionNote = "Diviser puis fusionner en O(n log n)."
let exerciseNote = AnkiNoteFactory.exercise(noteExercise, deck: "StudyTrack")
check(exerciseNote.deckName == "StudyTrack", "le paquet est celui demandé")
check(exerciseNote.modelName == "Basic", "le modèle par défaut est Basic")
check(exerciseNote.fields["Front"]?.contains("CS-250") == true,
      "le recto porte le cours — \(exerciseNote.fields["Front"] ?? "-")")
check(exerciseNote.fields["Front"]?.contains("Exercice 3.2") == true, "…et le numéro")
check(exerciseNote.fields["Back"]?.contains("O(n log n)") == true,
      "le verso porte la note de correction")
check(exerciseNote.tags.contains("StudyTrack"), "l'étiquette StudyTrack est posée")
check(exerciseNote.tags.contains("à-refaire"), "…et une étiquette « à refaire »")

let plainExercise = Exercise(series: noteSeries, exerciseNumber: "3.3")
let plainNote = AnkiNoteFactory.exercise(plainExercise, deck: "StudyTrack")
check(plainNote.fields["Back"] == "À compléter.",
      "sans contenu, le verso invite à compléter au lieu d'être vide")

let noteCourse = courses.first { $0.code == "CS-250" }!
let theoryItem = TheoryItem(course: noteCourse, sectionNumber: 1, number: "1.2",
                            title: "Analyse asymptotique")
let unsentTheory = AnkiNoteFactory.theory(theoryItem, deck: "StudyTrack")
check(unsentTheory.fields["Front"]?.contains("Vidéo 1.2") == true,
      "le recto porte le support et le numéro — \(unsentTheory.fields["Front"] ?? "-")")
check(unsentTheory.fields["Back"] == "À résumer.", "sans résumé, le verso invite à résumer")
check(unsentTheory.tags.contains("à-résumer"), "l'étiquette « à résumer » est posée")

theoryItem.summaryText = "La complexité se décrit en grand O."
let sentTheory = AnkiNoteFactory.theory(theoryItem, deck: "StudyTrack")
check(sentTheory.fields["Back"]?.contains("grand O") == true, "le résumé devient le verso")

// Le corps envoyé à AnkiConnect.
let payload = exerciseNote.payload
if let note = payload["note"] as? [String: Any] {
    check(note["deckName"] as? String == "StudyTrack", "le corps porte le paquet")
    check(note["fields"] != nil, "…les champs")
    check((note["options"] as? [String: Any])?["allowDuplicate"] as? Bool == false,
          "les doublons sont refusés : Anki le fait mieux que nous")
}

print("== Live Activity : le compteur ne repart pas de zéro ==")
// Le bogue : l'état portait `accumulated` **et** `runningSince`, et le compteur
// système n'affichait que le second. Après une pause, il repartait de zéro —
// « 00:01 » au lieu d'une heure de travail.
let activityNow = Date(timeIntervalSince1970: 1_700_000_000)

let running = ActivityTimerState.make(elapsed: 600, running: true, now: activityNow)
check(running.isRunning, "un chrono qui tourne est marqué en cours")
check(running.elapsed(at: activityNow) == 600,
      "…et affiche le total accumulé, pas zéro — \(Int(running.elapsed(at: activityNow))) s")
check(running.elapsed(at: activityNow.addingTimeInterval(60)) == 660,
      "…et il continue d'avancer")
check(abs((running.countingSince ?? activityNow).timeIntervalSince(activityNow) + 600) < 0.001,
      "l'instant de départ est reculé du total déjà écoulé")

// Le cas exact du rapport : reprendre après une pause d'une heure de travail.
let resumed = ActivityTimerState.make(elapsed: 3600, running: true, now: activityNow)
check(resumed.elapsed(at: activityNow) == 3600,
      "reprendre après 1 h affiche 1 h, pas 00:01 — \(Int(resumed.elapsed(at: activityNow))) s")
check(resumed.elapsed(at: activityNow.addingTimeInterval(2)) == 3602,
      "…et deux secondes plus tard, 1 h 00 min 02")

let paused = ActivityTimerState.make(elapsed: 600, running: false, now: activityNow)
check(!paused.isRunning, "en pause, le chrono n'est pas marqué en cours")
check(paused.countingSince == nil, "…et rien ne s'écoule")
check(paused.elapsed(at: activityNow.addingTimeInterval(300)) == 600,
      "…le total reste figé même cinq minutes plus tard")
check(paused.frozenTotal == 600, "le total figé est conservé")

let zero = ActivityTimerState.make(elapsed: 0, running: true, now: activityNow)
check(zero.elapsed(at: activityNow) == 0, "un chrono neuf part de zéro")
let negative = ActivityTimerState.make(elapsed: -50, running: false, now: activityNow)
check(negative.frozenTotal == 0, "un total négatif est ramené à zéro")

print("== Live Activity : sous-questions et anneau Pomodoro ==")
// Les champs ajoutés sont `Optional` pour deux raisons, toutes deux testées ici :
// une activité publiée par une version précédente doit se décoder, et « pas de
// sous-questions » ne doit pas se confondre avec « zéro sur zéro ».
let bare = ActivityTimerState.make(elapsed: 120, running: true, now: activityNow)
check(bare.questionsLabel == nil, "sans cible, aucun compte de sous-questions")
check(!bare.hasNextQuestion, "…et donc pas de bouton « question suivante »")
check(bare.questionsProgress == nil, "…ni de barre de progression")

let withQuestions = ActivityTimerState.make(elapsed: 120, running: true,
                                            questionsDone: 3, questionsTotal: 9,
                                            now: activityNow)
check(withQuestions.questionsLabel == "3/9", "trois sur neuf — \(withQuestions.questionsLabel ?? "nil")")
check(withQuestions.hasNextQuestion, "il reste des questions à cocher")
check(abs((withQuestions.questionsProgress ?? 0) - 1.0 / 3) < 0.001, "un tiers fait")

let finished = ActivityTimerState.make(elapsed: 120, running: true,
                                       questionsDone: 9, questionsTotal: 9,
                                       now: activityNow)
check(!finished.hasNextQuestion, "tout coché : plus de question suivante")
check(finished.questionsLabel == "9/9", "…mais le compte reste affiché")

let single = ActivityTimerState.make(elapsed: 120, running: true,
                                     questionsDone: 0, questionsTotal: 1,
                                     now: activityNow)
check(single.questionsLabel == nil,
      "une cible à une seule case n'affiche pas « 0/1 » : le bouton « fait » le dit déjà")
check(single.hasNextQuestion, "…elle garde pourtant sa question suivante")

// Décodage d'une activité écrite **avant** ces champs : le contrat de compatibilité.
let legacyJSON = #"{"countingSince":"2023-11-14T22:13:20Z","frozenTotal":600}"#
let legacyDecoder = JSONDecoder()
legacyDecoder.dateDecodingStrategy = .iso8601
if let data = legacyJSON.data(using: .utf8),
   let legacy = try? legacyDecoder.decode(ActivityTimerState.self, from: data) {
    check(legacy.frozenTotal == 600, "un état d'avant les sous-questions se décode encore")
    check(legacy.questionsTotal == nil, "…et ses champs absents valent nil")
    check(legacy.pomodoro == nil, "…y compris le bloc Pomodoro")
} else {
    check(false, "un état d'avant les sous-questions doit se décoder")
}

// L'anneau : les bornes en horloge murale sont ce que le système sait animer.
let ring = ActivityPomodoro.make(blockNumber: 1, elapsedInBlock: 600, remaining: 900,
                                 completedBlocks: 0, running: true, now: activityNow)
check(ring.startedAt == activityNow.addingTimeInterval(-600),
      "le bloc a commencé il y a dix minutes de travail")
check(ring.endsAt == activityNow.addingTimeInterval(900), "…et se termine dans quinze")
check(ring.interval != nil, "l'anneau a un intervalle à animer")
check(abs(ring.frozenProgress - 0.4) < 0.001, "40 % du bloc")
check(ring.label == "Bloc 1", "libellé du bloc")

let pausedRing = ActivityPomodoro.make(blockNumber: 2, elapsedInBlock: 300, remaining: 1200,
                                       completedBlocks: 1, running: false, now: activityNow)
check(pausedRing.interval == nil,
      "en pause, aucun intervalle : un anneau qui continue de se remplir mentirait")
check(abs(pausedRing.frozenProgress - 0.2) < 0.001, "…mais la part faite reste connue")
check(pausedRing.completedBlocks == 1, "un bloc déjà terminé")

let completeRing = ActivityPomodoro.make(blockNumber: 1, elapsedInBlock: 1500, remaining: 0,
                                         completedBlocks: 1, running: true, now: activityNow)
check(completeRing.isBlockComplete, "un bloc à terme est marqué terminé")
check(completeRing.interval == nil, "…et n'anime plus rien : l'intervalle serait vide")

// Le pont entre le moteur et l'anneau : ce que l'app fera réellement.
let engineStatus = PomodoroEngine.status(elapsed: 1500 * 2 + 600, focusMinutes: 25)
let fromEngine = ActivityPomodoro.make(blockNumber: engineStatus.blockNumber,
                                       elapsedInBlock: engineStatus.elapsedInBlock,
                                       remaining: engineStatus.remaining,
                                       completedBlocks: engineStatus.completedBlocks,
                                       running: true, now: activityNow)
check(fromEngine.blockNumber == 3, "le moteur donne le bloc 3, l'anneau le reprend")
check(fromEngine.completedBlocks == 2, "…et ses deux blocs terminés")
check(abs(fromEngine.frozenProgress - engineStatus.progress) < 0.001,
      "…sans changer la fraction que le moteur a calculée")

print("== Live Activity : le jour d'examen ==")
// L'activité d'examen n'est déclenchée par aucun geste : elle s'ouvre et se ferme
// **par le temps**. C'est donc la seule chose qui puisse se tromper, et elle est
// ici entièrement testable.
let examAt = Date(timeIntervalSince1970: 1_700_000_000)

check(ExamActivityState.phase(examDate: examAt, now: examAt.addingTimeInterval(-3600)) == .upcoming,
      "une heure avant, l'épreuve est à venir")
check(ExamActivityState.phase(examDate: examAt, now: examAt) == .running,
      "à l'heure pile, l'épreuve est en cours")
check(ExamActivityState.phase(examDate: examAt, now: examAt.addingTimeInterval(3600)) == .running,
      "une heure après le début, toujours en cours")
check(ExamActivityState.phase(examDate: examAt,
                              now: examAt.addingTimeInterval(ExamActivityState.assumedDuration + 1)) == .over,
      "passé la durée supposée, l'épreuve est terminée")

// La fenêtre d'affichage : ni trop tôt — un compte à rebours de trois jours est
// une pression, pas une information — ni après coup.
check(!ExamActivityState.isRelevant(examDate: examAt, now: examAt.addingTimeInterval(-3 * 86400)),
      "trois jours avant, aucune activité")
check(!ExamActivityState.isRelevant(examDate: examAt,
                                    now: examAt.addingTimeInterval(-ExamActivityState.lead - 60)),
      "juste avant la fenêtre, toujours rien")
check(ExamActivityState.isRelevant(examDate: examAt,
                                   now: examAt.addingTimeInterval(-ExamActivityState.lead + 60)),
      "dans les douze heures, l'activité s'affiche")
check(ExamActivityState.isRelevant(examDate: examAt, now: examAt.addingTimeInterval(-1800)),
      "une demi-heure avant, elle est là")
check(ExamActivityState.isRelevant(examDate: examAt, now: examAt.addingTimeInterval(1800)),
      "pendant l'épreuve, elle reste")
check(!ExamActivityState.isRelevant(examDate: examAt,
                                    now: examAt.addingTimeInterval(ExamActivityState.assumedDuration + 60)),
      "après l'épreuve, elle disparaît — c'est ce qui laissait un îlot mort à l'écran")

check(ExamActivityState.make(examDate: examAt, now: examAt.addingTimeInterval(-600)).phase == .upcoming,
      "l'état publié reprend la phase déduite")

print("== Pomodoro ==")
check(PomodoroEngine.blockDuration(minutes: 25) == 1500, "25 min = 1500 s")
check(PomodoroEngine.blockDuration(minutes: 0) == 60,
      "un bloc nul est borné à une minute — sinon la boucle d'alerte ne s'arrête jamais")
check(PomodoroEngine.blockDuration(minutes: -10) == 60, "un bloc négatif est borné aussi")

let start = PomodoroEngine.status(elapsed: 0, focusMinutes: 25)
check(start.blockNumber == 1, "au départ, bloc 1")
check(start.elapsedInBlock == 0, "rien d'écoulé dans le bloc")
check(start.remaining == 1500, "25 min restantes")
check(start.progress == 0, "anneau à zéro")
check(!start.isBlockComplete, "bloc non terminé")

let midway = PomodoroEngine.status(elapsed: 600, focusMinutes: 25)
check(midway.blockNumber == 1, "10 min plus tard, toujours bloc 1")
check(midway.remaining == 900, "15 min restantes — \(Int(midway.remaining)) s")
check(abs(midway.progress - 0.4) < 0.001, "anneau à 40 % — \(String(format: "%.2f", midway.progress))")

// L'instant exact où la pause est due : c'est le cas qui compte.
let exactly = PomodoroEngine.status(elapsed: 1500, focusMinutes: 25)
check(exactly.isBlockComplete, "à 25 min pile, le bloc est terminé")
check(exactly.blockNumber == 1, "…et on est encore sur le bloc 1, pas déjà le 2")
check(exactly.completedBlocks == 1, "un bloc terminé")
check(exactly.progress == 1, "anneau plein")

let second = PomodoroEngine.status(elapsed: 1501, focusMinutes: 25)
check(second.blockNumber == 2, "une seconde plus tard, bloc 2")
check(second.completedBlocks == 1, "toujours un bloc terminé")
check(second.remaining == 1499, "le nouveau bloc vient de commencer")

let third = PomodoroEngine.status(elapsed: 1500 * 2 + 60, focusMinutes: 25)
check(third.blockNumber == 3, "après deux blocs et une minute, bloc 3")
check(third.completedBlocks == 2, "deux blocs terminés")
check(third.remaining == 1440, "24 min restantes")
check(third.label == "Bloc 3", "libellé du bloc")

check(PomodoroEngine.status(elapsed: -5, focusMinutes: 25).blockNumber == 1,
      "un temps négatif ne produit pas un bloc négatif")
check(PomodoroEngine.blocksRemaining(elapsed: 1500, targetBlocks: 4, focusMinutes: 25) == 3,
      "trois blocs restants sur un objectif de quatre")
check(PomodoroEngine.blocksRemaining(elapsed: 1500 * 5, targetBlocks: 4, focusMinutes: 25) == 0,
      "un objectif dépassé ne donne pas de blocs négatifs")

print("== Raccourcis du chrono ==")
let defaultShortcuts = FocusShortcutDefaults.make(from: ["CS-250", "MATH-101"])
check(defaultShortcuts.count == 4, "deux cours × deux natures = quatre raccourcis (\(defaultShortcuts.count))")
check(defaultShortcuts.first?.courseCode == "CS-250", "l'ordre des cours est conservé")
check(defaultShortcuts.first?.taskType == .video, "la vidéo vient en premier")
check(defaultShortcuts[1].taskType == .exercise, "puis les exercices")

let manyCourses = (1...10).map { "C-\($0)" }
check(FocusShortcutDefaults.make(from: manyCourses).count == FocusShortcutDefaults.maxDefaults,
      "la proposition est plafonnée à \(FocusShortcutDefaults.maxDefaults)")

// Un cours supprimé ne doit pas laisser une tuile morte.
let prunedShortcuts = FocusShortcutDefaults.sanitize(
    [FocusShortcut(courseCode: "CS-250", taskType: .video),
     FocusShortcut(courseCode: "DISPARU-1", taskType: .video),
     FocusShortcut(courseCode: "CS-250", taskType: .video),
     FocusShortcut(courseCode: "CS-250", taskType: .exercise)],
    knownCourses: ["CS-250"])
check(prunedShortcuts.count == 2, "cours disparu retiré et doublon supprimé (\(prunedShortcuts.count))")
check(prunedShortcuts.map(\.taskType) == [.video, .exercise], "l'ordre est préservé")
check(FocusShortcutDefaults.sanitize([], knownCourses: []).isEmpty, "une liste vide reste vide")

// Aller-retour JSON : c'est ainsi que les raccourcis sont conservés.
let encoded = FocusShortcut.encode(defaultShortcuts)
check(FocusShortcut.decode(encoded) == defaultShortcuts, "les raccourcis survivent à l'encodage")
check(FocusShortcut.decode("pas du json").isEmpty, "un contenu illisible ne plante pas")
check(FocusShortcut.decode("").isEmpty, "un contenu vide ne plante pas")
check(FocusShortcut(courseCode: "CS-250", taskType: .video).id == "CS-250|video",
      "l'identifiant est stable — \(FocusShortcut(courseCode: "CS-250", taskType: .video).id)")

print("== Schéma versionné ==")
// Le schéma de l'app doit contenir **exactement** les modèles déclarés dans les
// sources. C'est l'oubli qui avait laissé `GroupItemCompletion` hors du conteneur.
let schemaModelNames = Set(SchemaV1.models.map { String(describing: $0) })
let declared = Set(declaredModelNames)
let missingFromSchema = declared.subtracting(schemaModelNames)
let unknownInSchema = schemaModelNames.subtracting(declared)
check(missingFromSchema.isEmpty,
      "aucun @Model oublié dans SchemaV1 — manquants : \(missingFromSchema.sorted())")
check(unknownInSchema.isEmpty,
      "aucun modèle fantôme dans SchemaV1 — en trop : \(unknownInSchema.sorted())")
check(schemaModelNames.count == declared.count,
      "\(declared.count) modèles déclarés, \(schemaModelNames.count) dans le schéma")
check(SchemaV1.versionIdentifier == Schema.Version(1, 0, 0), "version 1.0.0")
check(StudyTrackSchema.currentVersion == 1, "version courante cohérente")
check(StudyTrackMigrationPlan.schemas.count == 1,
      "le plan connaît la version en cours (\(StudyTrackMigrationPlan.schemas.count))")
check(StudyTrackMigrationPlan.stages.isEmpty || !StudyTrackMigrationPlan.stages.isEmpty,
      "le plan de migration est interrogeable")

// La liste des modèles déclarés n'est pas vide : un garde-fou qui ne compare rien
// ne garde rien.
check(!declared.isEmpty, "la liste générée depuis les sources n'est pas vide")
check(declared.contains("Course") && declared.contains("AcademicMilestone"),
      "elle contient bien les modèles attendus")

print("== Recherche globale ==")
// La recherche doit trouver ce que l'utilisateur **tape**, pas ce qu'il a écrit.
check(SearchEngine.normalize("Algèbre linéaire") == "algebre lineaire",
      "accents et casse neutralisés — « \(SearchEngine.normalize("Algèbre linéaire")) »")
check(SearchEngine.normalize("CS-250") == "cs 250", "ponctuation réduite à un espace")
check(SearchEngine.normalize("  trop   d'espaces  ") == "trop d espaces", "espaces normalisés")
check(SearchEngine.tokens("algo exo") == ["algo", "exo"], "mots séparés")
check(SearchEngine.search("", in: []).isEmpty, "requête vide : aucun résultat")
check(SearchEngine.search("   ", in: []).isEmpty, "requête blanche : aucun résultat")

let catalogue: [SearchDocument] = [
    SearchDocument(id: "course.1", kind: .course, title: "Algorithms I",
                   subtitle: "CS-250 · 6 crédits", detail: "algorithms i cs 250 cs250",
                   courseCode: "CS-250"),
    SearchDocument(id: "course.2", kind: .course, title: "Analyse I",
                   subtitle: "MATH-101 · 7 crédits", detail: "analyse i math 101 math101",
                   courseCode: "MATH-101"),
    SearchDocument(id: "exercise.1", kind: .exercise, title: "Exercice 3.2 — Tri fusion",
                   subtitle: "CS-250 · Série 3", detail: "exercice 3 2 tri fusion algo recursif",
                   courseCode: "CS-250", date: Date()),
    SearchDocument(id: "theory.1", kind: .theory, title: "Analyse asymptotique",
                   subtitle: "CS-250 · Vidéo 1.2", detail: "video 1 2 complexite grand o",
                   courseCode: "CS-250"),
    SearchDocument(id: "session.1", kind: .session, title: "Révision récurrences",
                   subtitle: "CS-250 · Exercices", detail: "revision recurrences exercices",
                   courseCode: "CS-250", date: Date()),
    SearchDocument(id: "milestone.1", kind: .milestone, title: "Fin des examens",
                   subtitle: "Fin des examens · 30 janv.", detail: "fin des examens")
]

// Trouver par intitulé.
let algoHits = SearchEngine.search("algorithms", in: catalogue)
check(algoHits.first?.document.id == "course.1", "le cours sort en premier")
check(algoHits.first?.match == .title, "…et la correspondance est annoncée comme un intitulé")

// Sans accent ni casse.
check(SearchEngine.search("ANALYSE", in: catalogue).contains { $0.document.id == "course.2" },
      "recherche insensible aux accents et à la casse")
check(SearchEngine.search("asymptotique", in: catalogue).first?.document.id == "theory.1",
      "un titre de théorie se trouve")

// Par code de cours, sous ses trois écritures.
for written in ["CS-250", "cs250", "cs 250"] {
    let found = SearchEngine.search(written, in: catalogue)
    check(found.contains { $0.document.id == "exercise.1" },
          "« \(written) » trouve les exercices du cours")
}
check(SearchEngine.search("cs250", in: catalogue).contains { $0.document.id == "theory.1" },
      "…et la théorie du même cours")

// Tous les mots doivent correspondre : c'est ce qui rend la recherche utile.
let bothWords = SearchEngine.search("tri fusion", in: catalogue)
check(bothWords.count == 1 && bothWords.first?.document.id == "exercise.1",
      "deux mots : seul le document qui contient les deux sort (\(bothWords.count))")
check(SearchEngine.search("tri banane", in: catalogue).isEmpty,
      "un mot absent disqualifie le document")
check(SearchEngine.search("algo cours", in: catalogue).isEmpty,
      "« algo » ne suffit pas si le second mot n'existe nulle part")

// Un mot du détail suffit, mais l'intitulé passe devant.
let detailHit = SearchEngine.search("recursif", in: catalogue)
check(detailHit.first?.document.id == "exercise.1", "un mot du détail trouve le document")
check(detailHit.first?.match == .detail, "…et la correspondance est annoncée comme un détail")

// Le code de cours est un cas intermédiaire, annoncé comme tel.
let codeOnly = SearchEngine.search("math101", in: catalogue)
check(codeOnly.first?.match == .course, "correspondance par code annoncée comme telle")

// À score égal, l'ordre des natures est stable : cours, puis exercice.
let broad = SearchEngine.search("cs", in: catalogue)
check(broad.first?.kind == .course, "à pertinence comparable, un cours passe avant un exercice")
check(broad == broad.sorted { lhs, rhs in
    lhs.score != rhs.score ? lhs.score > rhs.score : lhs.kind <= rhs.kind
} || broad.count < 2, "le tri est déterministe")

// Groupement et résumé.
let grouped = SearchEngine.grouped(algoHits)
check(grouped.count == 1 && grouped.first?.kind == .course, "regroupement par nature")
check(SearchEngine.summary([], query: "").contains("Tape un code"),
      "sans requête, l'écran explique quoi taper")
check(SearchEngine.summary([], query: "zzz").contains("zzz"), "sans résultat, la requête est citée")
check(SearchEngine.summary(algoHits, query: "algorithms").contains("1 résultat"),
      "avec résultats, le compte est annoncé")

// Le plafond : au-delà, la liste cesse d'aider.
let many = (0..<200).map { index in
    SearchDocument(id: "x.\(index)", kind: .exercise, title: "Exercice \(index) trigonométrie",
                   detail: "trigonometrie")
}
check(SearchEngine.search("trigonometrie", in: many).count == SearchEngine.limit,
      "les résultats sont plafonnés à \(SearchEngine.limit)")

// ── Index construit depuis les modèles ──────────────────────────────────────
if let indexCourse = courses.first(where: { $0.code == "CS-250" }) {
    let documents = SearchIndexBuilder.documents(courses: [indexCourse])
    check(documents.contains { $0.kind == .course }, "le cours est indexé")
    check(documents.contains { $0.kind == .series }, "ses séries sont indexées")
    check(documents.contains { $0.kind == .exercise }, "ses exercices sont indexés")
    check(documents.contains { $0.kind == .theory }, "sa théorie est indexée")
    check(documents.contains { $0.kind == .exam }, "ses évaluations sont indexées")
    check(documents.count > 10, "l'index est fourni (\(documents.count) documents pour un cours)")

    // Le code du cours se retrouve sous ses deux écritures.
    let codeHit = SearchEngine.search("cs250", in: documents)
    check(!codeHit.isEmpty, "« cs250 » trouve le cours et son contenu (\(codeHit.count) résultats)")

    // Chercher un titre réel du cours d'exemple.
    if let series = indexCourse.sortedSeries.first {
        let found = SearchEngine.search("serie \(series.seriesNumber)", in: documents)
        check(found.contains { $0.kind == .series || $0.kind == .exercise },
              "une série se retrouve par son numéro")
    }
    check(SearchEngine.search("zzzzintrouvable", in: documents).isEmpty,
          "un mot absent ne ramène rien")
}

// Groupes et échéances sont indexables aussi.
let nonCourseDocuments = SearchIndexBuilder.documents(courses: [],
                                                     milestones: [builderMilestone],
                                                     groups: [])
check(nonCourseDocuments.contains { $0.kind == .milestone },
      "les échéances de l'EPFL sont cherchables")
check(SearchEngine.search("examen", in: nonCourseDocuments).contains { $0.kind == .milestone },
      "…et se trouvent par leur intitulé")

print("== Calendrier académique de l'EPFL : lecture de la vraie page ==")
// Le HTML est un extrait **authentique** de la page publique : c'est ce qui rend
// ce test utile. Un parseur testé sur une structure inventée ne prouve rien.
let epflHTML = """
<p><strong>Semestre automne 26-27</strong></p>
<table><tbody>
<tr><td>Fin juillet 2026</td><td><a href="x">Publication de l&#8217;horaire du semestre</a></td></tr>
<tr><td>1 ao&#251;t 2026</td><td>F&#234;te nationale (jour f&#233;ri&#233;)</td></tr>
<tr><td><strong>7 septembre 2026</strong></td><td><strong>D&#233;but des enseignements</strong></td></tr>
<tr><td>21 septembre 2026</td><td>Lundi du Je&#251;ne f&#233;d&#233;ral (jour f&#233;ri&#233;)</td></tr>
<tr><td>16 octobre 2026</td><td>Interruption des enseignements (fin de journ&#233;e)</td></tr>
<tr><td>26 octobre 2026</td><td>Reprise des enseignements</td></tr>
<tr><td>Mi-novembre 2026</td><td>Publication de l&#8217;horaire des examens</td></tr>
<tr><td>20 novembre 2026</td><td><a href="y">D&#233;lai pour le&nbsp;retrait des examens</a></td></tr>
<tr><td>18 d&#233;cembre 2026</td><td>Fin des enseignements</td></tr>
<tr><td>11 janvier 2027</td><td>D&#233;but des examens</td></tr>
<tr><td>30 janvier 2027</td><td>Fin des examens</td></tr>
</tbody></table>
<p><strong>Semestre printemps 25-26</strong></p>
<table><tbody>
<tr><td><strong>16 f&#233;vrier 2026</strong></td><td><strong>D&#233;but des enseignements (sauf mise &#224; niveau)</strong></td></tr>
<tr><td>3 avril 2026</td><td>Vendredi saint (jour f&#233;ri&#233;)</td></tr>
<tr><td><strong>4 juillet 2026</strong></td><td><strong>Fin des examens</strong></td></tr>
</tbody></table>
"""
let parsedCalendar = AcademicCalendarParser.parse(html: epflHTML)
check(parsedCalendar.count == 14, "14 lignes lues sur la page (\(parsedCalendar.count))")
check(parsedCalendar.allSatisfy { $0.date >= Date(timeIntervalSince1970: 0) },
      "chaque échéance porte une date")

/// Les deux semestres contiennent un « Début des enseignements » : on cible
/// celui d'automne, comme le ferait l'écran pour le semestre en cours.
func milestone(_ title: String, in term: String = "automne") -> AcademicMilestoneValue? {
    parsedCalendar.first { $0.title.contains(title) && $0.termLabel.contains(term) }
}
check(milestone("Début des enseignements")?.title.contains("mise à niveau") == false,
      "« Début des enseignements » de l'automne est lu — \(milestone("Début des enseignements")?.title ?? "-")")
check(milestone("Début des enseignements")?.termLabel == "Semestre automne 26-27",
      "…rattaché à son semestre — \(milestone("Début des enseignements")?.termLabel ?? "-")")
check(milestone("Début des enseignements")?.kind == .teachingStart, "…classé comme début des cours")
check(milestone("Début des enseignements")?.isImportant == true,
      "…et marqué important, comme l'EPFL le fait")

// La date qui commande toute l'app.
let epflAutumn2026 = AcademicCalendarParser.parseDate("7 septembre 2026")
let epflCalendar = Calendar(identifier: .gregorian)
check(epflAutumn2026 != nil, "« 7 septembre 2026 » est lue")
if let epflAutumn2026 {
    let parts = epflCalendar.dateComponents([.year, .month, .day, .weekday], from: epflAutumn2026.date)
    check(parts.year == 2026 && parts.month == 9 && parts.day == 7,
          "…au 7 septembre 2026 (\(parts.day ?? -1)/\(parts.month ?? -1)/\(parts.year ?? -1))")
    check(parts.weekday == 2, "…qui est bien un lundi")
    check(epflAutumn2026.approximate == false, "…comme date exacte")
}
check(DateUtils.autumnStart(forYear: 2026) == epflAutumn2026?.date,
      "la règle de rentrée et la page de l'EPFL donnent la même date")

// Les dates approximatives : l'EPFL ne donne pas de jour, on le dit.
let midNovember = AcademicCalendarParser.parseDate("Mi-novembre 2026")
check(midNovember?.approximate == true, "« Mi-novembre » est marquée approximative")
check(epflCalendar.component(.day, from: midNovember?.date ?? Date()) == 15,
      "…au 15 du mois — \(midNovember.map { epflCalendar.component(.day, from: $0.date) } ?? -1)")
let endDecember = AcademicCalendarParser.parseDate("Fin décembre 2025")
check(epflCalendar.component(.day, from: endDecember?.date ?? Date()) == 31,
      "« Fin décembre » au dernier jour du mois — \(endDecember.map { epflCalendar.component(.day, from: $0.date) } ?? -1)")
let earlyMarch = AcademicCalendarParser.parseDate("Début mars 2026")
check(epflCalendar.component(.day, from: earlyMarch?.date ?? Date()) == 1, "« Début mars » au 1er")
check(AcademicCalendarParser.parseDate("Fin février 2027").map {
    epflCalendar.component(.day, from: $0.date)
} == 28, "février 2027 n'est pas bissextile : 28")
check(AcademicCalendarParser.parseDate("Fin février 2028").map {
    epflCalendar.component(.day, from: $0.date)
} == 29, "février 2028 est bissextile : 29")
check(AcademicCalendarParser.parseDate("pas une date") == nil, "un texte sans date ne produit rien")
check(AcademicCalendarParser.parseDate("") == nil, "une cellule vide ne produit rien")

// Classification.
check(AcademicCalendarParser.kind(for: "Vendredi saint (jour férié)") == .holiday, "jour férié reconnu")
check(AcademicCalendarParser.kind(for: "Interruption des enseignements (fin de journée)") == .break,
      "interruption reconnue")
check(AcademicCalendarParser.kind(for: "Délai pour le retrait des examens") == .deadline, "délai reconnu")
check(AcademicCalendarParser.kind(for: "Ouverture des inscriptions anticipées") == .opening,
      "ouverture reconnue")
check(AcademicCalendarParser.kind(for: "Fin des examens") == .examEnd, "fin des examens reconnue")
check(AcademicCalendarParser.kind(for: "Envoi des bulletins de notes") == .publication,
      "envoi de bulletins classé en publication")
check(AcademicCalendarParser.kind(for: "Autre chose") == .other, "l'inconnu ne force pas une nature")

// HTML : sans les balises ni les entités.
check(AcademicCalendarParser.plainText("<td>D&#233;lai pour le&nbsp;retrait</td>")
        == "Délai pour le retrait",
      "balises et entités retirées — « \(AcademicCalendarParser.plainText("<td>D&#233;lai pour le&nbsp;retrait</td>")) »")
check(AcademicCalendarParser.plainText("<a href=\"x\">Deux <strong>mots</strong></a>") == "Deux mots",
      "balises imbriquées retirées")
check(AcademicCalendarParser.plainText("<td>   espaces   multiples  </td>") == "espaces multiples",
      "espaces normalisés")

// Clé stable : deux lectures de la même page ne doivent pas dupliquer.
let idsFirst = Set(AcademicCalendarParser.parse(html: epflHTML).map(\.id))
let idsAgain = Set(AcademicCalendarParser.parse(html: epflHTML).map(\.id))
check(idsFirst == idsAgain && idsFirst.count == 14,
      "les identifiants sont stables d'une lecture à l'autre (\(idsFirst.count))")

// ── Instantané embarqué ─────────────────────────────────────────────────────
let snapshot = EPFLCalendarSnapshot.milestones()
check(snapshot.count == 71, "instantané embarqué : 71 échéances (\(snapshot.count))")
check(snapshot.allSatisfy { $0.id.hasPrefix("epfl.") }, "chaque échéance porte une clé EPFL")
check(snapshot == snapshot.sorted { $0.date < $1.date }, "l'instantané est chronologique")
check(!snapshot.isEmpty, "l'instantané n'est pas vide")

// Les quatre bornes du semestre d'automne 2026-2027, vérifiables à la main.
func snapshotDate(_ title: String, in term: String? = nil) -> Date? {
    snapshot.first { value in
        value.title == title && (term == nil || value.termLabel.contains(term!))
    }?.date
}
func day(_ date: Date?) -> String {
    guard let date else { return "—" }
    return DateUtils.shortDay.string(from: date)
}
check(day(snapshotDate("Début des enseignements", in: "automne 26-27")) == "lun. 7 sept.",
      "automne 2026 : début des cours le 7 septembre — \(day(snapshotDate("Début des enseignements")))")
check(day(snapshotDate("Fin des enseignements", in: "automne 26-27")) == "ven. 18 déc.",
      "…fin des cours le 18 décembre — \(day(snapshotDate("Fin des enseignements")))")
check(day(snapshotDate("Début des examens", in: "automne 26-27")) == "lun. 11 janv.",
      "…début des examens le 11 janvier — \(day(snapshotDate("Début des examens")))")
check(day(snapshotDate("Fin des examens", in: "automne 26-27")) == "sam. 30 janv.",
      "…fin des examens le 30 janvier — \(day(snapshotDate("Fin des examens")))")

check(EPFLCalendarSnapshot.autumnTeachingStart(year: 2026) == epflAutumn2026?.date,
      "le début d'automne est extractible de l'instantané")
check(EPFLCalendarSnapshot.autumnTeachingStart(year: 2025) == nil,
      "une année non publiée ne rend pas de date inventée")

check(snapshot.contains { $0.kind == .holiday }, "l'instantané contient les jours fériés")
check(snapshot.contains { $0.kind == .deadline }, "…et les délais")
check(snapshot.filter(\.isApproximate).count == 13,
      "13 échéances approximatives, signalées comme telles (\(snapshot.filter(\.isApproximate).count))")

print("== Couverture du suivi : qu'est-ce qui échappe à l'app ? ==")
// Un cours modèle, volontairement sain : tout est là, rien à signaler.
func healthyCourse(code: String = "OK-100") -> CourseCoverageInput {
    CourseCoverageInput(code: code, name: "Cours modèle", isTracked: true, hasTerm: true,
                        hasLectures: true, currentWeek: 5, termWeeks: 14,
                        theoryCount: 8, theoryWithoutDuration: 0, theoryWatchedNotSummarized: 0,
                        seriesNumbersWithNoExercise: [], overdueSeries: [], misplannedSeries: [],
                        exerciseCount: 20, notDoneExerciseCount: 4,
                        doneNotCorrectedCount: 0, toRedoCount: 0,
                        examCount: 1, upcomingExamCount: 1)
}
check(CoverageEngine.audit(healthyCourse()).isHealthy,
      "un cours complet ne produit aucun manque")
check(CoverageEngine.audit(healthyCourse()).findings.isEmpty,
      "…et exactement aucun constat")

// Un cours archivé n'a pas à être complet : il n'est plus suivi.
var archived = healthyCourse(code: "OLD-100")
archived.isTracked = false
archived.theoryCount = 0
archived.examCount = 0
check(CoverageEngine.audit(archived).findings.isEmpty,
      "un cours archivé n'est pas audité")
check(CoverageEngine.audit(archived).isTracked == false, "…et reste distinguable")

// Chaque famille de manque, isolément.
var noTerm = healthyCourse(); noTerm.hasTerm = false
check(CoverageEngine.audit(noTerm).blocking.contains { $0.category == .foundation },
      "cours sans semestre = manque bloquant")

var empty = healthyCourse(); empty.theoryCount = 0; empty.exerciseCount = 0
check(CoverageEngine.audit(empty).blocking.contains { $0.title.contains("vide") },
      "cours sans aucun contenu = manque bloquant")
check(CoverageEngine.audit(empty).blocking.allSatisfy { !$0.title.contains("OK-100") },
      "le titre du constat ne porte pas le code : l'écran l'affiche à part")
check(CoverageEngine.audit(empty).blocking.allSatisfy { $0.courseCode == "OK-100" },
      "…mais le constat sait de quel cours il parle")

var emptySeries = healthyCourse(); emptySeries.seriesNumbersWithNoExercise = [3, 4]
let emptySeriesFindings = CoverageEngine.audit(emptySeries).findings
check(emptySeriesFindings.contains { $0.category == .content && $0.title.contains("2 séries") },
      "séries sans exercice signalées — \(emptySeriesFindings.first { $0.category == .content }?.title ?? "-")")

var overdue = healthyCourse(); overdue.overdueSeries = [3]
check(CoverageEngine.audit(overdue).warnings.contains { $0.category == .planning },
      "série en retard = avertissement de planification")

var misplanned = healthyCourse(); misplanned.misplannedSeries = [22]
check(CoverageEngine.audit(misplanned).findings.contains { $0.category == .planning && $0.severity == .info },
      "série planifiée hors semestre = remarque, pas un défaut")

var notCorrected = healthyCourse(); notCorrected.doneNotCorrectedCount = 7
check(CoverageEngine.audit(notCorrected).warnings.contains { $0.category == .correction },
      "exercices faits non corrigés = incomplet")

var toRedo = healthyCourse(); toRedo.toRedoCount = 2
check(CoverageEngine.audit(toRedo).warnings.contains { $0.category == .correction },
      "exercices à refaire = incomplet")

var noExam = healthyCourse(); noExam.examCount = 0; noExam.upcomingExamCount = 0
check(CoverageEngine.audit(noExam).warnings.contains { $0.category == .exams },
      "cours sans évaluation = incomplet")

var pastExams = healthyCourse(); pastExams.upcomingExamCount = 0
let pastFindings = CoverageEngine.audit(pastExams).findings
check(pastFindings.contains { $0.category == .exams && $0.severity == .info },
      "évaluations toutes passées = remarque, pas un défaut")

var unwatched = healthyCourse()
unwatched.theoryWatchedNotSummarized = 3
unwatched.theoryWithoutDuration = 2
let theoryFindings = CoverageEngine.audit(unwatched).findings.filter { $0.category == .theory }
check(theoryFindings.count == 2, "les deux remarques de théorie sont distinctes (\(theoryFindings.count))")
check(theoryFindings.allSatisfy { $0.severity == .info },
      "…et aucune n'est comptée comme un manque réel")

// Le cours sain ne doit pas être « incomplet » : c'est tout l'intérêt du score.
check(CoverageEngine.audit(healthyCourse()).isHealthy,
      "les remarques de confort ne rendent pas un cours incomplet")

// ── Rapport global ──────────────────────────────────────────────────────────
let healthyReport = CoverageEngine.report(courses: [healthyCourse()],
                                          hasTerm: true, hasTimetable: true)
check(healthyReport.isComplete, "rapport complet quand tout est là")
check(healthyReport.coverage == 1, "couverture à 100 % — \(Int(healthyReport.coverage * 100)) %")
check(healthyReport.healthyCourses == 1, "un cours sain compté")

let noTermReport = CoverageEngine.report(courses: [healthyCourse()],
                                         hasTerm: false, hasTimetable: true)
check(noTermReport.globalFindings.contains { $0.severity == .blocking },
      "sans semestre, un manque bloquant est remonté au niveau global")
check(noTermReport.coverage == 1,
      "…sans artificiellement pénaliser les cours, qui n'y sont pour rien")

let noTimetableReport = CoverageEngine.report(courses: [healthyCourse()],
                                              hasTerm: true, hasTimetable: false)
check(noTimetableReport.globalFindings.contains { $0.id == "socle.horaire" },
      "sans horaire importé, une suggestion est proposée")
check(noTimetableReport.globalFindings.allSatisfy { $0.severity != .blocking },
      "…et ce n'est pas un manque bloquant")

let emptyReport = CoverageEngine.report(courses: [], hasTerm: true, hasTimetable: true)
check(emptyReport.coverage == 0, "sans cours suivi, la couverture est nulle sans division par zéro")
check(emptyReport.globalFindings.contains { $0.id == "socle.cours" }, "…et l'absence de cours est dite")

let mixedReport = CoverageEngine.report(courses: [healthyCourse(code: "A-100"),
                                                  healthyCourse(code: "B-100"),
                                                  noExam],
                                        hasTerm: true, hasTimetable: true)
check(mixedReport.trackedCount == 3, "trois cours suivis")
check(mixedReport.healthyCourses == 2, "deux cours sans manque (\(mixedReport.healthyCourses))")
check(abs(mixedReport.coverage - 2.0 / 3.0) < 0.001,
      "couverture = 2/3 — \(String(format: "%.3f", mixedReport.coverage))")
check(mixedReport.count(.warning) >= 1, "les avertissements sont comptés (\(mixedReport.count(.warning)))")
check(mixedReport.allFindings.first?.severity == .blocking
      || mixedReport.count(.blocking) == 0,
      "le tri met les manques bloquants en tête")
check(mixedReport.findings(in: .exams).count == 1, "regroupement par famille")

// ── Lecture des modèles ─────────────────────────────────────────────────────
let coverageCourse = courses.first { $0.code == "CS-250" }
if let coverageCourse {
    let input = CoverageBuilder.input(for: coverageCourse)
    check(input.code == coverageCourse.displayCode, "code lu depuis le modèle")
    check(input.hasTerm, "le cours d'exemple a bien un semestre")
    check(input.exerciseCount == coverageCourse.allExercises.count,
          "exercices comptés (\(input.exerciseCount))")
    check(input.examCount == coverageCourse.exams.count, "évaluations comptées (\(input.examCount))")
    check(input.doneNotCorrectedCount <= input.exerciseCount,
          "les exercices non corrigés forment un sous-ensemble des exercices")
    check(input.seriesNumbersWithNoExercise.count <= coverageCourse.series.count,
          "les séries vides forment un sous-ensemble des séries")
}
let modelReport = CoverageBuilder.report(courses: courses,
                                         term: AcademicTerm.resolve(from: [builderTerm]),
                                         hasTimetable: true)
check(modelReport.trackedCount == courses.filter(\.isTracked).count,
      "tous les cours suivis sont audités (\(modelReport.trackedCount))")
check(modelReport.courses.count == courses.count, "tous les cours sont représentés")

print("== Diagnostic des erreurs Supabase ==")
// Ce traducteur a menti deux fois : « politiques RLS » sans dire quelle table, et
// un message qui laissait croire qu'un simple réexécutable suffisait. On le teste
// donc sur les réponses **réelles** de PostgREST.
let rlsBody = #"{"code":"42501","message":"new row violates row-level security policy for table \"presence\"","details":null,"hint":null}"#
let rlsRaw = "Erreur serveur (403) : \(rlsBody)"
let rls = GroupErrorExplainer.explain(raw: rlsRaw)
check(rls.contains("membre du groupe"), "un 42501 oriente vers l'adhésion manquante")
check(rls.contains("presence"), "…et nomme la table refusée — \(rls.suffix(60))")
check(rls.contains("42501"), "…et conserve le code serveur")

let denied = GroupErrorExplainer.explain(
    raw: #"Erreur serveur (403) : {"code":"42501","message":"permission denied for table presence"}"#)
check(denied.contains("droits manquants"),
      "un « permission denied » est distingué d'une politique RLS — \(denied.prefix(50))")

let missing = GroupErrorExplainer.explain(
    raw: #"Erreur serveur (404) : {"code":"PGRST205","message":"Could not find the table 'public.presence' in the schema cache"}"#)
check(missing.contains("supabase-schema.sql"), "une table absente renvoie au fichier SQL")

let ambiguous = GroupErrorExplainer.explain(
    raw: #"Erreur serveur (300) : {"code":"PGRST201","message":"Could not embed because more than one relationship was found"}"#)
check(ambiguous.contains("deux chemins"), "une imbrication ambiguë est expliquée")

let fk = GroupErrorExplainer.explain(
    raw: #"Erreur serveur (409) : {"code":"23503","message":"insert or update on table violates foreign key constraint"}"#)
check(fk.contains("profil"), "une violation de clé étrangère renvoie au profil")

let unknownRaw = "Erreur serveur (500) : panne inconnue"
check(GroupErrorExplainer.explain(raw: unknownRaw) == unknownRaw,
      "une erreur non reconnue est rendue telle quelle, sans invention")

check(GroupErrorExplainer.serverDetail("pas de json ici").isEmpty,
      "sans JSON, aucun détail inventé")
check(GroupErrorExplainer.serverDetail(#"{"code":"X"}"#).contains("code X"),
      "un code seul est tout de même repris")
check(GroupErrorExplainer.serverDetail(#"{"message":""}"#).isEmpty,
      "un message vide ne produit pas de « Serveur : » orphelin")
check(GroupErrorExplainer.serverDetail(#"{"message":"boom","hint":"essaie ceci"}"#)
        .contains("essaie ceci"),
      "l'indication du serveur est conservée")

print("== Rôle : le créateur reste administrateur après migration ==")
// `roleRaw` est arrivé après `StudyGroup.isAdmin`. Pour un groupe créé avant,
// SwiftData a migré le nouvel attribut à sa valeur par défaut — « member » —
// y compris pour la personne qui avait créé le groupe. Elle se retrouvait sans
// droits sur son propre groupe.
let migratedGroup = StudyGroup(name: "Créé avant les rôles", isAdmin: true)
let migratedOwner = GroupMember(group: migratedGroup, userID: "me", displayName: "Moi",
                                isMe: true, role: .member)
check(migratedOwner.role == .member, "le rôle a bien migré à « member »")
check(migratedOwner.isAdmin, "…et le créateur reste administrateur malgré tout")

let joinedGroup = StudyGroup(name: "Rejoint", isAdmin: false)
let joiner = GroupMember(group: joinedGroup, userID: "me", displayName: "Moi",
                         isMe: true, role: .member)
check(!joiner.isAdmin, "celui qui a rejoint n'est pas administrateur")
joiner.role = .admin
check(joiner.isAdmin, "une promotion explicite prime sur le drapeau local")
joiner.role = .member
check(!joiner.isAdmin, "une rétrogradation aussi")

let otherGroup = StudyGroup(name: "Autre", isAdmin: true)
let someoneElse = GroupMember(group: otherGroup, userID: "u9", displayName: "Alice", role: .member)
check(!someoneElse.isAdmin, "le drapeau « admin » du groupe ne profite qu'à moi")

print("== Comparaison d'avancement entre membres ==")
let subjectReference = SubjectReference(seriesNumbers: [1, 2, 3],
                                        exerciseNumbers: ["1.1", "1.2", "1.3", "1.4"],
                                        theoryNumbers: ["1.1", "1.2"])
check(subjectReference.seriesTotal == 3
      && subjectReference.exerciseTotal == 4
      && subjectReference.theoryTotal == 2,
      "référentiel compté : 3 séries, 4 exercices, 2 théorie")
check(!subjectReference.isEmpty, "référentiel non vide")
check(SubjectReference().isEmpty, "référentiel vide détecté")

let subjectComparison = GroupProgressEngine.compare(
    subject: "cs-250",
    reference: subjectReference,
    contributions: [
        SubjectContribution(userID: "me",
                            seriesNumbers: [1, 2],
                            exerciseNumbers: ["1.1"],
                            theoryNumbers: ["1.1"]),
        SubjectContribution(userID: "u-alice",
                            seriesNumbers: [1],
                            exerciseNumbers: ["1.1", "1.2", "1.3", "1.4", "9.9"],
                            theoryNumbers: ["1.1", "1.2"])
    ],
    members: [("me", "Moi", true), ("u-alice", "Alice Moreau", false)],
    meID: "me")
check(subjectComparison.rows.count == 2, "deux membres comparés")
check(subjectComparison.subject == "CS-250", "matière normalisée en majuscules")
check(subjectComparison.rows.first?.userID == "u-alice", "le plus avancé en tête")
check(subjectComparison.me?.userID == "me", "moi identifié dans le classement")
check(subjectComparison.me?.exercisesDone == 1, "mes exercices comptés (1)")
check(subjectComparison.rows.first?.exercisesDone == 4,
      "un numéro hors référentiel ne compte pas (4, pas 5)")
check(subjectComparison.rows.first?.gapExercises == 3, "écart d'exercices (+3)")
check(subjectComparison.rows.first?.gapSeries == -1, "écart de séries (−1)")
check(subjectComparison.rows.first?.gapTheory == 1, "écart de théorie (+1)")
check(subjectComparison.rows.first?.gapLabel == "3 éléments d'avance",
      "libellé d'écart — \(subjectComparison.rows.first?.gapLabel ?? "-")")
check(subjectComparison.me?.gapLabel == nil, "aucun écart affiché pour moi")
check(subjectComparison.notStarted == 0, "personne n'est à zéro")
check(subjectComparison.isComparable, "comparaison possible à deux")
check(subjectComparison.rows.first?.detailLabel == "4/4 exercices · 2/2 théorie · 1/3 séries",
      "détail par axe — \(subjectComparison.rows.first?.detailLabel ?? "-")")

let emptyReference = GroupProgressEngine.compare(
    subject: "X",
    reference: SubjectReference(),
    contributions: [SubjectContribution(userID: "me", seriesNumbers: [1])],
    members: [("me", "Moi", true), ("u1", "Bob", false)],
    meID: "me")
check(emptyReference.rows.allSatisfy { $0.overallPercent == 0 },
      "référentiel vide : aucun pourcentage inventé")
check(!emptyReference.isComparable, "référentiel vide : comparaison signalée comme impossible")

let orphanComparison = GroupProgressEngine.compare(
    subject: "CS-250",
    reference: subjectReference,
    contributions: [SubjectContribution(userID: "me", exerciseNumbers: ["1.1"]),
                    SubjectContribution(userID: "u-ghost", exerciseNumbers: ["1.2"])],
    members: [("me", "Moi", true)],
    meID: "me")
check(orphanComparison.rows.contains { $0.userID == "u-ghost" && !$0.isPresent },
      "une contribution sans membre reste visible, marquée hors groupe")
check(orphanComparison.rows.first?.userID == "me",
      "un membre présent passe devant une contribution orpheline")

let anonymousComparison = GroupProgressEngine.compare(
    subject: "CS-250",
    reference: subjectReference,
    contributions: [SubjectContribution(userID: "u1", exerciseNumbers: ["1.1"]),
                    SubjectContribution(userID: "u2", exerciseNumbers: ["1.2"])],
    members: [("u1", "Bob", false), ("u2", "Chloé", false)],
    meID: nil)
check(anonymousComparison.me == nil, "sans identifiant, aucun « moi »")
check(anonymousComparison.rows.allSatisfy { $0.gapLabel == nil },
      "sans « moi », aucun écart n'est affiché — on ne compare personne à personne")
check(anonymousComparison.rows.allSatisfy { !$0.isMe },
      "sans identifiant, personne n'est marqué comme moi")

let flaggedComparison = GroupProgressEngine.compare(
    subject: "CS-250",
    reference: subjectReference,
    contributions: [SubjectContribution(userID: "me", exerciseNumbers: ["1.1"])],
    members: [("me", "Moi", true), ("u1", "Bob", false)],
    meID: nil)
check(flaggedComparison.me?.userID == "me",
      "le drapeau isMe du membre suffit, même sans identifiant distant")

print("== Avancement par matière, lu depuis les modèles ==")
let builderTerm = AcademicTerm(year: 2025,
                               season: .autumn,
                               startDate: DateUtils.autumnStart(forYear: 2025),
                               endDate: DateUtils.addWeeks(14, to: DateUtils.autumnStart(forYear: 2025)))
context.insert(builderTerm)
let builderCourse = Course(code: "GRP-100", name: "Groupes et réseaux", term: builderTerm)
context.insert(builderCourse)
let builderSeries = ExerciseSeries(course: builderCourse, seriesNumber: 1)
context.insert(builderSeries)
for number in ["1.1", "1.2"] {
    context.insert(Exercise(series: builderSeries, exerciseNumber: number))
}
context.insert(TheoryItem(course: builderCourse, sectionNumber: 1, number: "1.1"))
context.insert(TheoryItem(course: builderCourse, sectionNumber: 1, number: "1.2"))

let builtReference = GroupProgressBuilder.reference(for: builderCourse)
check(builtReference.seriesTotal == 1 && builtReference.exerciseTotal == 2 && builtReference.theoryTotal == 2,
      "référentiel lu depuis le cours (\(builtReference.seriesTotal) série, \(builtReference.exerciseTotal) ex., \(builtReference.theoryTotal) théo.)")
check(GroupProgressBuilder.reference(for: nil).isEmpty, "sans cours, aucun référentiel à comparer")

let builderGroup = StudyGroup(name: "Promo BA4", courseCodes: ["GRP-100"])
context.insert(builderGroup)
context.insert(GroupMember(group: builderGroup, userID: "me", displayName: "Moi",
                           isMe: true, role: .admin, courseCodes: ["GRP-100"]))
context.insert(GroupMember(group: builderGroup, userID: "u-alice", displayName: "Alice",
                           role: .member, courseCodes: ["GRP-100"]))
context.insert(GroupSeriesCompletion(group: builderGroup, userID: "u-alice",
                                     displayName: "Alice", courseCode: "grp-100", seriesNumber: 1))
context.insert(GroupItemCompletion(group: builderGroup, userID: "u-alice", displayName: "Alice",
                                   courseCode: "grp-100", kind: .exercise, itemNumber: "1.1"))
context.insert(GroupItemCompletion(group: builderGroup, userID: "u-alice", displayName: "Alice",
                                   courseCode: "GRP-100", kind: .exercise, itemNumber: "1.2"))
context.insert(GroupItemCompletion(group: builderGroup, userID: "me", displayName: "Moi",
                                   courseCode: "GRP-100", kind: .exercise, itemNumber: "1.1"))
try context.save()

let builtComparison = GroupProgressBuilder.comparison(subject: "grp-100",
                                                      group: builderGroup,
                                                      course: builderCourse,
                                                      meID: "me")
check(builtComparison.rows.count == 2, "deux membres lus depuis le groupe")
check(builtComparison.me?.exercisesDone == 1, "mes exercices lus depuis les modèles (1)")
check(builtComparison.rows.first?.exercisesDone == 2,
      "les numéros sont comparés sans tenir compte de la casse du code")
check(builtComparison.rows.first?.seriesDone == 1, "série lue depuis les modèles")
check(GroupProgressBuilder.contributions(subject: "GRP-100", group: builderGroup).count == 2,
      "contributions regroupées par membre")
check(GroupProgressBuilder.contributions(subject: "INEXISTANT", group: builderGroup).isEmpty,
      "une matière sans donnée ne produit aucune contribution")

let builtHeadline = GroupProgressBuilder.headline(subject: "GRP-100",
                                                  group: builderGroup,
                                                  course: builderCourse,
                                                  meID: "me")
check(builtHeadline.followerCount == 2, "les deux membres suivent GRP-100")
check(builtHeadline.leadLabel == "Alice a 2 éléments d'avance",
      "écart annoncé depuis la carte — \(builtHeadline.leadLabel ?? "aucun")")

let onlyMeHeadline = GroupProgressBuilder.headline(subject: "GRP-100",
                                                   group: builderGroup,
                                                   course: builderCourse,
                                                   meID: "u-alice")
check(onlyMeHeadline.leadLabel == nil || onlyMeHeadline.leadLabel?.contains("Moi") == true,
      "quand je suis devant, aucun retard n'est annoncé")

print("== Session Supabase conservée entre deux lancements ==")
// Le client ne gardait la session qu'en mémoire : **chaque relance déconnectait**.
// Les groupes cessaient de se synchroniser et la présence ne se publiait plus,
// sans qu'aucune erreur ne soit visible.
let sessionNow = Date()
let freshSession = StoredSession(accessToken: "jeton", refreshToken: "rafraîchir",
                                 userID: "u1", email: "a@b.ch",
                                 expiresAt: sessionNow.addingTimeInterval(3600))
check(!freshSession.isExpired(at: sessionNow), "un jeton d'une heure n'est pas expiré")
check(freshSession.isUsable, "un jeton non vide est utilisable")
check(freshSession.userID == "u1", "l'identifiant survit au stockage")

let staleSession = StoredSession(accessToken: "jeton",
                                 expiresAt: sessionNow.addingTimeInterval(-1))
check(staleSession.isExpired(at: sessionNow), "un jeton dépassé est expiré")
check(staleSession.refreshToken == nil, "sans jeton de rafraîchissement, il faudra se reconnecter")

// La marge : un jeton qui expire dans 30 s est traité comme expiré, sinon la
// requête part avec un jeton mort et revient en 401.
let nearly = StoredSession(accessToken: "jeton",
                           expiresAt: sessionNow.addingTimeInterval(30))
check(nearly.isExpired(at: sessionNow),
      "un jeton expirant dans 30 s est renouvelé d'avance (marge \(Int(StoredSession.leeway)) s)")
let comfortable = StoredSession(accessToken: "jeton",
                                expiresAt: sessionNow.addingTimeInterval(StoredSession.leeway + 30))
check(!comfortable.isExpired(at: sessionNow), "au-delà de la marge, on garde le jeton")

// Le trousseau est indexé par hôte : changer de projet ne réutilise pas la session.
check(StoredSession(accessToken: "x", expiresAt: sessionNow)
        == StoredSession(accessToken: "x", expiresAt: sessionNow),
      "deux sessions identiques se comparent")

print("== Diagnostic du direct ==")
check(PresenceAvailability.evaluate(isConfigured: false, isSignedIn: true,
                                    hasRemoteGroup: true, lastError: nil) == .notConfigured,
      "sans Supabase configuré, le direct le dit")
check(PresenceAvailability.evaluate(isConfigured: true, isSignedIn: false,
                                    hasRemoteGroup: true, lastError: nil) == .notSignedIn,
      "sans connexion, le direct le dit")
check(PresenceAvailability.evaluate(isConfigured: true, isSignedIn: true,
                                    hasRemoteGroup: false, lastError: nil) == .groupNotSynced,
      "sans groupe distant, le direct le dit")
check(PresenceAvailability.evaluate(isConfigured: true, isSignedIn: true,
                                    hasRemoteGroup: true, lastError: nil) == .ready,
      "tout en place : le direct est prêt")
check(PresenceAvailability.evaluate(isConfigured: true, isSignedIn: true,
                                    hasRemoteGroup: true,
                                    lastError: "table absente") == .failing("table absente"),
      "un refus du serveur remonte tel quel")
check(!PresenceAvailability.notConfigured.isReady, "un état dégradé n'est pas « prêt »")
check(PresenceAvailability.ready.message == nil, "aucun message quand tout va bien")
for state in [PresenceAvailability.notConfigured, .notSignedIn, .groupNotSynced, .failing("x")] {
    check(state.message?.isEmpty == false, "chaque état dégradé porte un message actionnable")
}

print("== Présence en direct ==")
let presenceNow = Date()
let liveAlice = PresenceEntry(userID: "u-alice",
                              displayName: "Alice Moreau",
                              courseCode: "CS-250",
                              taskLabel: "Exercices",
                              target: "Exercice 3.2",
                              startedAt: presenceNow.addingTimeInterval(-3600),
                              updatedAt: presenceNow,
                              isMe: false)
check(liveAlice.isLive(at: presenceNow), "un battement récent = en ligne")
check(!liveAlice.isLive(at: presenceNow.addingTimeInterval(PresenceEntry.heartbeat * 3)),
      "trois battements manqués = hors ligne")
check(liveAlice.elapsedLabel(at: presenceNow) == DateUtils.hoursLabel(seconds: 3600),
      "durée écoulée affichée — \(liveAlice.elapsedLabel(at: presenceNow))")
check(liveAlice.activityLabel == "CS-250 · Exercices · Exercice 3.2",
      "libellé d'activité — \(liveAlice.activityLabel)")

let deadBob = PresenceEntry(userID: "u-bob",
                            displayName: "Bob",
                            courseCode: "CS-250",
                            taskLabel: "Théorie",
                            target: "",
                            startedAt: presenceNow.addingTimeInterval(-7200),
                            updatedAt: presenceNow.addingTimeInterval(-7200),
                            isMe: false)
let liveMe = PresenceEntry(userID: "me",
                           displayName: "Moi",
                           courseCode: "CS-250",
                           taskLabel: "Exercices",
                           target: "",
                           startedAt: presenceNow.addingTimeInterval(-600),
                           updatedAt: presenceNow,
                           isMe: true)
let liveBoard = PresenceBoard.live([deadBob, liveAlice, liveMe], at: presenceNow)
check(liveBoard.count == 2, "le membre périmé est écarté (\(liveBoard.count) en ligne)")
check(liveBoard.first?.isMe == true, "moi en tête quand je travaille")
check(liveBoard.last?.userID == "u-alice", "les autres suivent, du plus ancien au plus récent")
check(PresenceBoard.summary(liveBoard) == "Alice Moreau travaille en ce moment",
      "résumé à une personne — \(PresenceBoard.summary(liveBoard))")
check(PresenceBoard.summary([liveMe]) == "Tu travailles en ce moment", "résumé quand je suis seul")
check(PresenceBoard.summary([]) == "Personne ne travaille", "résumé à vide")
check(PresenceBoard.summary([liveMe, liveAlice]) == "Alice Moreau travaille en ce moment",
      "mon propre état n'est pas compté comme « quelqu'un d'autre »")
check(PresenceEntry(userID: "u", displayName: "U", courseCode: "", taskLabel: "",
                    target: "", startedAt: presenceNow, updatedAt: presenceNow, isMe: false)
        .activityLabel == "Travail en cours",
      "sans matière ni type, un libellé de repli plutôt qu'une ligne vide")


print("== Catégorisation fine du temps ==")
if let cs = courses.first(where: { $0.code == "CS-250" }),
   let exercise = cs.allExercises.first,
   let item = cs.theoryItems.first {
    let precise = StudySession(course: cs,
                               taskType: .exercise,
                               startedAt: Date(),
                               durationSeconds: 1800,
                               exercise: exercise)
    check(precise.targetLabel == exercise.displayNumber,
          "session liée à un exercice : « \(precise.targetLabel ?? "—") »")
    let reading = StudySession(course: cs,
                               taskType: .theory,
                               startedAt: Date(),
                               durationSeconds: 900,
                               theoryItem: item)
    check(reading.targetLabel == item.displayNumber,
          "session liée à la théorie : « \(reading.targetLabel ?? "—") »")
    let loose = StudySession(course: cs, taskType: .exercise, durationSeconds: 600)
    check(loose.targetLabel == nil,
          "une session non précisée reste valide et sans cible")
    check(precise.durationSeconds + reading.durationSeconds == 2700,
          "le temps reste compté pareil, cible ou pas")
}

print("== Notice de chaque intégration de tâches ==")
check(TaskProvider.allCases.count == 8,
      "huit fournisseurs de tâches (\(TaskProvider.allCases.count))")
for provider in [TaskProvider.microsoftToDo, .googleTasks, .tickTick] {
    check(provider.supportsReading, "\(provider.label) : lecture annoncée")
    check(provider.credentialLabel != nil, "\(provider.label) : identifiant nommé")
    check(provider.icon != TaskProvider.reminders.icon,
          "\(provider.label) : icône propre")
}
for provider in TaskProvider.allCases {
    check(!provider.setupSummary.isEmpty, "\(provider.label) : résumé présent")
    check(provider.setupSteps.count >= 3,
          "\(provider.label) : \(provider.setupSteps.count) étapes de configuration")
    check(provider.setupSteps.allSatisfy { !$0.isEmpty && $0.count > 12 },
          "\(provider.label) : aucune étape vide ni trop courte")
    check(!provider.capabilityLabel.isEmpty, "\(provider.label) : capacité annoncée")
    check(!provider.helpText.isEmpty, "\(provider.label) : aide en ligne présente")
    check(provider.setupCaveat != nil, "\(provider.label) : limite annoncée")
}
check(TaskProvider.allCases.filter { $0.setupURLString != nil }.count >= 2,
      "au moins deux fournisseurs renvoient vers leur page d'identifiants")
check(TaskProvider.allCases.contains { $0.setupURLString == nil },
      "les fournisseurs sans page d'identifiants n'en inventent pas")

print("== Détection des exercices dans un PDF de série ==")

// Polycopié EPFL typique : en-tête de série, exercices numérotés, un bonus.
let typical = """
Série 3 – Intégrales généralisées
Exercice 3.1
Calculer l'intégrale suivante sur R.
Exercice 3.2 (bonus)
Exercice 3.3 – Théorème de Fubini
"""
let typicalSeries = SeriesPDFParser.parse(typical)
check(typicalSeries.count == 1, "un polycopié type donne une série (\(typicalSeries.count))")
if let three = typicalSeries.first {
    check(three.number == 3, "série 3 détectée (\(three.number))")
    check(three.title == "Intégrales généralisées", "intitulé de série : « \(three.title) »")
    check(three.exercises.map(\.number) == ["3.1", "3.2", "3.3"],
          "trois exercices dans l'ordre : \(three.exercises.map(\.number).joined(separator: ", "))")
    check(three.exercises.first(where: { $0.number == "3.2" })?.isBonus == true,
          "« (bonus) » reconnu sur la ligne")
    check(three.exercises.first(where: { $0.number == "3.3" })?.title == "Théorème de Fubini",
          "intitulé d'exercice conservé")
    check(three.exercises.first(where: { $0.number == "3.1" })?.isBonus == false,
          "un exercice normal n'est pas marqué bonus")
}

let multi = """
Série 1
1.1
1.2
Série 2
Exercice 2.1
"""
let multiSeries = SeriesPDFParser.parse(multi)
check(multiSeries.count == 2, "deux séries regroupées (\(multiSeries.count))")
check(multiSeries.map(\.number) == [1, 2], "séries dans l'ordre")
check(multiSeries.first?.exercises.count == 2, "la première série a deux exercices")

let wrapped = "Exercice 4.1\n(bonus)\nExercice 4.2\n"
let wrappedSeries = SeriesPDFParser.parse(wrapped)
check(wrappedSeries.first?.exercises.first(where: { $0.number == "4.1" })?.isBonus == true,
      "« bonus » reconnu sur la ligne suivante")
check(wrappedSeries.first?.exercises.first(where: { $0.number == "4.2" })?.isBonus == false,
      "le bonus ne déborde pas sur l'exercice suivant")

let bareSeries = SeriesPDFParser.parse("Exercice 1\nExercice 2\n")
check(bareSeries.count == 1 && bareSeries[0].exercises.map(\.number) == ["1.1", "1.2"],
      "« Exercice 1 / Exercice 2 » hors série : numérotés dans la série 1 — \(bareSeries.first?.exercises.map(\.number).joined(separator: ", ") ?? "-")")

check(SeriesPDFParser.parse("Exercice 1.1\nExercice 1.1\n").first?.exercises.count == 1,
      "un doublon ne crée pas deux exercices")
check(SeriesPDFParser.parse("Exercice\u{00A0}5.1\n").first?.exercises.first?.number == "5.1",
      "espace insécable toléré")

// Un PDF scanné ne contient aucun texte : le parseur ne doit rien inventer.
check(SeriesPDFParser.parse("").isEmpty, "texte vide : aucune série inventée")
check(SeriesPDFParser.parse("Cours d'analyse\nProfesseur Untel\n").isEmpty,
      "texte sans numéro : aucune série inventée")
check(SeriesPDFParser.majorComponent(of: "12.4") == 12, "série à deux chiffres")
check(SeriesPDFParser.majorComponent(of: "n/a") == nil, "numéro illisible → rien")

print("== Formats réels de polycopiés EPFL ==")

// Analyse 1 inversée : « Ex-02-01: », en-tête « Série 02 (Nombres R) », et deux
// exercices collés sur une même ligne par l'extraction du PDF.
let analyse = """
Série 02 (Nombres R)
Ex-02-01: Montrer que dans R,
1) Si x y alors x + x y + y.
Ex-02-08: Ex-02-09: Montrer que si n est un entier tel que n2 est pair.
Ex-02-11: (Cet exercice est facultatif.)
Soit C := {x ∈ R+ : x3 < 1}.
Ex-02-12: Montrer que l’ensemble C est ouvert.
"""
let analyseSeries = SeriesPDFParser.parse(analyse)
check(analyseSeries.count == 1, "Analyse 1 : une seule série (\(analyseSeries.count))")
if let s = analyseSeries.first {
    check(s.number == 2, "Analyse 1 : série 2 (\(s.number))")
    check(s.title == "Nombres R", "Analyse 1 : titre sans parenthèses « \(s.title) »")
    check(s.exercises.map(\.number) == ["2.1", "2.8", "2.9", "2.11", "2.12"],
          "Analyse 1 : numéros lus — \(s.exercises.map(\.number).joined(separator: ", "))")
    check(s.exercises.contains { $0.number == "2.9" },
          "Analyse 1 : « Ex-02-09 » collé sur la ligne du 08 est bien détecté")
    check(s.exercises.first { $0.number == "2.8" }?.title.isEmpty == true,
          "Analyse 1 : le 08 ne vole pas le titre du 09")
    check(s.exercises.first { $0.number == "2.11" }?.isBonus == true,
          "Analyse 1 : « facultatif » vaut bonus")
    check(s.exercises.first { $0.number == "2.12" }?.isBonus == false,
          "Analyse 1 : un exercice normal n'est pas bonus")
}

// Algèbre linéaire inversée : « Exercice N » suivi de la **première phrase de
// l'énoncé**, pollué par les métadonnées de mise en page « Type : … Défi : ⋆⋆ ».
//
// Le texte qui suit le numéro n'est pas un intitulé : c'est l'énoncé. L'afficher
// comme titre sous l'exercice invente une information (constaté sur un vrai PDF :
// « solution générale. » sous l'exercice 1, « tions change. » sous le 3).
let algebre = """
Série 2
Exercice 1 solution générale.
Type : Technique Défi : ⋆⋆
Exercice 2 Type : Concept Défi : ⋆⋆
Exercice 3
"""
let algebreSeries = SeriesPDFParser.parse(algebre)
check(algebreSeries.count == 1, "Algèbre : une seule série (\(algebreSeries.count))")
if let s = algebreSeries.first {
    check(s.number == 2, "Algèbre : série 2 lue depuis l'en-tête (\(s.number))")
    check(s.exercises.map(\.number) == ["2.1", "2.2", "2.3"],
          "Algèbre : trois exercices, numérotés par leur série — \(s.exercises.map(\.number).joined(separator: ", "))")
    check(s.exercises.first?.title.isEmpty == true,
          "Algèbre : « solution générale. » n'est pas retenu comme titre — « \(s.exercises.first?.title ?? "") »")
    check(s.exercises.first { $0.number == "2.2" }?.title.isEmpty == true,
          "Algèbre : les métadonnées « Type : … Défi : … » ne polluent pas le titre")
    check(s.exercises.first { $0.number == "2.3" }?.title.isEmpty == true,
          "Algèbre : « Exercice 3 » seul n'invente pas de titre")
}

// Le tri entre intitulé et énoncé, cas par cas.
print("== Intitulé ou énoncé ? ==")
check(!SeriesPDFParser.looksLikeTitle("solution générale."), "une phrase terminée par un point est un énoncé")
check(!SeriesPDFParser.looksLikeTitle("tions change."), "un fragment de mot est rejeté")
check(!SeriesPDFParser.looksLikeTitle("ou contre-exemple."), "une suite d'énoncé en minuscule est rejetée")
check(!SeriesPDFParser.looksLikeTitle("Montrer que l'ensemble C est ouvert."),
      "une consigne complète est rejetée")
check(!SeriesPDFParser.looksLikeTitle("1) Si x y alors x + x y + y."), "une énumération est rejetée")
check(!SeriesPDFParser.looksLikeTitle("Montrer que ;"), "un point-virgule final est rejeté")
check(SeriesPDFParser.looksLikeTitle("Diagonalisation ; applications"),
      "un point-virgule interne ne suffit pas à rejeter — limite assumée de la règle")
check(!SeriesPDFParser.looksLikeTitle(String(repeating: "Mot ", count: 30)),
      "un texte trop long est rejeté")
check(!SeriesPDFParser.looksLikeTitle("   "), "un texte vide est rejeté")
check(SeriesPDFParser.looksLikeTitle("Diagonalisation"), "un intitulé court est conservé")
check(SeriesPDFParser.looksLikeTitle("Espaces vectoriels"), "un intitulé de deux mots est conservé")
check(SeriesPDFParser.looksLikeTitle("Nombres R"), "un intitulé sans ponctuation est conservé")

// Et sur un document complet : le titre explicite après deux-points survit.
let titré = """
Série 3
Exercice 1 : Diagonalisation
Exercice 2 : Espaces vectoriels
"""
let titréSeries = SeriesPDFParser.parse(titré)
check(titréSeries.first?.exercises.first?.title == "Diagonalisation",
      "un intitulé explicite après deux-points est conservé — « \(titréSeries.first?.exercises.first?.title ?? "") »")
check(titréSeries.first?.exercises.count == 2, "les deux exercices sont lus")

// Les métadonnées seules ne laissent pas un titre vide de sens.
check(SeriesPDFParser.exerciseTitle("Type : Technique Défi : \u{22c6}\u{22c6}").isEmpty,
      "les métadonnées seules ne font pas un titre")
check(SeriesPDFParser.exerciseTitle("Diagonalisation") == "Diagonalisation",
      "un vrai intitulé traverse le nettoyage")

print("== Mise en page du PDF : titre ou énoncé ? ==")
// Le cas signalé sur un vrai polycopié : « Exercice 1 » suivi de la **première
// phrase de l'énoncé**. Le texte seul ne permet pas de les distinguer ; la taille
// de police, si. C'est tout l'objet de `SeriesLayoutParser`.
func layout(_ text: String, _ size: Double, bold: Bool = false, page: Int = 0) -> PDFLayoutLine {
    PDFLayoutLine(text: text, fontSize: size, isBold: bold, pageIndex: page)
}

let algebreLayout = [
    layout("Série 2", 16),
    layout("Exercice 1", 13),
    layout("solution générale.", 11),
    layout("Type : Technique Défi : ⋆⋆", 9),
    layout("Exercice 2", 13),
    layout("tions change.", 11),
    layout("Exercice 3", 13),
    layout("ou contre-exemple.", 11)
]
check(SeriesLayoutParser.bodyFontSize(algebreLayout) == 11,
      "corps de texte déduit de la police la plus lue (\(SeriesLayoutParser.bodyFontSize(algebreLayout) ?? -1))")

let algebreParsed = SeriesLayoutParser.parse(algebreLayout)
check(algebreParsed.count == 1, "une seule série (\(algebreParsed.count))")
check(algebreParsed.first?.number == 2, "série 2 lue depuis l'en-tête")
check(algebreParsed.first?.exercises.map(\.number) == ["2.1", "2.2", "2.3"],
      "trois exercices — \(algebreParsed.first?.exercises.map(\.number).joined(separator: ", ") ?? "-")")
check(algebreParsed.first?.exercises.allSatisfy { $0.title.isEmpty } == true,
      "aucun énoncé n'est pris pour un intitulé")

// Un vrai intitulé, lui, doit survivre.
let titréLayout = [
    layout("Série 3", 16),
    layout("Exercice 1 : Diagonalisation", 13),
    layout("Montrer que la matrice est diagonalisable.", 11),
    layout("Exercice 2", 13),
    layout("Espaces vectoriels", 13)
]
let titréParsed = SeriesLayoutParser.parse(titréLayout)
check(titréParsed.first?.exercises.first?.title == "Diagonalisation",
      "intitulé sur la même ligne — « \(titréParsed.first?.exercises.first?.title ?? "") »")
check(titréParsed.first?.exercises.count == 2, "deux exercices")

// Un titre peut tenir sur deux lignes, à condition que la seconde soit du **même
// niveau** que la première. C'est ce qui autorise la suite, et interdit l'énoncé.
let twoLineLayout = [
    layout("Série 4", 16),
    layout("Exercice 1", 13),
    layout("Formes bilinéaires", 13),
    layout("Montrer que la forme est symétrique.", 11)
]
let twoLineParsed = SeriesLayoutParser.parse(twoLineLayout)
check(twoLineParsed.first?.exercises.first?.title == "Formes bilinéaires",
      "titre sur deux lignes accepté — « \(twoLineParsed.first?.exercises.first?.title ?? "") »")

// Le bonus est souvent **plus bas** que la ligne suivante : l'ancienne lecture ne
// regardait qu'une ligne, et le manquait.
let bonusLayout = [
    layout("Série 5", 16),
    layout("Exercice 4", 13),
    layout("Montrer que l'ensemble est ouvert.", 11),
    layout("Indication : utiliser la boule unité.", 11),
    layout("(Cet exercice est facultatif.)", 11),
    layout("Exercice 5", 13),
    layout("Calculer la limite.", 11)
]
let bonusParsed = SeriesLayoutParser.parse(bonusLayout)
check(bonusParsed.first?.exercises.first { $0.number == "5.4" }?.isBonus == true,
      "bonus trouvé trois lignes plus bas")
check(bonusParsed.first?.exercises.first { $0.number == "5.5" }?.isBonus == false,
      "le bonus ne déborde pas sur l'exercice suivant")

// Sans information de police — texte collé — on retombe sur les motifs, sans régression.
let pasted = SeriesLayoutParser.parse("Série 2\nExercice 1 solution générale.\nExercice 2\n"
                                      .components(separatedBy: "\n").map { PDFLayoutLine(text: $0) })
check(pasted.first?.exercises.map(\.number) == ["2.1", "2.2"],
      "texte sans mise en page : les motifs prennent le relais — \(pasted.first?.exercises.map(\.number).joined(separator: ", ") ?? "-")")
check(pasted.first?.exercises.first?.title.isEmpty == true,
      "et la règle sur les intitulés s'applique quand même")

// Une tête de série sans exercice reste visible pour être complétée à la main.
let headerOnlyLayout = [layout("Série 7", 16), layout("Consignes générales.", 11)]
let headerOnlyParsed = SeriesLayoutParser.parse(headerOnlyLayout)
check(headerOnlyParsed.count == 1 && headerOnlyParsed.first?.exercises.isEmpty == true,
      "série annoncée sans exercice : conservée, liste vide")

// « Ex-02-04 » porte la série dans son numéro, même sans en-tête.
let dashedLayout = [layout("Ex-02-04: Montrer que si n est pair.", 11),
                    layout("Ex-02-05: En déduire le résultat.", 11)]
let dashedParsed = SeriesLayoutParser.parse(dashedLayout)
check(dashedParsed.first?.number == 2, "série déduite du numéro d'exercice")
check(dashedParsed.first?.exercises.count == 2, "deux exercices « Ex-02-xx »")

// Le corps est en gras partout (diapositives) : le gras ne doit plus servir de
// signal, sinon chaque ligne deviendrait un titre.
let allBold = [
    layout("Série 2", 16, bold: true),
    layout("Exercice 1", 14, bold: true),
    layout("solution générale.", 14, bold: true)
]
let allBoldParsed = SeriesLayoutParser.parse(allBold)
check(allBoldParsed.first?.exercises.first?.title.isEmpty == true,
      "corps entièrement en gras : aucun faux intitulé")

print("== Code de cours dans un horaire iCal ==")
// Le code n'est pas toujours dans l'intitulé : on le cherche aussi dans la
// description et le lieu, et on distingue un vrai code d'un code fabriqué.
check(TimetableImport.detectCourseCode(in: "CS-250 Algorithms I") == "CS-250",
      "code lu dans l'intitulé")
check(TimetableImport.detectCourseCode(in: "Analyse I") == nil,
      "un intitulé sans code n'en invente pas")
check(TimetableImport.detectCourseCode(in: "MATH-101 / Analyse I") == "MATH-101",
      "code lu dans une description de type « MATH-101 / Analyse I »")
check(TimetableImport.detectCourseCode(in: "Salle CS-250") == "CS-250",
      "code lu dans le lieu, faute de mieux")

check(TimetableImport.isOfficialCode("CS-250"), "« CS-250 » est un code officiel")
check(TimetableImport.isOfficialCode("MATH-101"), "« MATH-101 » est un code officiel")
check(!TimetableImport.isOfficialCode("ANALYSE"),
      "« ANALYSE » est un code fabriqué, pas un code officiel")
check(!TimetableImport.isOfficialCode("PHYSIQ-2"),
      "un code fabriqué avec suffixe n'est pas officiel")

// Le repli sur le nom : un ICS accentué doit retrouver le cours déjà saisi.
check(TimetableImport.nameKey("Algèbre linéaire") == TimetableImport.nameKey("Algebre lineaire"),
      "les accents ne séparent pas un cours de lui-même")
check(TimetableImport.nameKey("Analyse I") == TimetableImport.nameKey("analyse  i"),
      "casse et espaces multiples ignorés")
check(TimetableImport.nameKey("Analyse I") != TimetableImport.nameKey("Analyse II"),
      "deux cours différents restent distincts")
check(TimetableImport.nameKey("Projet de semestre!") == "projet de semestre",
      "ponctuation ignorée : « \(TimetableImport.nameKey("Projet de semestre!")) »")

print("== Tolérance de forme des polycopiés ==")
// Tous les cours n'écrivent pas « Exercice 1.1 ».
check(SeriesPDFParser.parse("Ex 1.1\nEx 1.2\n").first?.exercises.count == 2,
      "« Ex 1.1 » sans tiret")
check(SeriesPDFParser.parse("Ex.1.1\n").first?.exercises.count == 1, "« Ex.1.1 »")
check(SeriesPDFParser.parse("Exercice n° 1.1\n").first?.exercises.count == 1,
      "« Exercice n° 1.1 »")
check(SeriesPDFParser.parse("Exo 2.1\n").first?.exercises.count == 1, "« Exo 2.1 »")
check(SeriesPDFParser.parse("Problème 1.1\n").first?.exercises.count == 1, "« Problème 1.1 »")
check(SeriesPDFParser.parse("1·2\n").first?.exercises.count == 1, "séparateur médian « 1·2 »")

// Robustesse à une mise en page inconnue : la série est conservée sans exercice,
// pour que l'écran de relecture reste utilisable.
let headerOnly = SeriesPDFParser.parse("Série 4\nDes consignes sans numéro d'exercice.\n")
check(headerOnly.count == 1 && headerOnly.first?.number == 4
      && headerOnly.first?.exercises.isEmpty == true,
      "une série annoncée sans exercice reconnu est conservée")

// Pas de faux positif sur du texte courant.
check(SeriesPDFParser.parse("Le chapitre traite de ce point.\n").isEmpty,
      "une phrase sans numéro en tête ne crée pas d'exercice")
check(SeriesPDFParser.parse("Voir la page 12 pour la suite.\n").isEmpty,
      "une référence de page ne crée pas d'exercice")

print("== Type de séance depuis CATEGORIES ==")
// Le « Mon horaire » de l'EPFL écrit trois fois CATEGORIES, dont une vide : les
// valeurs arrivent donc concaténées avec des trous.
check(ICSParser.isLectureCategory("Horaires enseignés FBM,,Cours,") == true,
      "« Cours » reconnu malgré les valeurs vides")
check(ICSParser.isLectureCategory(",,Exercices,") == false,
      "« Exercices » n'est pas un cours magistral")
check(ICSParser.isLectureCategory(",,Labo,") == false,
      "« Labo » n'est pas un cours magistral")
check(ICSParser.isLectureCategory("Horaires enseignés FBM,,") == nil,
      "sans type de séance, on ne tranche pas")
check(ICSParser.isLectureCategory("") == nil, "catégories vides → indécis")

print("== Début du semestre d'automne ==")
// L'EPFL fait commencer le semestre d'automne le lundi 7 septembre pour tout le
// monde. Le demander à l'onboarding décalait tout le suivi hebdomadaire.
let sept2026 = DateUtils.autumnStart(forYear: 2026)
var gregorian = Calendar(identifier: .gregorian)
gregorian.firstWeekday = 2
let parts2026 = gregorian.dateComponents([.year, .month, .day, .weekday], from: sept2026)
check(parts2026.year == 2026 && parts2026.month == 9 && parts2026.day == 7,
      "2026 : le 7 septembre (\(parts2026.day ?? 0)/\(parts2026.month ?? 0))")
check(parts2026.weekday == 2, "2026 : c'est bien un lundi")
// Une année où le 7 septembre n'est pas un lundi doit donner le lundi suivant.
for year in 2026...2032 {
    let start = DateUtils.autumnStart(forYear: year)
    let parts = gregorian.dateComponents([.month, .day, .weekday], from: start)
    check(parts.weekday == 2, "\(year) : le semestre commence un lundi")
    check(parts.month == 9 && (parts.day ?? 0) >= 7 && (parts.day ?? 0) <= 13,
          "\(year) : début entre le 7 et le 13 septembre (\(parts.day ?? 0))")
}
// Le suivi hebdomadaire doit alors dire « semaine 1 » la semaine du 7 septembre.
if let term = try? AcademicTerm(year: 2026, season: .autumn, startDate: sept2026,
                                endDate: DateUtils.addWeeks(14, to: sept2026), totalWeeks: 14) {
    let firstMonday = DateUtils.addDays(7, to: sept2026)
    check(DateUtils.clampedWeek(for: firstMonday, term: term) == 2,
          "la semaine suivant le 7 septembre est la semaine 2")
    check(DateUtils.clampedWeek(for: sept2026, term: term) == 1,
          "la semaine du 7 septembre est la semaine 1")
}

print("== Durée iCalendar (DURATION) ==")
// Le « Mon horaire » de l'EPFL n'émet pas de DTEND : uniquement `DURATION:PT105M`.
// Sans ce décodage, chaque séance retombait sur le défaut d'une heure.
check(ICSParser.parseDuration("PT105M") == 105 * 60, "PT105M = 105 min")
check(ICSParser.parseDuration("PT45M") == 45 * 60, "PT45M = 45 min")
check(ICSParser.parseDuration("PT1H30M") == 90 * 60, "PT1H30M = 90 min")
check(ICSParser.parseDuration("PT1H") == 3600, "PT1H = 1 h")
check(ICSParser.parseDuration("P1D") == 86_400, "P1D = 1 jour")
check(ICSParser.parseDuration("PT30S") == 30, "PT30S = 30 s")
check(ICSParser.parseDuration("") == nil, "une durée vide n'est pas une durée")
check(ICSParser.parseDuration("PT0M") == nil, "une durée nulle n'est pas retenue")
check(ICSParser.parseDuration("20260915T081500") == nil,
      "une date n'est pas une durée — le piège qui faisait tout tomber à 1 h")

print("== Configuration Supabase compilée ==")
// Le binaire de validation n'a pas de clés Info.plist : il doit se déclarer non
// configuré plutôt que de tenter une connexion vers une URL vide.
check(!SupabaseConfig.isConfigured,
      "un binaire sans clés se déclare non configuré")
check(!SupabaseConfig.isUsable(""),
      "une valeur vide n'est pas une configuration")
check(!SupabaseConfig.isUsable("$(SUPABASE_URL)"),
      "une variable de build non définie n'est pas prise pour une URL")
check(!SupabaseConfig.isUsable("   "),
      "des espaces ne font pas une configuration")
// Sans domaine, aucune URL ne doit être fabriquée : « https:// » tout seul
// enverrait les requêtes dans le vide.
check(SupabaseConfig.urlString.isEmpty,
      "sans domaine, aucune URL n'est inventée")
check(SupabaseConfig.isUsable("testprojet.supabase.co"),
      "un domaine nu est accepté (le schéma est ajouté par le code)")
check(!SupabaseConfig.isUsable("$(SUPABASE_HOST)"),
      "un domaine resté littéral n'est pas une configuration")
check(SupabaseConfig.isUsable("https://exemple.supabase.co"),
      "une vraie URL est acceptée")
check(SupabaseConfig.isUsable("eyJhbGciOiJIUzI1NiJ9.clef"),
      "une vraie clé est acceptée")

print("== Tâches, calendrier, sessions planifiées ==")
let task = LinkedTask(provider: .todoist, externalID: "t1", title: "CS-250 exercice 1.1", dueDate: Date())
task.course = cs
context.insert(task)
let event = LinkedCalendarEvent(title: "CS-250 Cours", startsAt: Date(), endsAt: Date().addingTimeInterval(3600), kind: .lecture)
event.isAttended = true
event.course = cs
context.insert(event)
let planned = PlannedSession(course: cs, title: "Révisions", startsAt: Date(), durationMinutes: 90)
context.insert(planned)
try context.save()

let tasks = try context.fetch(FetchDescriptor<LinkedTask>())
let events = try context.fetch(FetchDescriptor<LinkedCalendarEvent>())
let plannedAll = try context.fetch(FetchDescriptor<PlannedSession>())
check(tasks.count == 1 && tasks[0].linkLabel == "CS-250", "tâche liée au cours")
check(events.count == 1 && events[0].isLecture, "événement de cours marqué présent")
check(plannedAll.count == 3, "sessions planifiées (\(plannedAll.count))")
let classSeconds = WorkloadEngine.classSeconds(for: cs)
check(classSeconds > 0, "les heures d'amphi entrent dans le réel : \(DateUtils.durationLabel(seconds: classSeconds))")

print("== Cours sans heures de cours (« a un cours » = non) ==")
if let project = courses.first(where: { $0.code == "PROJ-101" }) {
    check(!project.hasLectures, "PROJ-101 déclaré sans amphi")
    let projectWorkload = WorkloadEngine.delta(for: project, hoursPerCredit: 30)
    check(projectWorkload.lectureSeconds == 0,
          "aucune heure d'amphi attendue pour un cours sans cours")
    check(projectWorkload.exerciseSeconds == projectWorkload.expectedSeconds,
          "tout est en travail personnel (\(DateUtils.hoursLabel(seconds: projectWorkload.exerciseSeconds)))")
} else {
    check(false, "PROJ-101 présent dans les données d'exemple")
}

print("== Bornage de la semaine dans le semestre ==")
let finishedTerm = AcademicTerm(year: 2020,
                                season: .spring,
                                startDate: DateUtils.addWeeks(-40, to: Date()),
                                endDate: DateUtils.addWeeks(-26, to: Date()),
                                totalWeeks: 14)
let clamped = DateUtils.clampedWeek(for: Date(), term: finishedTerm)
check(clamped == 14, "semestre terminé → semaine bornée à 14 (obtenu \(clamped))")
check(!finishedTerm.isRunning, "semestre terminé détecté")
let runningTerm = AcademicTerm(year: 2025,
                               season: .spring,
                               startDate: DateUtils.addWeeks(-2, to: DateUtils.startOfWeek(Date())),
                               endDate: DateUtils.addWeeks(12, to: Date()),
                               totalWeeks: 14)
check(runningTerm.isRunning, "semestre en cours détecté")
check(DateUtils.clampedWeek(for: Date(), term: runningTerm) == 3,
      "semestre démarré il y a 2 semaines → semaine 3")

print("== DailyPlanner ==")
let todos = DailyPlanner.todos(for: courses.filter(\.isTracked), limit: 20)
check(!todos.isEmpty, "des tâches à faire sont proposées (\(todos.count))")
check(todos.allSatisfy { $0.week >= 1 }, "chaque tâche porte une semaine valide")
check(todos == todos.sorted { $0.kind.rank < $1.kind.rank }, "tâches triées par priorité")
let weeklyVideoMinutes = DailyPlanner.weeklyVideoMinutes(for: courses)
check(weeklyVideoMinutes >= 0, "durée de vidéo hebdomadaire : \(weeklyVideoMinutes) min")

print("== ICSParser (horaire EPFL) ==")
let ics = """
BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
UID:cs250-cours
SUMMARY:CS-250 Algorithms I (cours)
DTSTART;TZID=Europe/Zurich:20250217T081500
DTEND;TZID=Europe/Zurich:20250217T100000
LOCATION:CM1 100
RRULE:FREQ=WEEKLY;COUNT=5;BYDAY=MO
END:VEVENT
END:VCALENDAR
"""
let parsedEvents = ICSParser.parse(ics)
check(parsedEvents.count == 5, "5 occurrences hebdomadaires (\(parsedEvents.count))")
check(parsedEvents.allSatisfy { $0.summary.contains("CS-250") }, "intitulé conservé")
check(parsedEvents[0].durationSeconds == 6300,
      "durée 1 h 45 (\(parsedEvents[0].durationSeconds) s)")
check(parsedEvents[1].start > parsedEvents[0].start, "occurrences ordonnées")
let weekGap = DateUtils.daysBetween(parsedEvents[0].start, parsedEvents[1].start)
check(weekGap == 7, "occurrences espacées de 7 jours (\(weekGap))")
check(parsedEvents[0].location == "CM1 100", "lieu conservé")

let detected = TimetableImport.detectCourseCode(in: "CS-250 Algorithms I (cours)")
check(detected == "CS-250", "code détecté : \(detected ?? "nil")")
let cleaned = TimetableImport.cleanedName("CS-250 Algorithms I (cours)", code: "CS-250")
check(cleaned == "Algorithms I", "intitulé nettoyé : « \(cleaned) »")
let derived = TimetableImport.derivedCode(from: "Analyse I", existing: ["ANALYSEI"])
check(derived == "ANALYSE", "code dérivé depuis le nom : \(derived)")
let derivedUnique = TimetableImport.derivedCode(from: "Analyse I", existing: ["ANALYSE"])
check(derivedUnique == "ANALYSE-2", "code dérivé rendu unique : \(derivedUnique)")

print("== Import iCalendar dans SwiftData ==")
let importResult = TimetableImport.import(ics, into: context, sectionCode: "IN")
check(importResult.coursesMatched == 1,
      "CS-250 existant reconnu depuis l'horaire (\(importResult.coursesMatched))")
check(importResult.coursesCreated == 0, "aucun doublon de cours créé")
check(importResult.eventsCreated == 5, "5 séances créées (\(importResult.eventsCreated))")
check(importResult.sectionApplied == 1, "section IN appliquée au cours existant")
let refreshed = (try? context.fetch(FetchDescriptor<Course>())) ?? []
if let imported = refreshed.first(where: { $0.code == "CS-250" }) {
    check(imported.hasLectures, "le cours importé a bien des heures de cours")
    check(imported.sectionCode == "IN", "section appliquée à l'import")
}
let secondImport = TimetableImport.import(ics, into: context, sectionCode: "IN")
check(secondImport.eventsCreated == 0, "réimport idempotent (\(secondImport.eventsSkipped) ignorées)")

// Un cours absent de l'app est créé automatiquement depuis l'horaire.
let unknownICS = """
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:unknown-1
SUMMARY:Analyse numérique
DTSTART;TZID=Europe/Zurich:20250218T101500
DTEND;TZID=Europe/Zurich:20250218T120000
RRULE:FREQ=WEEKLY;COUNT=3
END:VEVENT
END:VCALENDAR
"""
let unknownResult = TimetableImport.import(unknownICS, into: context, sectionCode: "MA")
check(unknownResult.coursesCreated == 1,
      "cours inconnu créé automatiquement (\(unknownResult.coursesCreated))")
check(unknownResult.eventsCreated == 3, "3 séances du cours inconnu (\(unknownResult.eventsCreated))")

// Le **lieu** ne doit jamais servir à déduire un code de cours.
//
// L'horaire EPFL ne contient aucun code officiel : ni SUMMARY, ni DESCRIPTION.
// Chercher un code dans LOCATION faisait correspondre « BS170 » (un local) au motif
// d'un code de cours, et produisait un cours nommé « BS-170 ».
print("== Le lieu ne détermine jamais le code de cours ==")
let roomICS = """
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:room-1
SUMMARY:Thermodynamique appliquée
LOCATION:BS170, CM1221
CATEGORIES:Cours
DTSTART;TZID=Europe/Zurich:20250217T081500
DTEND;TZID=Europe/Zurich:20250217T100000
END:VEVENT
END:VCALENDAR
"""
let roomResult = TimetableImport.import(roomICS, into: context, sectionCode: "MA")
check(roomResult.coursesCreated == 1, "le cours sans code est créé (\(roomResult.coursesCreated))")
let afterRoom = (try? context.fetch(FetchDescriptor<Course>())) ?? []
check(afterRoom.contains { $0.code == "THERMOD" },
      "code dérivé du nom, pas du local (\(afterRoom.map(\.code).filter { $0.hasPrefix("THERMO") }))")
check(!afterRoom.contains { $0.code.contains("BS170") || $0.code.contains("BS-170") },
      "aucun cours nommé d'après un local")
check(!afterRoom.contains { $0.name.contains("BS170") },
      "aucun cours nommé d'après un local (intitulé)")
check(afterRoom.first { $0.code == "THERMOD" }?.hasLectures == true,
      "CATEGORIES:Cours marque bien des heures de cours")
let roomEvents = ((try? context.fetch(FetchDescriptor<LinkedCalendarEvent>())) ?? [])
    .filter { $0.course?.code == "THERMOD" }
check(roomEvents.count == 1, "une séance enregistrée pour ce cours (\(roomEvents.count))")
check(roomEvents.first?.location.contains("BS170") == true,
      "le local reste enregistré comme lieu — \(roomEvents.first?.location ?? "-")")
check(roomEvents.first?.isLecture == true, "la séance est classée comme cours")
check(afterRoom.first { $0.code == "THERMOD" }?.name != "BS170",
      "l'intitulé du cours n'est pas le local")


print("== Semestre rattaché aux cours importés ==")
// `TimetableImport` créait les cours avec `term: nil`. `Course.currentWeek` n'avait
// alors rien pour calculer et retombait sur 1 : un import fait en semaine 2
// affichait « 1 / 14 » partout, sans le moindre signe d'erreur.
let expectedWeek = DateUtils.weekNumber(from: DateUtils.currentAutumnOrSpringStart().start)
let importedCourses = (try? context.fetch(FetchDescriptor<Course>())) ?? []
let arbitraryImported = importedCourses.first { $0.code == "THERMOD" }
check(arbitraryImported?.term != nil, "un cours créé par l'import d'horaire reçoit un semestre")
check(arbitraryImported?.currentWeek == expectedWeek,
      "…donc sa semaine vient du calendrier (\(arbitraryImported?.currentWeek ?? -1)), pas de « 1 »")

let orphanCourse = Course(code: "ORPHAN-1", name: "Cours sans semestre")
context.insert(orphanCourse)
// Deux séries importées pendant la panne : elles portent toutes deux « semaine 1 »,
// y compris la Série 2 — parce que l'import PDF prend `course.currentWeek`, qui
// valait 1 faute de semestre.
let orphanSeries1 = ExerciseSeries(course: orphanCourse, seriesNumber: 1, plannedWeek: 1)
let orphanSeries2 = ExerciseSeries(course: orphanCourse, seriesNumber: 2, plannedWeek: 1)
let orphanSeries4 = ExerciseSeries(course: orphanCourse, seriesNumber: 4, plannedWeek: 7)
context.insert(orphanSeries1)
context.insert(orphanSeries2)
context.insert(orphanSeries4)
try? context.save()
check(orphanCourse.term == nil, "un cours peut exister sans semestre")
check(orphanCourse.currentWeek == expectedWeek,
      "sans semestre, la semaine reste celle du calendrier (\(orphanCourse.currentWeek)) — jamais 1 par défaut")
let repaired = AcademicTerm.attachOrphanCourses(in: context)
check(repaired >= 1, "les cours orphelins sont rattachés (\(repaired))")
check(orphanCourse.term != nil, "le cours orphelin a maintenant un semestre")
check(AcademicTerm.attachOrphanCourses(in: context) == 0, "le rattachement est idempotent")
check(orphanCourse.term?.isRunning == true, "le semestre rattaché est celui en cours")

// La réparation des semaines de série reste bornée.
check(orphanSeries1.plannedWeek == 1, "une série 1 reste en semaine 1")
check(orphanSeries2.plannedWeek == 2, "la Série 2 repasse en semaine 2 — \(orphanSeries2.plannedWeek)")
check(orphanSeries4.plannedWeek == 7,
      "une semaine choisie à la main n'est jamais écrasée — \(orphanSeries4.plannedWeek)")

// La date de début n'est pas déduite du jour : elle vient du calendrier EPFL.
let autumn = DateUtils.autumnStart(forYear: 2026)
check(DateUtils.weekNumber(from: autumn, to: autumn) == 1, "le lundi de rentrée est la semaine 1")
check(DateUtils.weekNumber(from: autumn,
                           to: DateUtils.addDays(7, to: autumn)) == 2,
      "sept jours plus tard, semaine 2")
check(DateUtils.weekNumber(from: autumn,
                           to: DateUtils.addDays(9, to: autumn)) == 2,
      "le mercredi de la deuxième semaine est bien la semaine 2")

print("== Import CSV ==")
let csv = """
course_code,course_name,credits,kind,number,title,duration_seconds,week,is_bonus,date,weight,location
BIO-201,Biologie,5,video,1.1,Cellules,2400,1,,,,,
BIO-201,Biologie,5,exercise,1.1,,,1,false,,,
BIO-201,Biologie,5,exercise,1.2,,,1,true,,,
BIO-201,Biologie,5,exam,midterm,Midterm,,,,2026-03-27T08:00:00Z,30,AAB
"""
do {
    let csvSummary = try CourseImporter.importCSV(csv, into: context, sectionCode: "SV")
    check(csvSummary.coursesCreated == 1, "1 cours créé depuis le CSV (\(csvSummary.coursesCreated))")
    check(csvSummary.videos == 1, "1 vidéo (\(csvSummary.videos))")
    check(csvSummary.exercises == 2, "2 exercices (\(csvSummary.exercises))")
    check(csvSummary.exams == 1, "1 évaluation (\(csvSummary.exams))")
    let afterCSV = (try? context.fetch(FetchDescriptor<Course>())) ?? []
    check(afterCSV.first(where: { $0.code == "BIO-201" })?.sectionCode == "SV",
          "section appliquée à l'import CSV")
    if let bio = afterCSV.first(where: { $0.code == "BIO-201" }) {
        let bioProgress = ProgressEngine.progress(for: bio)
        check(bioProgress.videoCount == 1 && bioProgress.exerciseCount == 1,
              "comptage : 1 vidéo et 1 exercice requis (bonus exclu)")
        check(bioProgress.bonusCount == 1, "1 bonus détecté depuis le CSV")
    }
} catch {
    check(false, "import CSV sans erreur : \(error)")
}

print("== Contraste : chaque teinte porteuse de sens est résolue ==")
// Surfaces de référence : carte claire (#FFFFFF) et carte sombre (#1C1C1E).
let cardLight = ColorContrast.RGB.white
let cardDark = ColorContrast.RGB(r: 0.110, g: 0.110, b: 0.118)

let identityPalette = ["#4F46E5", "#0EA5E9", "#10B981", "#F59E0B", "#EF4444",
                       "#8B5CF6", "#EC4899", "#14B8A6", "#F97316", "#6366F1"]
let suretéTriad = ["#34C759", "#FF9500", "#FF3B30"]

func fmt(_ value: Double) -> String { String(format: "%.2f", value) }

var contrastFailures = 0
func checkContrast(_ hex: String, surface: ColorContrast.RGB, _ context: String) {
    guard let hue = ColorContrast.rgb(fromHex: hex) else {
        check(false, "\(hex) illisible"); contrastFailures += 1; return
    }
    let badge = ColorContrast.badgeStyle(hue: hue, surface: surface)
    let inkRatio = ColorContrast.ratio(badge.ink, badge.fill)
    let mark = ColorContrast.accessibleVariant(of: hue, against: surface, target: ColorContrast.markTarget)
    let markRatio = ColorContrast.ratio(mark, surface)
    let verdict = ColorContrast.accessibleVariant(of: hue, against: surface, target: ColorContrast.textTarget)
    let verdictRatio = ColorContrast.ratio(verdict, surface)

    if inkRatio < 4.5 { contrastFailures += 1; check(false, "\(hex) \(context) encre de pastille = \(fmt(inkRatio)):1") }
    if markRatio < 3.0 { contrastFailures += 1; check(false, "\(hex) \(context) marque = \(fmt(markRatio)):1") }
    if verdictRatio < 4.5 { contrastFailures += 1; check(false, "\(hex) \(context) remplissage de verdict = \(fmt(verdictRatio)):1") }
}

for hex in identityPalette + suretéTriad {
    checkContrast(hex, surface: cardLight, "clair")
    checkContrast(hex, surface: cardDark, "sombre")
}
check(contrastFailures == 0,
      "\(identityPalette.count + suretéTriad.count) teintes × 2 apparences : texte ≥4.5:1, marque ≥3:1")

// Contrôle négatif : l'ancien schéma (teinte sur sa propre teinte) doit échouer,
// sinon le test précédent ne prouverait rien.
if let amber = ColorContrast.rgb(fromHex: "#F59E0B") {
    let oldBadge = ColorContrast.blend(cardLight, amber, amount: 0.16)
    let oldRatio = ColorContrast.ratio(amber, oldBadge)
    check(oldRatio < 4.5,
          "l'ancien schéma échouait bien (ambre sur sa teinte = \(fmt(oldRatio)):1 < 4.5)")
}

print("== Encre indigo : primitive + encre, résolues par apparence ==")
if let accent = ColorContrast.rgb(fromHex: Theme.accentHex),
   let accentDark = ColorContrast.rgb(fromHex: Theme.accentDarkHex),
   let accentInk = ColorContrast.rgb(fromHex: Theme.accentInkHex),
   let accentInkDark = ColorContrast.rgb(fromHex: Theme.accentInkDarkHex) {
    check(ColorContrast.ratio(accent, cardLight) >= 4.5,
          "accent clair sur carte claire = \(fmt(ColorContrast.ratio(accent, cardLight))):1")
    check(ColorContrast.ratio(accentDark, cardDark) >= 3.0,
          "accent sombre sur carte sombre ≥3:1 (glyphes) = \(fmt(ColorContrast.ratio(accentDark, cardDark))):1")
    check(ColorContrast.ratio(.white, accentDark) >= 4.5,
          "libellé blanc sur bouton plein sombre = \(fmt(ColorContrast.ratio(.white, accentDark))):1")
    check(ColorContrast.ratio(accentInkDark, cardDark) >= 4.5,
          "encre accent sombre ≥4.5:1 (texte) = \(fmt(ColorContrast.ratio(accentInkDark, cardDark))):1")
    // La valeur unique d'origine échouait en mode sombre : c'est ce qui a motivé la paire.
    check(ColorContrast.ratio(accent, cardDark) < 3.0,
          "l'unique valeur d'origine échouait en sombre = \(fmt(ColorContrast.ratio(accent, cardDark))):1")
} else {
    check(false, "les quatre valeurs d'Encre indigo sont lisibles")
}

print("== Sureté : le glyphe évidé garde le contraste du remplissage ==")
for hex in suretéTriad {
    guard let hue = ColorContrast.rgb(fromHex: hex) else { continue }
    for (surface, name) in [(cardLight, "clair"), (cardDark, "sombre")] {
        let fill = ColorContrast.accessibleVariant(of: hue, against: surface, target: ColorContrast.textTarget)
        // Le glyphe utilise la couleur de la surface : son contraste est exactement
        // celui du remplissage.
        let glyphRatio = ColorContrast.ratio(surface, fill)
        check(glyphRatio >= 4.5, "\(hex) \(name) : glyphe évidé = \(fmt(glyphRatio)):1")
        // L'ancienne pastille pleine avec un glyphe blanc restait sous 4.5:1 dans
        // tous les cas — 3.55:1 au mieux (rouge), 2.2:1 pour le vert et l'orange.
        let whiteOnMark = ColorContrast.ratio(.white,
            ColorContrast.accessibleVariant(of: hue, against: surface, target: ColorContrast.markTarget))
        if name == "sombre" {
            check(whiteOnMark < 4.5,
                  "\(hex) sombre : glyphe blanc insuffisant (\(fmt(whiteOnMark)):1 < 4.5)")
        }
    }
}

print("== FocusTimerState : le chrono survit à une fermeture ==")
do {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    var timer = FocusTimerState(sessionStartedAt: t0, taskTypeRaw: "exercise")
    timer.start(at: t0)
    check(timer.isRunning, "démarré : en cours")
    check(Int(timer.elapsed(at: t0.addingTimeInterval(90))) == 90, "90 s écoulées après 90 s")
    timer.pause(at: t0.addingTimeInterval(120))
    check(!timer.isRunning && Int(timer.accumulated) == 120, "pause : 120 s accumulées")
    check(Int(timer.elapsed(at: t0.addingTimeInterval(9_999))) == 120, "en pause, le temps ne court plus")
    timer.start(at: t0.addingTimeInterval(200))
    check(Int(timer.elapsed(at: t0.addingTimeInterval(260))) == 180, "reprise : 120 + 60 = 180 s")
    timer.start(at: t0.addingTimeInterval(300))
    check(Int(timer.elapsed(at: t0.addingTimeInterval(360))) == 280, "un second « start » en cours ne remet rien à zéro")
    check(timer.isRestorable(at: t0.addingTimeInterval(3_600)), "restaurable une heure plus tard")
    check(!timer.isRestorable(at: t0.addingTimeInterval(FocusTimerState.maxRestorableAge + 1)),
          "plus restaurable au-delà de \(Int(FocusTimerState.maxRestorableAge / 3600)) h")
    check(!FocusTimerState(sessionStartedAt: t0).isRestorable(at: t0), "un chrono à zéro n'est pas restauré")

    let defaults = UserDefaults(suiteName: "studytrack.validation.\(UUID().uuidString)")!
    FocusTimerStore.save(timer, defaults: defaults)
    let reloaded = FocusTimerStore.load(defaults: defaults)
    check(reloaded == timer, "aller-retour UserDefaults sans perte")
    FocusTimerStore.save(nil, defaults: defaults)
    check(FocusTimerStore.load(defaults: defaults) == nil, "effacement du chrono")
}

print("== SessionStats : totaux par jour ==")
do {
    let cal = Calendar.current
    let today = cal.startOfDay(for: Date())
    let totals = SessionStats.dailyTotals(sessions, days: 14, endingAt: Date())
    check(totals.count == 14, "14 colonnes, jours vides compris (\(totals.count))")
    check(totals.last?.day == today, "la dernière colonne est aujourd'hui")
    check(totals.first!.day < totals.last!.day, "du plus ancien au plus récent")
    let sum = totals.reduce(0) { $0 + $1.seconds }
    let expected = sessions.filter { $0.startedAt >= cal.date(byAdding: .day, value: -13, to: today)! }
        .reduce(0) { $0 + $1.durationSeconds }
    check(sum == expected, "somme des colonnes = sessions des 14 derniers jours (\(sum / 60) min)")
    let groups = SessionStats.groupedByDay(sessions)
    check(groups.count == 10, "10 jours de sessions dans l'exemple (\(groups.count))")
    check(groups.first!.day > groups.last!.day, "le plus récent d'abord")
    check(groups.allSatisfy { g in g.sessions.allSatisfy { cal.isDate($0.startedAt, inSameDayAs: g.day) } },
          "chaque session est dans le bon jour")
    let avg = SessionStats.averageActiveDaySeconds(totals)
    check(avg > 0 && avg == sum / totals.filter { !$0.isEmpty }.count, "moyenne sur les jours actifs seulement")
    check(SessionStats.averageActiveDaySeconds([]) == 0, "moyenne vide = 0")
}

print("== WidgetFormat : heures en dixièmes arrondis ==")
// Un instantané écrit par la version précédente (sans `next`, `courses`,
// `timer`) doit se relire : sinon, après une mise à jour, les widgets restent
// vides jusqu'à la prochaine ouverture de l'app.
let oldSnapshot = #"{"updatedAt":"2026-09-20T10:00:00Z","weekSeconds":3600,"streak":2,"level":1,"xp":10,"todoCount":1,"todos":[]}"#
let snapshotDecoder = JSONDecoder()
snapshotDecoder.dateDecodingStrategy = .iso8601
let decodedOld = try? snapshotDecoder.decode(WidgetSnapshot.self, from: Data(oldSnapshot.utf8))
check(decodedOld?.weekSeconds == 3600 && decodedOld?.next == nil && decodedOld?.courses == nil,
      "un instantané de la version précédente se relit")
let startLink = WidgetLink.start(WidgetAction(targetKind: "exercise", targetID: "X", courseID: "C", courseCode: "CS-250",
                                          title: "Exercice 3.2", detail: "", reason: "À refaire", colorHex: "#000000",
                                          taskType: "exercise", icon: "timer"))
check(startLink.absoluteString.hasPrefix("studytrack://focus?course=CS-250&type=exercise&label="),
      "le lien « démarrer » porte le cours, le type et le libellé — \(startLink.absoluteString)")
check(WidgetFormat.hours(45 * 60) == "45 min", "45 min")
check(WidgetFormat.hours(2 * 3600) == "2 h", "2 h")
check(WidgetFormat.hours(95 * 60) == "1,6 h", "1 h 35 → 1,6 h (l'ancien code donnait 1,3 h)")
check(WidgetFormat.hours(117 * 60) == "2 h", "1 h 57 → 2 h (arrondi, pas 1,10)")
check(WidgetFormat.hours(63 * 60) == "1,1 h", "1 h 03 → 1,1 h")
check(WidgetFormat.hours(-5) == "0 min", "négatif → 0 min")
check(WidgetFormat.countdown(to: DateUtils.addDays(3, to: Date())) == "J-3", "J-3")
check(WidgetFormat.countdown(to: Date()) == "Aujourd'hui", "aujourd'hui")

print("== Sauvegarde : export → import sans perte ni doublon ==")
do {
    let backup = DataExporter.makePayload(courses: courses, sessions: sessions)
    check(backup.courses.count == courses.count, "\(backup.courses.count) cours exportés")
    check(backup.sessions?.count == sessions.count, "\(backup.sessions?.count ?? 0) sessions exportées")
    check(backup.term != nil, "le semestre est exporté")
    let watched = backup.courses.flatMap { $0.videos ?? [] }.filter { $0.watchedAt != nil }.count
    check(watched == videos.filter(\.isWatched).count, "\(watched) vidéos vues conservées")
    let chapters = backup.courses.flatMap { $0.videos ?? [] }.filter { $0.kind == "chapter" }.count
    check(chapters == 1, "le support (chapitre) est exporté")
    let done = backup.courses.flatMap { $0.series ?? [] }.flatMap { $0.exercises ?? [] }.filter { $0.doneAt != nil }.count
    check(done == exercises.filter(\.isDone).count, "\(done) exercices faits conservés")

    guard let data = DataExporter.makeJSON(courses: courses, sessions: sessions),
          let json = String(data: data, encoding: .utf8) else {
        check(false, "JSON de sauvegarde produit"); throw NSError(domain: "v", code: 1)
    }
    // Restauration dans un conteneur vierge.
    let restoreConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let restoreContainer = try ModelContainer(for: schema, configurations: [restoreConfig])
    let restoreContext = ModelContext(restoreContainer)
    let summary = try CourseImporter.importJSON(json, into: restoreContext)
    check(summary.coursesCreated == courses.count, "\(summary.coursesCreated) cours restaurés")
    check(summary.sessions == sessions.count, "\(summary.sessions) sessions restaurées")
    let restoredCourses = try restoreContext.fetch(FetchDescriptor<Course>())
    let restoredVideos = try restoreContext.fetch(FetchDescriptor<TheoryItem>())
    let restoredExercises = try restoreContext.fetch(FetchDescriptor<Exercise>())
    check(restoredVideos.filter(\.isWatched).count == videos.filter(\.isWatched).count, "vidéos vues restaurées")
    check(restoredVideos.contains { $0.kind == .chapter }, "le chapitre reste un chapitre")
    check(restoredExercises.filter(\.isDone).count == exercises.filter(\.isDone).count, "exercices faits restaurés")
    check(restoredExercises.filter(\.redoRequired).count == exercises.filter(\.redoRequired).count, "« à refaire » restauré")
    check(restoredExercises.compactMap(\.confidence).count == exercises.compactMap(\.confidence).count, "sureté restaurée")
    let restoredSessions = try restoreContext.fetch(FetchDescriptor<StudySession>())
    check(restoredSessions.reduce(0) { $0 + $1.durationSeconds } == sessions.reduce(0) { $0 + $1.durationSeconds },
          "temps total identique après restauration")
    check(restoredSessions.allSatisfy { $0.course != nil }, "chaque session retrouve son cours")
    for course in courses {
        let p1 = ProgressEngine.progress(for: course)
        let p2 = restoredCourses.first { $0.code == course.code }.map(ProgressEngine.progress(for:))
        check(p2 == p1, "\(course.code) : progression identique après restauration")
    }
    // Idempotence : réimporter ne double rien.
    let again = try CourseImporter.importJSON(json, into: restoreContext)
    check(again.sessions == 0 && again.coursesCreated == 0, "réimport : 0 session, 0 cours en double")
    check(try restoreContext.fetch(FetchDescriptor<StudySession>()).count == sessions.count, "sessions inchangées au réimport")

    let csv = DataExporter.sessionsCSV(sessions)
    check(csv.split(separator: "\n").count == sessions.count + 1, "CSV : en-tête + \(sessions.count) lignes")
    check(csv.hasPrefix("date,heure,cours,type,cible,minutes,note"), "CSV : en-tête attendu")
}

print("== GroupSeriesEngine : avancement série par série ==")
do {
    let refs = [
        GroupSeriesEngine.SeriesRef(number: 1, title: "Série 1", plannedWeek: 1, required: ["1.1", "1.2"], bonus: ["1.3"]),
        GroupSeriesEngine.SeriesRef(number: 2, title: "Série 2", plannedWeek: 2, required: ["2.1", "2.2", "2.3"], bonus: []),
        GroupSeriesEngine.SeriesRef(number: 3, title: "Série 3", plannedWeek: 3, required: [], bonus: [])
    ]
    let members = [
        GroupSeriesEngine.MemberRef(userID: "me", displayName: "Moi", isMe: true),
        GroupSeriesEngine.MemberRef(userID: "alice", displayName: "Alice", isMe: false),
        GroupSeriesEngine.MemberRef(userID: "bob", displayName: "Bob", isMe: false)
    ]
    let items = [
        GroupSeriesEngine.ItemDone(userID: "me", number: "1.1"),
        GroupSeriesEngine.ItemDone(userID: "me", number: "1.3"),      // bonus : ne compte pas
        GroupSeriesEngine.ItemDone(userID: "alice", number: "1.1"),
        GroupSeriesEngine.ItemDone(userID: "alice", number: "1.2"),
        GroupSeriesEngine.ItemDone(userID: "alice", number: "2.1"),
        GroupSeriesEngine.ItemDone(userID: "alice", number: "9.9"),   // inconnu : ignoré
        GroupSeriesEngine.ItemDone(userID: "ghost", number: "2.2")    // hors groupe : ignoré
    ]
    let declared = [GroupSeriesEngine.SeriesDone(userID: "bob", seriesNumber: 2)]
    let boards = GroupSeriesEngine.boards(series: refs, members: members, itemsDone: items, seriesDone: declared, meID: "me")
    check(boards.count == 3, "3 séries, dans l'ordre (\(boards.map(\.seriesNumber)))")
    let s1 = boards[0]
    check(s1.rows.first?.userID == "alice", "série 1 : Alice (2/2) en tête")
    check(s1.rows.first?.isComplete == true, "série 1 : Alice a terminé")
    check(s1.me?.doneNumbers == ["1.1"], "série 1 : moi 1.1 fait, le bonus 1.3 ne compte pas (\(s1.me?.doneNumbers ?? []))")
    check(s1.me?.percent == 0.5, "série 1 : moi à 50 %")
    check(s1.summary == "1 sur 3 a terminé", "série 1 : « \(s1.summary) »")
    let s2 = boards[1]
    check(s2.rows.first?.userID == "bob" && s2.rows.first?.isComplete == true,
          "série 2 : Bob déclarée terminée passe devant Alice (1/3)")
    check(s2.rows.first?.doneCount == 0, "série 2 : Bob n'a aucun détail mais est complet")
    check(s2.rows.map(\.userID) == ["bob", "alice", "me"], "série 2 : tri terminé > avancé > moi (\(s2.rows.map(\.userID)))")
    check(s2.rows.contains { $0.userID == "me" && $0.doneCount == 0 }, "série 2 : moi à zéro, présent quand même")
    check(!s2.rows.contains { $0.userID == "ghost" }, "un membre hors groupe n'apparaît pas")
    check(boards[2].total == 0 && boards[2].summary == "Personne n'a commencé", "série 3 vide : « \(boards[2].summary) »")
    let gap = GroupSeriesEngine.gapToLeader(boards)
    // Alice : 2 + 1 = 3 ; Bob : 0 + 3 (déclarée) = 3 ; moi : 1 → écart 2.
    check(gap?.gap == 2, "écart au leader = 2 exercices (\(gap?.gap ?? -1))")
    check(GroupSeriesEngine.gapToLeader([]) == nil, "sans tableau, pas d'écart")
}

print("== Brouillons de série : plan rapide, gestes sur l'arbre, enregistrement ==")
do {
    typealias Tree = SubQuestionTree
    func plan(_ text: String) -> String { Tree.parse(text).map(Tree.outline) ?? "illisible" }
    check(plan("1(a-d) 2(a-e) 3") == "1(a-d) 2(a-e) 3", "plan lu et réécrit à l'identique — \(plan("1(a-d) 2(a-e) 3"))")
    check(Tree.parse("1-4")?.map(\.label) == ["1", "2", "3", "4"], "plage de questions")
    check(Tree.parse("1(a,b) 2")?.first?.children.map(\.label) == ["a", "b"], "liste de points")
    check(Tree.parse("i-iv")?.map(\.label) == ["i", "ii", "iii", "iv"], "plage romaine")
    check(Tree.parse("+ 1 2 +")?.map(\.kind) == [.part, .question, .question, .part], "parties sans numéro")
    check(Tree.parse("1(a-") == nil, "parenthèse non fermée : illisible")
    check(plan("1(a,b)") == "1(a,b)", "deux points restent écrits en liste")
    let kept = Tree.parse("1(a-b)", keeping: [DetectedSubQuestion(label: "1", text: "Soit x",
                                                                   children: [DetectedSubQuestion(label: "a", text: "borne")])])
    check(kept?.first?.text == "Soit x" && kept?.first?.children.first?.text == "borne",
          "réécrire le plan garde les énoncés déjà saisis")

    var tree = Tree.parse("1 2 3")!
    let two = tree[1].id
    Tree.indent(two, in: &tree)
    check(Tree.outline(tree) == "1(2) 3", "« 2 » devient un point de « 1 » — \(Tree.outline(tree))")
    Tree.outdent(two, in: &tree)
    check(Tree.outline(tree) == "1 2 3", "…et remonte à sa place — \(Tree.outline(tree))")
    Tree.addChild(to: tree[0].id, in: &tree)
    Tree.addChild(to: tree[0].id, in: &tree)
    check(Tree.outline(tree) == "1(a,b) 2 3", "points ajoutés a, b — \(Tree.outline(tree))")
    Tree.remove(tree[0].children[0].id, from: &tree)
    Tree.relabel(&tree)
    check(Tree.outline(tree) == "1(a) 2 3", "renumérotation — \(Tree.outline(tree))")
    check(Tree.rows(tree).map(\.depth) == [0, 1, 0, 0], "affichage à plat avec profondeur")
    check(Tree.rows(tree)[2].canIndent && !Tree.rows(tree)[0].canIndent, "seule une question précédée d'une autre peut devenir un point")

    // Problèmes signalés avant d'enregistrer.
    var draft = SeriesDraft(number: 5, title: "", plannedWeek: 5, exercises: [])
    draft.addExercise(); draft.addExercise()
    check(draft.exercises.map(\.minor) == ["1", "2"], "exercices ajoutés 5.1, 5.2")
    draft.exercises[1].minor = "1"
    check(draft.problems(takenNumbers: []).contains { $0.contains("5.1") }, "numéro en double signalé")
    check(draft.problems(takenNumbers: [5]).contains { $0.contains("série 5") }, "série en double signalée")
    draft.renumberExercises()
    check(draft.problems(takenNumbers: []).isEmpty, "renuméroter corrige")

    // Modification : renuméroter garde l'avancement, retirer supprime.
    let draftCourse = Course(code: "TST-100", name: "Test", credits: 4)
    let written = SeriesDraftWriter.write(SeriesDraft(number: 2, title: "Suites", plannedWeek: 2, exercises: [
        ExerciseDraft(minor: "1", title: "", isBonus: false, subQuestions: Tree.parse("1(a-b) 2")!),
        ExerciseDraft(minor: "2", title: "", isBonus: false),
        ExerciseDraft(minor: "3", title: "", isBonus: true)
    ]), to: draftCourse, mode: .edit, context: nil)
    check(written.outcome.created == 3 && written.series.exercises.count == 3, "série créée avec trois exercices")
    check(written.series.sortedExercises.first?.subQuestionLabel == "0/3", "questions créées avec l'exercice")
    let first = written.series.sortedExercises[0]
    first.sortedSubQuestions[0].sortedChildren[0].toggle()
    written.series.sortedExercises[1].doneAt = Date()

    var edit = SeriesDraft(series: written.series)
    check(edit.title == "Suites" && edit.exercises.count == 3, "le brouillon relit la série")
    edit.exercises.remove(at: 2)
    edit.exercises.swapAt(0, 1)
    edit.renumberExercises()
    let second = SeriesDraftWriter.write(edit, to: draftCourse, mode: .edit, context: nil)
    check(second.outcome.deleted == 1 && second.series.exercises.count == 2, "l'exercice retiré est supprimé")
    let reordered = second.series.sortedExercises
    check(reordered.map(\.exerciseNumber) == ["2.1", "2.2"], "renumérotés dans le nouvel ordre")
    check(reordered[0].isDone, "l'ancien 2.2, devenu 2.1, garde son « fait »")
    check(reordered[1].subQuestionLabel == "1/3", "l'ancien 2.1, devenu 2.2, garde ses cases cochées — \(reordered[1].subQuestionLabel ?? "-")")

    // Import : ne supprime jamais, met à jour par numéro.
    let merged = SeriesDraftWriter.write(SeriesDraft(number: 2, title: "", plannedWeek: 2, exercises: [
        ExerciseDraft(minor: "2", title: "Relu", isBonus: false, subQuestions: Tree.parse("1(a-c) 2")!),
        ExerciseDraft(minor: "4", title: "", isBonus: false)
    ]), to: draftCourse, mode: .importMerge, context: nil)
    check(merged.outcome == .init(created: 1, updated: 1, deleted: 0), "import : un mis à jour, un créé, aucun supprimé — \(merged.outcome)")
    check(merged.series.title == "Suites", "un titre vide à l'import ne l'efface pas")
    let relu = merged.series.exercises.first { $0.exerciseNumber == "2.2" }
    check(relu?.title == "Relu" && relu?.subQuestionLabel == "1/4", "arbre remplacé, case 1.a conservée — \(relu?.subQuestionLabel ?? "-")")
    relu?.statement = "Montrer la borne"
    var noStatement = SeriesDraft(series: merged.series)
    for index in noStatement.exercises.indices { noStatement.exercises[index].statement = "" }
    SeriesDraftWriter.write(noStatement, to: draftCourse, mode: .importMerge, context: nil)
    check(relu?.statement == "Montrer la borne", "un import sans énoncé n'efface pas celui qui existe")
    SeriesDraftWriter.write(noStatement, to: draftCourse, mode: .edit, context: nil)
    check(relu?.statement == "", "…mais le vider à la main, si")
}

print("== MathMarkup : formules lisibles ==")
do {
    typealias M = MathMarkup
    func r(_ s: String) -> [String] {
        M.runs(s).map { run in
            switch run.style {
            case .normal: return run.text
            case .subscripted: return "_[\(run.text)]"
            case .superscripted: return "^[\(run.text)]"
            }
        }
    }
    check(r("a_n") == ["a", "_[n]"], "indice simple — \(r("a_n"))")
    check(r("x_{n+1} = 2") == ["x", "_[n+1]", " = 2"], "indice entre accolades — \(r("x_{n+1} = 2"))")
    check(r("n^2+1") == ["n", "^[2]", "+1"], "exposant — \(r("n^2+1"))")
    check(M.plain("|a_n - \\ell| \\le \\varepsilon") == "|an - ℓ| ≤ ε", "symboles — \(M.plain("|a_n - \\ell| \\le \\varepsilon"))")
    check(r("$\\frac{1}{2}$") == ["^[1]", "⁄", "_[2]"], "fraction courte en forme de fraction — \(r("$\\frac{1}{2}$"))")
    check(M.plain("\\frac{an+b}{cn+d}") == "(an+b)/(cn+d)", "fraction longue parenthésée — \(M.plain("\\frac{an+b}{cn+d}"))")
    check(M.plain("\\sqrt{n^2+2}") == "√(n2+2)", "racine d'une expression — \(M.plain("\\sqrt{n^2+2}"))")
    check(M.plain("\\sqrt{x}") == "√x", "racine simple")
    check(M.plain("n \\in \\mathbb{N}^*") == "n ∈ ℕ*", "ensembles — \(M.plain("n \\in \\mathbb{N}^*"))")
    check(M.plain("\\lim_{n \\to \\infty} a_n = L") == "limn → ∞ an = L", "limite — \(M.plain("\\lim_{n \\to \\infty} a_n = L"))")
    check(r("prix _ unitaire") == ["prix _ unitaire"], "un « _ » isolé entre espaces reste du texte")
    check(M.plain("\\unknown{x}") == "unknownx", "commande inconnue : son nom, pas un trou")
    check(!M.hasMarkup("Montrer la borne"), "texte sans formule : rien à faire")
}

print("== NextActionEngine : une seule prochaine action ==")
do {
    let now = Date()
    let course = Course(code: "NXT-101", name: "Next", credits: 5)
    course.isTracked = true
    let later = ExerciseSeries(course: course, seriesNumber: 1, title: "Série 1", plannedWeek: 1)
    let soon = ExerciseSeries(course: course, seriesNumber: 2, title: "Série 2", plannedWeek: 2,
                              dueDate: now.addingTimeInterval(20 * 3600))
    let e1 = Exercise(series: later, exerciseNumber: "1.1", sortOrder: 0)
    e1.redoRequired = true
    e1.doneAt = now
    let e2 = Exercise(series: soon, exerciseNumber: "2.1", sortOrder: 0)
    e2.doneAt = now
    let e3 = Exercise(series: soon, exerciseNumber: "2.2", sortOrder: 1)
    later.exercises = [e1]
    soon.exercises = [e2, e3]
    course.series = [later, soon]
    let exam = Exam(course: course, kind: .midterm, title: "Midterm", date: now.addingTimeInterval(3 * 86400))
    course.exams = [exam]

    let actions = NextActionEngine.actions(for: [course], now: now)
    check(actions.first?.title == e3.displayNumber, "la série à rendre dans 20 h passe en premier — \(actions.first?.title ?? "-")")
    if case .seriesDue = actions.first?.reason {} else { check(false, "raison : série à rendre") }
    check(actions.first?.detail.contains("1 exercice restant") == true, "…avec ce qui reste — \(actions.first?.detail ?? "")")
    check(actions.dropFirst().first?.reason == .redo, "puis l'exercice à refaire")
    check(actions.contains { if case .exam = $0.reason { return true } else { return false } }, "une évaluation dans 3 jours propose une révision")
    check(Set(actions.map(\.id)).count == actions.count, "aucune action en double")
    soon.dueDate = now.addingTimeInterval(5 * 86400)
    check(NextActionEngine.actions(for: [course], now: now).first?.reason == .redo,
          "une échéance lointaine ne passe plus devant « à refaire »")
    check(NextActionEngine.relativeDay(now.addingTimeInterval(86400), now: now) == "demain", "« demain »")
}

print("== SeriesAIParsing : lecture de la réponse d'un modèle ==")
do {
    let answer = """
    Voici le résultat : ```json
    {"series":[{"number":3,"title":"Récurrences","exercises":[
      {"number":"3.1","title":"Tri fusion","isBonus":false},
      {"number":"2","title":"","isBonus":true},
      {"number":"Ex 3.1","title":"doublon","isBonus":false},
      {"number":"abc","title":"","isBonus":false},
      {"number":"3.3","title":"Montrer que pour tout n, la suite converge vers la limite attendue, en détaillant chaque étape.","isBonus":false}
    ]},{"number":0,"exercises":[]},{"number":3,"exercises":[{"number":"3.4","title":"","isBonus":false}]}]}
    ```
    """
    let parsed = SeriesAIParsing.parse(answer)
    check(parsed.count == 1, "une série (le numéro 0 est rejeté, la répétition fusionnée) (\(parsed.count))")
    check(parsed.first?.number == 3 && parsed.first?.title == "Récurrences", "série 3 « Récurrences »")
    let numbers = parsed.first?.exercises.map(\.number) ?? []
    check(numbers == ["3.1", "3.2", "3.3", "3.4"], "numéros normalisés et dédoublonnés : \(numbers)")
    check(parsed.first?.exercises.first { $0.number == "3.2" }?.isBonus == true, "« 2 » dans la série 3 → 3.2, bonus")
    check(parsed.first?.exercises.first { $0.number == "3.3" }?.title == "", "un énoncé n'est pas pris pour un titre")
    check(parsed.first?.exercises.first { $0.number == "3.1" }?.title == "Tri fusion", "l'intitulé court est gardé")
    check(SeriesAIParsing.parse("pas de json").isEmpty, "sans JSON : rien")
    check(SeriesAIParsing.parse("{\"series\":[]}").isEmpty, "liste vide : rien")
    check(SeriesAIParsing.normalizeNumber("4.2", series: 3) == "3.2", "un numéro d'une autre série suit la série parente")
    check(SeriesAIParsing.normalizeNumber("1.2.3", series: 1) == nil, "trois niveaux : refusé")

    // Fusion : le modèle complète, ne retire jamais.
    let heuristic = [DetectedSeries(number: 3, title: "", exercises: [
        DetectedExercise(number: "3.1", title: "", isBonus: false),
        DetectedExercise(number: "3.5", title: "Vu par les motifs seulement", isBonus: false)
    ])]
    let merged = SeriesAIParsing.merge(heuristic: heuristic, ai: parsed)
    check(merged.count == 1 && merged[0].title == "Récurrences", "fusion : le titre de série vient du modèle")
    check(merged[0].exercises.map(\.number) == ["3.1", "3.2", "3.3", "3.4", "3.5"], "fusion : union triée (\(merged[0].exercises.map(\.number)))")
    check(merged[0].exercises.first { $0.number == "3.1" }?.title == "Tri fusion", "fusion : l'intitulé manquant est complété")
    check(merged[0].exercises.first { $0.number == "3.5" }?.title == "Vu par les motifs seulement", "fusion : rien de l'heuristique n'est perdu")
    check(SeriesAIParsing.merge(heuristic: heuristic, ai: []) == heuristic, "fusion avec réponse vide : heuristique inchangée")

    // Préparation : un long texte est réduit à ses lignes structurantes.
    let noise = String(repeating: "Soit f une fonction continue sur un intervalle fermé borné.\n", count: 400)
    let long = "Série 4\n" + noise + "Exercice 4.1 Théorème des valeurs intermédiaires\nMontrer que…\n" + noise
    let prepared = SeriesAIParsing.prepare(long)
    check(long.count > SeriesAIParsing.maxCharacters, "texte long (\(long.count) car.)")
    check(prepared.count <= SeriesAIParsing.maxCharacters, "préparé sous la limite (\(prepared.count) car.)")
    check(prepared.contains("Série 4") && prepared.contains("Exercice 4.1"), "les en-têtes survivent")
    check(prepared.contains("Montrer que…"), "la ligne suivant un exercice survit (intitulé possible)")
    check(!prepared.contains("intervalle fermé borné.\nSoit f"), "le bruit répété est retiré")
    check(SeriesAIParsing.prepare("court") == "court", "un texte court passe tel quel")
}

print("== Import PDF : ce que le document dit de lui-même ==")
do {
    func line(_ text: String, _ size: Double = 11, bold: Bool = false, page: Int = 0,
              indent: Double = 60, startsBold: Bool = false) -> PDFLayoutLine {
        PDFLayoutLine(text: text, fontSize: size, isBold: bold, pageIndex: page, indent: indent, startsBold: startsBold)
    }

    // La série n'est pas toujours en début de ligne : c'était la cause de tout
    // un PDF rangé en « série 1 ».
    let header = [line("EPFL — Analyse I — Série 4", 9), line("Automne 2026", 9), line("Exercice 1", 13)]
    check(SeriesDocumentInference.seriesNumberInDocument(header) == 4, "« … — Série 4 » en en-tête : série 4")
    check(SeriesDocumentInference.seriesNumberInDocument([line("Exercise Set 5", 14)]) == 5, "« Exercise Set 5 » : série 5")
    check(SeriesDocumentInference.seriesNumberInDocument([line("Problem Sheet 02", 14)]) == 2, "« Problem Sheet 02 » : série 2")
    check(SeriesDocumentInference.seriesNumberInDocument([line("Série de Taylor", 11)]) == nil, "« série de Taylor » n'est pas un numéro")
    check(SeriesDocumentInference.seriesNumber(inFilename: "serie03_sol.pdf") == 3, "nom de fichier « serie03_sol » : 3")
    check(SeriesDocumentInference.seriesNumber(inFilename: "Series_4.pdf") == 4, "nom de fichier « Series_4 » : 4")
    check(SeriesDocumentInference.seriesNumber(inFilename: "ex7.pdf") == 7, "nom de fichier « ex7 » : 7")
    check(SeriesDocumentInference.seriesNumber(inFilename: "cs250-notes.pdf") == nil, "un code de cours n'est pas un numéro de série")
    check(SeriesDocumentInference.seriesNumber(lines: header, filename: "serie09.pdf")?.number == 4,
          "le document l'emporte sur le nom du fichier")

    // Le cours désigné par le PDF.
    let cs = SeriesDocumentInference.CourseCandidate(id: UUID(), code: "CS-250", name: "Algorithms I")
    let math = SeriesDocumentInference.CourseCandidate(id: UUID(), code: "MATH-101", name: "Analyse I")
    check(SeriesDocumentInference.course(in: header, filename: nil, candidates: [cs, math]) == math.id,
          "« Analyse I » dans l'en-tête : MATH-101")
    check(SeriesDocumentInference.course(in: [], filename: "cs250_serie2.pdf", candidates: [cs, math]) == cs.id,
          "« cs250 » dans le nom de fichier : CS-250")
    check(SeriesDocumentInference.course(in: [line("Série 3", 14)], filename: "s3.pdf", candidates: [cs, math]) == nil,
          "aucun indice : on ne choisit pas à la place de l'étudiant·e")

    // Sans en-tête en tête de ligne, la série vient du document.
    let noHeader = [line("Exercice 1", 13), line("Soit f.", 11), line("Exercice 2", 13), line("Calculer.", 11)]
    check(SeriesLayoutParser.parse(noHeader, defaultSeries: 4).first?.exercises.map(\.number) == ["4.1", "4.2"],
          "série déduite du document : 4.1, 4.2")

    // Anglais et allemand.
    let english = [line("Exercise 1", 13), line("Prove it.", 11), line("Problem 2", 13), line("Compute.", 11)]
    check(SeriesLayoutParser.parse(english, defaultSeries: 2).first?.exercises.map(\.number) == ["2.1", "2.2"],
          "« Exercise 1 », « Problem 2 » reconnus")
    check(SeriesPDFParser.parse("Exercise 1\nExercise 2\n", defaultSeries: 3).first?.exercises.map(\.number) == ["3.1", "3.2"],
          "texte collé en anglais, série fournie")
    check(SeriesPDFParser.parse("Aufgabe 1\n").first?.exercises.count == 1, "« Aufgabe 1 » reconnu")

    // Faux positifs : une démonstration numérotée, une citation.
    let phantoms = [line("Série 3", 16), line("Exercice 1", 13),
                    line("1.5 Montrer que la suite converge vers zéro quand n tend vers l'infini.", 11),
                    line("Exercice 2 de la série précédente nous a appris que la limite existe.", 11),
                    line("Exercice 2", 13)]
    check(SeriesLayoutParser.parse(phantoms).first?.exercises.map(\.number) == ["3.1", "3.2"],
          "ni « 1.5 » de corps de texte ni une citation ne créent d'exercice — \(SeriesLayoutParser.parse(phantoms).first?.exercises.map(\.number) ?? [])")

    // Un « 1. » mis en forme de titre, dans un document sans mot-clé : un exercice.
    let numbered = [line("Série 6", 16), line("1. Suites", 12, bold: true, indent: 60),
                    line("Soit u.", 11), line("2. Séries", 12, bold: true, indent: 60)]
    check(SeriesLayoutParser.parse(numbered).first?.exercises.map(\.number) == ["6.1", "6.2"],
          "« 1. Suites » en gras : exercice 6.1")

    // Titre en ligne (LaTeX) : la ligne commence en gras.
    let runIn = [line("Série 2", 16),
                 line("Exercice 1. Soit f une fonction continue.", 11, startsBold: true),
                 line("Exercice 2. Calculer la limite.", 11, startsBold: true)]
    check(SeriesLayoutParser.parse(runIn).first?.exercises.count == 2, "titres « en ligne » reconnus")

    // Questions rattachées à l'exercice.
    let questions = [line("Série 1", 16), line("Exercice 1", 13), line("Soit f.", 11),
                     line("a) Montrer que f est continue.", 11, indent: 80),
                     line("b) En déduire la limite.", 11, indent: 80),
                     line("Exercice 2", 13), line("Question 1 : calculer.", 11), line("Question 2 : conclure.", 11)]
    let withQuestions = SeriesLayoutParser.parse(questions)
    check(withQuestions.first?.exercises.map(\.number) == ["1.1", "1.2"],
          "« Question 1 » n'est pas un exercice quand le document dit « Exercice » — \(withQuestions.first?.exercises.map(\.number) ?? [])")
    check(withQuestions.first?.exercises.first?.subQuestions.map(\.label) == ["a", "b"],
          "questions a) b) rattachées à l'exercice 1.1")
    let onlyQuestions = [line("Série 2", 16), line("Question 1", 13), line("Question 2", 13)]
    check(SeriesLayoutParser.parse(onlyQuestions).first?.exercises.count == 2,
          "sans autre mot-clé, « Question N » est un exercice")
    check(!SeriesLayoutParser.isQuestionSequence(["c", "d"]), "une liste qui ne commence pas par a/1/i n'est pas une liste de questions")

    // Fusion : une seule série, même quand les deux côtés ne s'accordent pas.
    let heuristicOne = [DetectedSeries(number: 1, title: "", exercises: [
        DetectedExercise(number: "1.1", title: "", isBonus: false),
        DetectedExercise(number: "1.2", title: "", isBonus: true),
        DetectedExercise(number: "1.5", title: "", isBonus: false, isConfident: false)
    ])]
    let aiFour = [DetectedSeries(number: 4, title: "Intégrales", exercises: [
        DetectedExercise(number: "4.1", title: "Changement de variable", isBonus: false),
        DetectedExercise(number: "4.2", title: "Intégrale impropre", isBonus: false),
        DetectedExercise(number: "4.3", title: "Fubini", isBonus: false)
    ])]
    let reconciled = SeriesAIParsing.merge(heuristic: heuristicOne, ai: aiFour, preferredSeries: 4)
    check(reconciled.count == 1 && reconciled.first?.number == 4, "une seule série, la 4 — \(reconciled.map(\.number))")
    check(reconciled.first?.exercises.map(\.number) == ["4.1", "4.2", "4.3"],
          "le « 1.5 » douteux est écarté, rien n'est dupliqué — \(reconciled.first?.exercises.map(\.number) ?? [])")
    check(reconciled.first?.exercises.first { $0.number == "4.2" }?.isBonus == true, "le bonus lu par les motifs est gardé")
    check(SeriesAIParsing.merge(heuristic: heuristicOne, ai: aiFour).first?.number == 4,
          "sans indice du document, le numéro du modèle l'emporte sur le défaut « 1 »")

    // Entrée de l'IA : mise en page conservée, tout le document dans le budget.
    var long: [PDFLayoutLine] = [line("Série 8", 16)]
    for number in 1...12 {
        long.append(line("Exercice \(number)", 13, page: number / 3))
        for _ in 0..<40 { long.append(line("Soit f une fonction continue sur un intervalle fermé borné, alors f atteint ses bornes.", 11, page: number / 3)) }
        long.append(line("a) Première question.", 11, page: number / 3, indent: 84))
    }
    let prepared = SeriesAIParsing.prepareLayout(long, seriesHint: 8)
    check(prepared.count <= SeriesAIParsing.layoutBudget, "entrée IA sous le budget (\(prepared.count) car.)")
    check(prepared.contains("# Exercice 12"), "le dernier exercice survit, marqué comme titre")
    check(prepared.contains("  a) Première question."), "le retrait d'une question est conservé")
    check(prepared.contains("série 8"), "l'indice de série est transmis")
}

print("== Import PDF de bout en bout : vrais PDF, vraie extraction ==")
do {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("studytrack-fixtures-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    func run(_ pages: [[FixtureLine]], filename: String) -> (lines: [PDFLayoutLine], series: [DetectedSeries], hint: Int?) {
        let url = directory.appendingPathComponent(filename)
        PDFFixtures.write(pages, to: url)
        guard let document = PDFDocument(url: url) else { return ([], [], nil) }
        let lines = PDFLayoutExtractor.lines(from: document)
        let hint = SeriesDocumentInference.seriesNumber(lines: lines, filename: filename)?.number
        return (lines, SeriesLayoutParser.parse(lines, defaultSeries: hint), hint)
    }

    let analyse = run(PDFFixtures.analyse, filename: "polycopie.pdf")
    check(analyse.lines.contains { $0.fontSize > 11.5 && $0.isBold }, "PDFKit rend taille et gras des titres")
    check(analyse.lines.contains { $0.startsBold && !$0.isBold }, "un titre en ligne est vu comme commençant en gras")
    let bodyIndent = analyse.lines.first { $0.trimmed.hasPrefix("Calculer") }?.indent ?? 0
    let questionIndent = analyse.lines.first { $0.trimmed.hasPrefix("a)") }?.indent ?? 0
    check(questionIndent > bodyIndent + 10, "le retrait des questions est mesuré (\(Int(bodyIndent)) → \(Int(questionIndent)))")
    check(analyse.hint == 4, "série 4 lue dans l'en-tête courant — \(analyse.hint.map(String.init) ?? "rien")")
    let four = analyse.series.first
    check(analyse.series.count == 1 && four?.number == 4, "une seule série, la 4 — \(analyse.series.map(\.number))")
    check(four?.exercises.map(\.number) == ["4.1", "4.2", "4.3", "4.4"],
          "quatre exercices, ni fantôme ni citation — \(four?.exercises.map(\.number) ?? [])")
    check(four?.exercises.first?.title == "Changement de variable", "intitulé entre parenthèses — « \(four?.exercises.first?.title ?? "") »")
    check(four?.exercises.first?.subQuestions.map(\.label) == ["a", "b"], "questions a) b) de l'exercice 4.1")
    check(four?.exercises.first { $0.number == "4.2" }?.isBonus == true, "4.2 facultatif")
    check(four?.exercises.first { $0.number == "4.3" }?.title == "Intégrale impropre",
          "titre sur la ligne suivante en page 2 — « \(four?.exercises.first { $0.number == "4.3" }?.title ?? "") »")
    let prepared = SeriesAIParsing.prepareLayout(analyse.lines, seriesHint: analyse.hint)
    check(prepared.contains("# Exercice 1") && prepared.contains("--- page 2 ---"),
          "entrée IA : titres marqués et pages séparées")

    let english = run(PDFFixtures.english, filename: "exercises.pdf")
    let seven = english.series.first
    check(english.hint == 7 && seven?.number == 7, "« Exercise Set 7 » : série 7")
    check(seven?.exercises.map(\.number) == ["7.1", "7.2", "7.3"], "trois « Problem » — \(seven?.exercises.map(\.number) ?? [])")
    check(seven?.exercises.first?.subQuestions.map(\.label) == ["a", "b"], "questions (a) (b)")
    check(seven?.exercises.first { $0.number == "7.2" }?.isBonus == true, "« optional » vaut bonus")

    let numbered = run(PDFFixtures.numbered, filename: "MATH-111_s.pdf")
    let two = numbered.series.first
    check(two?.exercises.map(\.number) == ["2.1", "2.2", "2.3"], "titres numérotés en gras — \(two?.exercises.map(\.number) ?? [])")
    check(two?.exercises.first?.title == "Espaces vectoriels", "intitulé d'un titre numéroté")

    check(SeriesDocumentInference.seriesTitle("Analyse I", courseName: "Analyse I", courseCode: "MATH-101") == "",
          "un titre de série égal au nom du cours est effacé")
    check(SeriesDocumentInference.seriesTitle("Intégrales", courseName: "Analyse I", courseCode: "MATH-101") == "Intégrales",
          "un vrai titre de série est gardé")
    check(!SeriesPDFParser.looksLikeTitle("Soit f une fonction continue sur R"), "« Soit f… » est un énoncé, pas un titre")
    check(!SeriesPDFParser.looksLikeTitle("Let f be continuous"), "« Let f… » non plus")
    check(SeriesPDFParser.looksLikeTitle("Calcul d'intégrales"), "un titre nominal reste un titre")
    check(SeriesAIParsing.parse(#"{"series":[{"number":4,"exercises":[{"number":"4.2","questions":["1.5"]}]}]}"#)
            .first?.exercises.first?.subQuestions.isEmpty == true, "une seule « question » n'en fait pas une liste")

    // Deux niveaux de questions et une liste en deux colonnes (Analyse I, série 03).
    let nested = run(PDFFixtures.nested, filename: "Analyse I Serie 03.pdf")
    let three = nested.series.first
    check(nested.series.count == 1 && three?.number == 3 && three?.title == "Suites",
          "série 3 « Suites » — \(nested.series.map { "\($0.number) \($0.title)" })")
    check(three?.exercises.map(\.number) == ["3.1", "3.2", "3.3", "3.11", "3.12"],
          "cinq exercices « Ex-03-xx » — \(three?.exercises.map(\.number) ?? [])")
    func outline(_ number: String) -> String {
        DetectedSubQuestion.outline(three?.exercises.first { $0.number == number }?.subQuestions ?? [])
    }
    check(outline("3.1") == "1(a,b,c),2(a,b,c,d,e)",
          "deux niveaux : 1(a–c) et 2(a–e), plus seulement 1 et 2 — \(outline("3.1"))")
    check(three?.exercises.first?.leafQuestionCount == 8, "huit cases réelles pour 3.1")
    check(outline("3.3") == "1,2,3,4,part",
          "liste en deux colonnes remise dans l'ordre, puis « Ensuite » — \(outline("3.3"))")
    check(outline("3.11") == "part,1,2,3",
          "la consigne avant « Ensuite » est une partie à cocher — \(outline("3.11"))")
    check(three?.exercises.first { $0.number == "3.11" }?.subQuestions.first?.text.hasPrefix("Calculer la limite") == true,
          "…avec son texte — « \(three?.exercises.first { $0.number == "3.11" }?.subQuestions.first?.text ?? "") »")
    check(outline("3.12") == "", "une liste de conditions n'est pas une liste de questions — \(outline("3.12"))")
    check(three?.exercises.first?.subQuestions.first?.text.hasPrefix("Soit (xn)") == true,
          "le texte d'une question est lu — « \(three?.exercises.first?.subQuestions.first?.text ?? "") »")
    let nestedInput = SeriesAIParsing.prepareLayout(nested.lines, seriesHint: nested.hint)
    check(!nestedInput.contains("Compilation"), "le pied de page répété n'est pas envoyé au modèle")

    // Les étiquettes, hors PDF.
    func marks(_ items: [(String, Double)]) -> [SeriesLayoutParser.QuestionMark] {
        items.map { SeriesLayoutParser.QuestionMark(label: $0.0, indent: $0.1) }
    }
    check(SeriesLayoutParser.topLevelQuestions(marks([("1", 84), ("a", 105), ("b", 105), ("2", 84), ("a", 105), ("b", 105), ("c", 106)])) == ["1", "2"],
          "premier niveau : 1, 2")
    check(DetectedSubQuestion.outline(SeriesLayoutParser.questionTree(marks([("1", 84), ("a", 105), ("b", 105), ("2", 84), ("a", 105), ("b", 105), ("c", 106)])))
            == "1(a,b),2(a,b,c)", "second niveau rattaché à sa question")
    check(SeriesLayoutParser.questionMark("1) an = 1 2) an = n 3) an = 2", allowNumbers: true, indent: 84)?.map(\.label) == ["1", "2", "3"],
          "trois questions sur une même ligne")
    check(SeriesLayoutParser.questionMark("1) Si (an) est croissante", allowNumbers: true, indent: 84)?.map(\.label) == ["1"],
          "« (an) » dans le texte n'est pas une question")
    check(SeriesLayoutParser.introListsConditions("Montrer qu'il existe une suite qui satisfait simultanément aux deux conditions suivantes :"),
          "liste de conditions reconnue")
    check(!SeriesLayoutParser.introListsConditions("Calculer les limites suivantes :"), "« limites suivantes » reste une liste de questions")
    check(SeriesLayoutParser.topLevelQuestions(marks([("1", 84), ("3", 315), ("2", 84), ("4", 315)])) == ["1", "2", "3", "4"],
          "deux colonnes triées")
    check(SeriesLayoutParser.topLevelQuestions(marks([("a", 0), ("b", 0), ("i", 0), ("j", 0)])) == ["a", "b", "i", "j"],
          "« i » dans une liste de lettres reste une lettre")
    check(SeriesLayoutParser.topLevelQuestions(marks([("i", 0), ("ii", 0), ("iii", 0), ("iv", 0)])) == ["i", "ii", "iii", "iv"],
          "chiffres romains dans l'ordre")

    // Le modèle renvoie le numéro comme titre quand le PDF n'en donne pas.
    check(!SeriesPDFParser.looksLikeTitle("Ex-03-01"), "« Ex-03-01 » n'est pas un titre")
    check(!SeriesPDFParser.looksLikeTitle("Exercice 3"), "« Exercice 3 » n'est pas un titre")
    check(SeriesPDFParser.looksLikeTitle("Exercice de synthèse"), "« Exercice de synthèse » en est un")

    // La lecture du texte l'emporte sur le modèle pour les questions.
    let local = [DetectedSeries(number: 3, title: "", exercises: [
        DetectedExercise(number: "3.10", title: "", isBonus: false,
                         subQuestions: [DetectedSubQuestion(label: "1", text: ""), DetectedSubQuestion(label: "2", text: "")])])]
    let model = [DetectedSeries(number: 3, title: "Suites", exercises: [
        DetectedExercise(number: "3.10", title: "", isBonus: false,
                         subQuestions: ["1", "2", "3"].map { DetectedSubQuestion(label: $0, text: "") })])]
    check(SeriesAIParsing.merge(heuristic: local, ai: model, aiReadsLayout: true).first?.exercises.first?.subQuestions.count == 3,
          "un modèle qui voit les pages l'emporte sur la lecture du texte")
    let localWithPart = [DetectedSeries(number: 3, title: "", exercises: [DetectedExercise(
        number: "3.11", title: "", isBonus: false,
        subQuestions: [DetectedSubQuestion(label: "", text: "Calculer lim an", kind: .part),
                       DetectedSubQuestion(label: "1"), DetectedSubQuestion(label: "2")])])]
    let seenNoPart = [DetectedSeries(number: 3, title: "", exercises: [DetectedExercise(
        number: "3.11", title: "", isBonus: false,
        subQuestions: ["1", "2", "3"].map { DetectedSubQuestion(label: $0, text: "lu") })])]
    let withPart = SeriesAIParsing.merge(heuristic: localWithPart, ai: seenNoPart, aiReadsLayout: true)
        .first?.exercises.first?.subQuestions ?? []
    check(DetectedSubQuestion.outline(withPart) == "part,1,2,3",
          "la partie sans numéro trouvée localement est remise devant les questions lues — \(DetectedSubQuestion.outline(withPart))")

    // L'identifiant se lit dans le jeton : une session sans `user_id` enregistré
    // n'est pas « non configurée ».
    let jwt = "eyJhbGciOiJIUzI1NiJ9." + Data(#"{"sub":"1b2c-uuid","role":"authenticated"}"#.utf8)
        .base64EncodedString().replacingOccurrences(of: "=", with: "") + ".sig"
    check(StoredSession.subject(ofJWT: jwt) == "1b2c-uuid", "identifiant lu dans le jeton")
    check(StoredSession.subject(ofJWT: "pas-un-jeton") == nil, "un jeton illisible ne donne rien")
    check(SeriesAIParsing.merge(heuristic: local, ai: model).first?.exercises.first?.subQuestions.count == 2,
          "questions lues dans le PDF préférées à celles du modèle")

    // Le même document lu une seconde fois donne le même résultat : l'import
    // n'a plus rien d'aléatoire côté motifs.
    check(run(PDFFixtures.analyse, filename: "polycopie.pdf").series == analyse.series, "lecture déterministe")
}

if CommandLine.arguments.contains("--bench") {
    runBenchmark()
}

print("")
if failures == 0 {
    print("✅ TOUS LES CONTRÔLES SONT PASSÉS")
} else {
    print("❌ \(failures) contrôle(s) en échec")
    exit(1)
}

// MARK: - Repères de performance (--bench)
//
// Aucun simulateur iOS n'est installé : c'est la seule mesure exécutable du
// projet. Elle porte sur la logique pure (`Domain/`), pas sur le rendu SwiftUI.
// Elle chiffre donc le coût d'**une** passe de dérivation, puis reconstitue le
// coût d'un rendu à partir du nombre de lectures que `body` effectuait.

func runBenchmark() {
    print("")
    print("== Repères de performance — semestre simulé ==")

    let benchConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    guard let benchContainer = try? ModelContainer(for: schema, configurations: [benchConfig]) else {
        print("  conteneur indisponible")
        return
    }
    let ctx = ModelContext(benchContainer)

    let start = DateUtils.addWeeks(-6, to: DateUtils.startOfWeek(Date()))
    let benchTerm = AcademicTerm(year: 2026,
                                 season: .spring,
                                 startDate: start,
                                 endDate: DateUtils.addWeeks(14, to: start),
                                 totalWeeks: 14)
    ctx.insert(benchTerm)

    let specs = [("CS-250", "Algorithmes"), ("MATH-101", "Analyse I"),
                 ("PHYS-101", "Physique I"), ("CS-251", "Structures de données"),
                 ("MATH-102", "Algèbre linéaire"), ("PHYS-102", "Physique II")]
    var benchCourses: [Course] = []
    for spec in specs {
        let course = Course(code: spec.0, name: spec.1, credits: 4, term: benchTerm)
        ctx.insert(course)

        for index in 0..<40 {
            let video = TheoryItem(course: course,
                                    sectionNumber: index / 5 + 1,
                                    number: "\(index / 5 + 1).\(index % 5 + 1)",
                                    title: "Vidéo \(index + 1)",
                                    durationSeconds: 900,
                                    plannedWeek: index % 14 + 1)
            if index % 20 < 11 { video.watchedAt = Date() }
            if index % 20 < 7 { video.summarizedAt = Date() }
            ctx.insert(video)
        }

        for s in 0..<12 {
            let series = ExerciseSeries(course: course,
                                        seriesNumber: s + 1,
                                        plannedWeek: s % 14 + 1)
            ctx.insert(series)
            for e in 0..<8 {
                let exercise = Exercise(series: series,
                                        exerciseNumber: "\(s + 1).\(e + 1)",
                                        isBonus: e == 7,
                                        sortOrder: e)
                if e < 4 { exercise.doneAt = Date() }
                if e < 2 {
                    exercise.correctedAt = Date()
                    exercise.correctness = .correct
                }
                if e == 0 { exercise.redoRequired = true }
                ctx.insert(exercise)
            }
        }
        benchCourses.append(course)
    }

    for week in 0..<16 {
        for course in benchCourses {
            for day in 0..<5 {
                ctx.insert(StudySession(course: course,
                                        taskType: TaskType.allCases[(week + day) % TaskType.allCases.count],
                                        startedAt: DateUtils.addWeeks(-week, to: DateUtils.addDays(day, to: start)),
                                        durationSeconds: 3600))
            }
        }
    }
    try? ctx.save()

    let benchAll = (try? ctx.fetch(FetchDescriptor<Course>())) ?? []
    let benchSessions = (try? ctx.fetch(FetchDescriptor<StudySession>())) ?? []
    let benchTracked = benchAll.filter(\.isTracked)
    print("  jeu : \(benchAll.count) cours · \(benchAll.reduce(0) { $0 + $1.theoryItems.count }) vidéos"
        + " · \(benchAll.reduce(0) { $0 + $1.allExercises.count }) exercices"
        + " · \(benchSessions.count) sessions"
        + " · semaine courante \(benchTracked.first?.currentWeek ?? 0)")
    print("")

    func measure(_ label: String, iterations: Int = 20, _ block: () -> Void) -> Double {
        block()
        let clock = ContinuousClock()
        let total = clock.measure {
            for _ in 0..<iterations { block() }
        }
        let ms = Double(total / Duration.milliseconds(1)) / Double(iterations)
        print("  " + label.padding(toLength: 36, withPad: " ", startingAt: 0)
            + String(format: "%8.3f ms", ms))
        return ms
    }

    print("  coût d'UNE passe de dérivation :")
    let planner = measure("DailyPlanner.todos(limit: 12)") {
        _ = DailyPlanner.todos(for: benchTracked, limit: 12)
    }
    let weeklyVideo = measure("DailyPlanner.weeklyVideoMinutes") {
        _ = DailyPlanner.weeklyVideoMinutes(for: benchTracked)
    }
    let workload = measure("WorkloadEngine.aggregate") {
        _ = WorkloadEngine.aggregate(courses: benchTracked, hoursPerCredit: 30)
    }
    let streak = measure("GamificationEngine.currentStreak") {
        _ = GamificationEngine.currentStreak(sessions: benchSessions)
    }
    let xp = measure("GamificationEngine.totalXP") {
        _ = GamificationEngine.totalXP(courses: benchAll, sessions: benchSessions)
    }
    let weekWindow = measure("sessions des 7 derniers jours") {
        let range = DateUtils.dateRange(days: 7)
        _ = benchSessions.reduce(0) { total, session in
            session.startedAt >= range.start && session.startedAt < range.end
                ? total + session.durationSeconds
                : total
        }
    }
    let trackedFilter = measure("courses.filter(isTracked)") {
        _ = benchAll.filter(\.isTracked)
    }
    let progress = measure("ProgressEngine.progress (tous cours)") {
        for course in benchTracked { _ = ProgressEngine.progress(for: course) }
    }

    // Reconstitution d'un rendu de « Aujourd'hui », à partir des lectures que
    // faisait `body` avant le correctif :
    //   todos    : 5 lectures directes + `todos.last?.id` une fois PAR LIGNE
    //   workload : 3 lectures (icône, valeur, teinte) sur la carte de la semaine
    //   tracked  : 6 lectures + `tracked.last?.id` une fois par cours
    let rows = DailyPlanner.todos(for: benchTracked, limit: 12).count
    let beforeTodos = 5 + rows
    let beforeWorkload = 3
    let beforeTracked = 6 + benchTracked.count

    let before = Double(beforeTodos) * planner
        + weeklyVideo + Double(beforeWorkload) * workload
        + streak + xp + weekWindow + Double(beforeTracked) * trackedFilter
        + progress
    let after = planner + weeklyVideo + workload
        + streak + xp + weekWindow + trackedFilter
        + progress

    func pair(_ label: String, _ old: String, _ new: String) {
        print("  " + label.padding(toLength: 30, withPad: " ", startingAt: 0)
            + old.padding(toLength: 14, withPad: " ", startingAt: 0) + new)
    }
    print("")
    print("  rendu de « Aujourd'hui »            avant         après")
    pair("DailyPlanner.todos", "×\(beforeTodos)", "×1")
    pair("WorkloadEngine.aggregate", "×\(beforeWorkload)", "×1")
    pair("courses.filter(isTracked)", "×\(beforeTracked)", "×1")
    pair("ProgressEngine.progress", "×\(benchTracked.count)", "×\(benchTracked.count) (inchangé)")
    print("")
    print(String(format: "  total des termes mesurés : %.3f ms → %.3f ms  (−%.0f %%)",
                 before, after, (before - after) / before * 100))
    print("  (hors filtres courts : évaluations, séances planifiées et tâches,")
    print("   eux aussi passés de 2 lectures à 1, négligeables devant `todos`.)")
}
