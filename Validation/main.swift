import Foundation
import SwiftData

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

let schema = Schema([
    AcademicTerm.self,
    Course.self,
    TheoryItem.self,
    ExerciseSeries.self,
    Exercise.self,
    StudySession.self,
    Exam.self,
    PlannedSession.self,
    LinkedTask.self,
    LinkedCalendarEvent.self,
    StudyGroup.self,
    GroupMember.self,
    GroupSeriesCompletion.self,
    GroupItemCompletion.self
])

print("== Conteneur SwiftData (en mémoire) ==")
let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
let container = try ModelContainer(for: schema, configurations: [configuration])
let context = ModelContext(container)
check(schema.entities.count == 14, "schéma : \(schema.entities.count) entités")

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
check(bareSeries.count == 1 && bareSeries[0].exercises.map(\.number) == ["1", "2"],
      "« Exercice 1 / Exercice 2 » donne deux exercices")

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
    check(s.exercises.map(\.number) == ["1", "2", "3"],
          "Algèbre : trois exercices — \(s.exercises.map(\.number).joined(separator: ", "))")
    check(s.exercises.first?.title.isEmpty == true,
          "Algèbre : « solution générale. » n'est pas retenu comme titre — « \(s.exercises.first?.title ?? "") »")
    check(s.exercises.first { $0.number == "2" }?.title.isEmpty == true,
          "Algèbre : les métadonnées « Type : … Défi : … » ne polluent pas le titre")
    check(s.exercises.first { $0.number == "3" }?.title.isEmpty == true,
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
