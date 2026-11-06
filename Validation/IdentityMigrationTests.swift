import CoreData
import Foundation
import SwiftData

// Contrôles de la recopie de base (StudyTrack/Domain/StoreCopier.swift), celle du
// passage de StudyTrack à Polymestre : l'ancienne base est relue par Core Data et
// recopiée par identifiant dans la nouvelle, puis vérifiée.
//
// Les bases sont de vrais fichiers SQLite écrits par SwiftData avec le schéma de
// l'app : c'est ce qui prouve que le modèle Core Data tiré du schéma ouvre la base
// d'origine, et que SwiftData relit ensuite la copie.

func identityMigrationResults() -> [(Bool, String)] {
    var results: [(Bool, String)] = []
    do { try identityMigrationChecks(&results) } catch {
        results.append((false, "migration : une vérification a levé une erreur : \(error)"))
    }
    return results
}

private struct MigrationFixture {
    let term = UUID(), course = UUID(), series = UUID(), exercise = UUID()
    let question = UUID(), point = UUID(), session = UUID()
}

private func writeFixture(_ f: MigrationFixture, to url: URL) throws {
    let container = try ModelContainer(for: StudyTrackSchema.current,
                                       configurations: [ModelConfiguration(schema: StudyTrackSchema.current, url: url, cloudKitDatabase: .none)])
    let context = ModelContext(container)
    let term = AcademicTerm.syncBlank(); term.id = f.term; term.name = "Automne 2026"
    let course = Course.syncBlank(); course.id = f.course; course.code = "MATH-101"; course.name = "Analyse I"; course.term = term
    let series = ExerciseSeries.syncBlank(); series.id = f.series; series.title = "Série 3"; series.course = course
    let exercise = Exercise.syncBlank(); exercise.id = f.exercise; exercise.title = "Exercice 2"; exercise.series = series
    let question = SubQuestion.syncBlank(); question.id = f.question; question.label = "1"; question.exercise = exercise
    let point = SubQuestion.syncBlank(); point.id = f.point; point.label = "a"; point.exercise = exercise; point.parent = question
    let session = StudySession.syncBlank(); session.id = f.session; session.durationSeconds = 1_500
    session.course = course; session.exercise = exercise
    for object in [term, course, series, exercise, question, point, session] as [any PersistentModel] { context.insert(object) }
    try context.save()
}

/// Une base ouverte par Core Data avec le modèle tiré du schéma de l'app.
private func coreDataStore(_ url: URL, readOnly: Bool) throws -> NSPersistentContainer {
    guard let model = NSManagedObjectModel.makeManagedObjectModel(for: SchemaV1.models) else {
        throw NSError(domain: "migration", code: 1, userInfo: [NSLocalizedDescriptionKey: "modèle Core Data introuvable"])
    }
    let container = NSPersistentContainer(name: url.deletingPathExtension().lastPathComponent, managedObjectModel: model)
    let description = NSPersistentStoreDescription(url: url)
    description.isReadOnly = readOnly
    description.shouldAddStoreAsynchronously = false
    description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
    container.persistentStoreDescriptions = [description]
    var failure: Error?
    container.loadPersistentStores { _, error in failure = error }
    if let failure { throw failure }
    return container
}

private func identityMigrationChecks(_ results: inout [(Bool, String)]) throws {
    func note(_ ok: Bool, _ label: String) { results.append((ok, label)) }

    // 0. Les décisions entre appareils (IdentityMigrationPlan).
    do {
        typealias Plan = IdentityMigrationPlan
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let a = UUID(), b = UUID(), c = UUID()
        let done = Plan.Lock(owner: "iPhone", startedAt: now.addingTimeInterval(-600), completedAt: now.addingTimeInterval(-500), ids: [a, b])
        note(Plan.decide(legacyIDs: [a, b], lock: done, storeIDs: [], me: "Mac", now: now) == .nothing,
             "migration (plan) : un appareil qui n'a rien de plus que le verrou ne copie rien")
        if case .wait = Plan.decide(legacyIDs: [a, b, c], lock: done, storeIDs: [a], me: "Mac", now: now) {
            note(true, "migration (plan) : ses objets propres attendent que la nouvelle base ait reçu ceux du verrou")
        } else { note(false, "migration (plan) : ses objets propres attendent que la nouvelle base ait reçu ceux du verrou") }
        note(Plan.decide(legacyIDs: [a, b, c], lock: done, storeIDs: [a, b], me: "Mac", now: now) == .copyOnly([c]),
             "migration (plan) : une fois tout reçu, il ne copie que ce qu'il est seul à avoir")
        let running = Plan.Lock(owner: "iPhone", startedAt: now.addingTimeInterval(-60), completedAt: nil, ids: [])
        if case .wait = Plan.decide(legacyIDs: [a], lock: running, storeIDs: [], me: "Mac", now: now) {
            note(!Plan.takeOver(running, me: "Mac", now: now), "migration (plan) : pendant qu'un autre copie, on attend")
        } else { note(false, "migration (plan) : pendant qu'un autre copie, on attend") }
        let abandoned = Plan.Lock(owner: "iPhone", startedAt: now.addingTimeInterval(-3_600), completedAt: nil, ids: [])
        note(Plan.takeOver(abandoned, me: "Mac", now: now) && Plan.decide(legacyIDs: [a], lock: abandoned, storeIDs: [], me: "Mac", now: now) == .copyAll,
             "migration (plan) : un verrou abandonné depuis une heure est repris")
        note(Plan.decide(legacyIDs: [a], lock: running, storeIDs: [], me: "iPhone", now: now) == .copyAll,
             "migration (plan) : l'appareil qui tenait le verrou reprend sa copie après un arrêt")
        let many = Set((0..<2_500).map { _ in UUID() })
        let blob = Plan.encode(many)
        note(blob.count == 40_000 && Plan.decode(blob) == many, "migration (plan) : 2 500 identifiants tiennent en 40 Ko et se relisent à l'identique")
    }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("studytrack-migration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let f = MigrationFixture()
    let oldURL = dir.appendingPathComponent("old.store")
    let newURL = dir.appendingPathComponent("new.store")
    try writeFixture(f, to: oldURL)

    // 1. Copie complète.
    let old = try coreDataStore(oldURL, readOnly: true)
    let fresh = try coreDataStore(newURL, readOnly: false)
    let before = try StoreCopier.counts(in: old.viewContext)
    let report = try StoreCopier.copyMissing(from: old.viewContext, to: fresh.viewContext)
    note(before["Course"] == 1 && before["SubQuestion"] == 2 && before["StudySession"] == 1,
         "migration : Core Data ouvre la base écrite par SwiftData avec le modèle tiré du schéma")
    note(report.copied == 7 && report.source == 7, "migration : les sept objets sont copiés (\(report.summary))")
    note(try StoreCopier.missing(from: old.viewContext, in: fresh.viewContext).isEmpty,
         "migration : la vérification ne trouve aucun identifiant manquant")
    note(try StoreCopier.counts(in: old.viewContext) == before, "migration : l'ancienne base n'a pas changé")
    note(try StoreCopier.counts(in: fresh.viewContext) == before, "migration : la nouvelle base a autant d'objets, entité par entité")

    // 2. Rejouer ne double rien.
    let again = try StoreCopier.copyMissing(from: old.viewContext, to: fresh.viewContext)
    note(again.copied == 0 && again.entities["Course"]?.alreadyThere == 1, "migration : une seconde passe ne copie rien")
    note(try StoreCopier.counts(in: fresh.viewContext) == before, "migration : une seconde passe ne crée aucun doublon")

    // 3. SwiftData relit la copie, relations comprises.
    for store in fresh.persistentStoreCoordinator.persistentStores { try fresh.persistentStoreCoordinator.remove(store) }
    do {
        // Comme l'app l'ouvre : avec le plan de migration.
        let container = try ModelContainer(for: StudyTrackSchema.current, migrationPlan: StudyTrackMigrationPlan.self,
                                           configurations: [ModelConfiguration(schema: StudyTrackSchema.current, url: newURL, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        let courses = try context.fetch(FetchDescriptor<Course>())
        let course = courses.first
        note(courses.count == 1 && course?.id == f.course && course?.code == "MATH-101" && course?.name == "Analyse I",
             "migration : SwiftData (avec le plan de migration de l'app) relit le cours copié, mêmes identifiant et champs")
        note(course?.term?.id == f.term && course?.term?.name == "Automne 2026", "migration : le cours garde son semestre")
        let series = course?.series.first
        note(series?.id == f.series && series?.exercises.first?.id == f.exercise, "migration : cours → série → exercice, dans les deux sens")
        let questions = try context.fetch(FetchDescriptor<SubQuestion>())
        let point = questions.first { $0.id == f.point }
        let question = questions.first { $0.id == f.question }
        note(point?.parent?.id == f.question && question?.children.map(\.id) == [f.point] && point?.exercise?.id == f.exercise,
             "migration : une sous-question garde sa question parente (relation vers la même entité)")
        let session = try context.fetch(FetchDescriptor<StudySession>()).first
        note(session?.durationSeconds == 1_500 && session?.course?.id == f.course && session?.exercise?.id == f.exercise,
             "migration : la session garde sa durée, son cours et son exercice")
    }

    // 4. Copie partielle : ce qui manque est recopié et rattaché à ce qui existe déjà.
    let partialURL = dir.appendingPathComponent("partial.store")
    let partial = try coreDataStore(partialURL, readOnly: false)
    _ = try StoreCopier.copyMissing(from: old.viewContext, to: partial.viewContext)
    let removal = NSFetchRequest<NSManagedObject>(entityName: "Exercise")
    for exercise in try partial.viewContext.fetch(removal) { partial.viewContext.delete(exercise) }
    try partial.viewContext.save()
    let gap = try StoreCopier.missing(from: old.viewContext, in: partial.viewContext)
    note(gap["Exercise"] == [f.exercise] && gap["SubQuestion"]?.count == 2,
         "migration : la vérification nomme l'exercice manquant et ses sous-questions")
    let repair = try StoreCopier.copyMissing(from: old.viewContext, to: partial.viewContext)
    note(repair.copied == 3 && repair.entities["ExerciseSeries"]?.alreadyThere == 1,
         "migration : seuls l'exercice et ses sous-questions sont recopiés (\(repair.summary))")
    let exercise = try partial.viewContext.fetch(removal).first
    let seriesOfExercise = exercise?.value(forKey: "series") as? NSManagedObject
    note(seriesOfExercise?.value(forKey: "id") as? UUID == f.series,
         "migration : l'exercice recopié est rattaché à la série déjà présente")
    let sessionRequest = NSFetchRequest<NSManagedObject>(entityName: "StudySession")
    let keptSession = try partial.viewContext.fetch(sessionRequest).first
    note((keptSession?.value(forKey: "exercise") as? NSManagedObject)?.value(forKey: "id") as? UUID == f.exercise,
         "migration : la session déjà présente retrouve son exercice recopié (le lien de l'ancienne base revient)")
    let sessions = try partial.viewContext.fetch(sessionRequest)
    note(sessions.count == 1 && sessions.first?.value(forKey: "durationSeconds") as? Int == 1_500,
         "migration : la session déjà présente n'est ni doublée ni réécrite")
    note(try StoreCopier.missing(from: old.viewContext, in: partial.viewContext).isEmpty,
         "migration : après réparation, plus rien ne manque")

    // 5. Doublons de la source (cas relevés dans une vraie base) : copies identiques,
    //    copie qui a perdu un lien, copie rattachée à une question d'un autre exercice.
    let dupURL = dir.appendingPathComponent("duplicates.store")
    let session = UUID(), lone = UUID(), stray = UUID()
    let stamp = Date(timeIntervalSince1970: 1_793_000_000)
    let rightParent = UUID(), wrongParent = UUID(), exerciseA = UUID(), exerciseB = UUID()
    do {
        let container = try ModelContainer(for: StudyTrackSchema.current,
                                           configurations: [ModelConfiguration(schema: StudyTrackSchema.current, url: dupURL, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        let a = Exercise.syncBlank(); a.id = exerciseA; a.title = "A"
        let b = Exercise.syncBlank(); b.id = exerciseB; b.title = "B"
        let right = SubQuestion.syncBlank(); right.id = rightParent; right.label = "c"; right.exercise = a
        let wrong = SubQuestion.syncBlank(); wrong.id = wrongParent; wrong.label = "5"; wrong.exercise = b
        for _ in 0..<2 {
            let s = StudySession.syncBlank(); s.id = session; s.durationSeconds = 600; s.exercise = a; s.startedAt = stamp; s.createdAt = stamp
            context.insert(s)
        }
        let loneWithParent = SubQuestion.syncBlank(); loneWithParent.id = lone; loneWithParent.label = "i"
        loneWithParent.exercise = a; loneWithParent.parent = right
        let loneWithout = SubQuestion.syncBlank(); loneWithout.id = lone; loneWithout.label = "i"; loneWithout.exercise = a
        let strayWrong = SubQuestion.syncBlank(); strayWrong.id = stray; strayWrong.label = "ii"
        strayWrong.exercise = a; strayWrong.parent = wrong
        let strayRight = SubQuestion.syncBlank(); strayRight.id = stray; strayRight.label = "ii"
        strayRight.exercise = a; strayRight.parent = right
        for object in [a, b, right, wrong, loneWithParent, loneWithout, strayWrong, strayRight] as [any PersistentModel] {
            context.insert(object)
        }
        try context.save()
    }
    let dupSource = try coreDataStore(dupURL, readOnly: true)
    let dupTarget = try coreDataStore(dir.appendingPathComponent("deduplicated.store"), readOnly: false)
    let merged = try StoreCopier.copyMissing(from: dupSource.viewContext, to: dupTarget.viewContext)
    note(merged.entities["StudySession"]?.copied == 1 && merged.entities["StudySession"]?.mergedDuplicates == 1,
         "migration : deux sessions identiques de même identifiant n'en font qu'une")
    note(merged.entities["SubQuestion"]?.unique == 4 && merged.entities["SubQuestion"]?.copied == 4,
         "migration : les sous-questions en double sont fondues (4 identifiants, 4 objets)")
    note(try StoreCopier.uniqueCounts(in: dupSource.viewContext) == StoreCopier.uniqueCounts(in: dupTarget.viewContext),
         "migration : autant d'identifiants distincts avant et après")
    func subQuestion(_ id: UUID) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "SubQuestion")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return try dupTarget.viewContext.fetch(request).first
    }
    func parentID(_ id: UUID) throws -> UUID? {
        ((try subQuestion(id))?.value(forKey: "parent") as? NSManagedObject)?.value(forKey: "id") as? UUID
    }
    note(try parentID(lone) == rightParent, "migration : une copie sans parent ne fait pas perdre le parent de l'autre")
    note(try parentID(stray) == rightParent,
         "migration : deux parents différents → celui du même exercice est gardé")
    // 6. Copie limitée (appareil qui n'a pas le verrou) : seulement ses objets, reliés à ceux déjà là.
    let limited = try coreDataStore(dir.appendingPathComponent("limited.store"), readOnly: false)
    _ = try StoreCopier.copyMissing(from: dupSource.viewContext, to: limited.viewContext, only: [exerciseA, rightParent])
    let onlyMine = try StoreCopier.copyMissing(from: dupSource.viewContext, to: limited.viewContext, only: [lone])
    let limitedIDs = try StoreCopier.allIDs(in: limited.viewContext)
    note(onlyMine.copied == 1 && limitedIDs == [exerciseA, rightParent, lone],
         "migration : une copie limitée ne copie que les identifiants demandés")
    let loneCopy = try limited.viewContext.fetch({ () -> NSFetchRequest<NSManagedObject> in
        let r = NSFetchRequest<NSManagedObject>(entityName: "SubQuestion"); r.predicate = NSPredicate(format: "id == %@", lone as CVarArg); return r }()).first
    note(((loneCopy?.value(forKey: "parent") as? NSManagedObject)?.value(forKey: "id") as? UUID) == rightParent
         && ((loneCopy?.value(forKey: "exercise") as? NSManagedObject)?.value(forKey: "id") as? UUID) == exerciseA,
         "migration : l'objet copié seul se rattache à sa question et à son exercice déjà présents")

    note(merged.conflicts == [StoreCopier.Conflict(entity: "SubQuestion", id: stray, key: "parent")],
         "migration : ce désaccord est rapporté comme conflit, et c'est le seul (\(merged.conflicts.map { "\($0.key)" }))")
}
