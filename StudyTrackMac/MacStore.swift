import Foundation
import CoreData
import Observation
import OSLog
import Security
import SwiftData

/// La base du Mac : le même schéma et le même conteneur iCloud que l'iPhone.
///
/// Le Mac n'importe rien de Moodle : il lit ce que l'iPhone a rangé, coche,
/// chronomètre — et iCloud rapporte tout au téléphone.
@MainActor
@Observable
final class MacStore {
    static let cloudContainerID = "iCloud.com.hczr.studytrack.app"

    let container: ModelContainer
    let isCloudSynced: Bool
    /// Pourquoi la base n'est pas celle d'iCloud, s'il y a lieu (barre latérale).
    let storeError: String?
    /// Les réglages communs à l'iPhone (relecture des cours, IA de lecture,
    /// nouveautés annoncées) : le même type, pour la même chaîne d'import.
    let preferences: SettingsStore

    /// Ce que fait iCloud : la barre latérale le dit.
    enum SyncState: Equatable {
        case idle
        case working(String)
        case synced(Date)
        case failed(String)
    }
    private(set) var syncState: SyncState = .idle

    /// Appelé quand les données changent, ici ou ailleurs (widgets du bureau).
    @ObservationIgnored var onDataChange: (() -> Void)?
    @ObservationIgnored private var pendingMerge: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let log = Logger(subsystem: "com.hczr.studytrack.mac", category: "sync")

    init(preferences: SettingsStore) {
        self.preferences = preferences
        let schema = StudyTrackSchema.current
        #if DEBUG
        // `-memoryStore` : une base vide en mémoire, sans iCloud (essais,
        // captures à côté de l'app réelle, sans toucher à ses données).
        if CommandLine.arguments.contains("-memoryStore") {
            // `cloudKitDatabase: .none` est indispensable : par défaut (`.automatic`),
            // une base « en mémoire » d'une app qui a le droit iCloud se
            // synchronise quand même — le cours d'essai de `-previewSeed` est
            // ainsi parti dans le vrai iCloud.
            container = try! ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
            isCloudSynced = false
            storeError = nil
            if CommandLine.arguments.contains("-previewSeed") {
                let container = self.container
                Task { @MainActor in Self.seedPreview(container.mainContext) }
            }
            return
        }
        #endif
        // Une copie sans signature (une compilation de contrôle, `CODE_SIGNING_ALLOWED=NO`)
        // n'a pas le droit iCloud : CloudKit **arrête l'app** au lieu de lever une
        // erreur. Elle ouvre alors une base à part, locale — jamais la vraie.
        guard Self.hasICloudEntitlement else {
            let url = MacSandboxMigration.storeURL.deletingLastPathComponent().appendingPathComponent("unsigned.store")
            container = (try? ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)]))
                ?? (try! ModelContainer(for: schema, configurations: [
                    ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)]))
            isCloudSynced = false
            storeError = "Copie non signée : base d'essai séparée, sans iCloud. Lance l'app depuis Xcode."
            return
        }
        // Hors du bac à sable, la base a son dossier (voir `MacSandboxMigration`).
        let cloud = MacSandboxMigration.isSandboxed
            ? ModelConfiguration(schema: schema, isStoredInMemoryOnly: false,
                                 cloudKitDatabase: .private(Self.cloudContainerID))
            : ModelConfiguration(schema: schema, url: MacSandboxMigration.storeURL,
                                 cloudKitDatabase: .private(Self.cloudContainerID))
        var failure: String?
        if let container = try? ModelContainer(for: schema, migrationPlan: StudyTrackMigrationPlan.self,
                                               configurations: [cloud]) {
            self.container = container
            isCloudSynced = true
        } else {
            // Comme sur l'iPhone : la même base, locale, **avec** le plan de
            // migration ; sans lui en dernier recours ; et un échec se voit.
            let local = MacSandboxMigration.isSandboxed
                ? ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none)
                : ModelConfiguration(schema: schema, url: MacSandboxMigration.storeURL, cloudKitDatabase: .none)
            if let container = try? ModelContainer(for: schema, migrationPlan: StudyTrackMigrationPlan.self, configurations: [local]) {
                self.container = container
                failure = "iCloud indisponible : base locale, rien ne se synchronise."
            } else if let container = try? ModelContainer(for: schema, configurations: [local]) {
                self.container = container
                failure = "La migration du schéma a échoué ; la base a été ouverte sans plan de migration."
            } else {
                self.container = try! ModelContainer(for: schema, configurations: [
                    ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
                failure = "La base n'a pas pu être ouverte : cette session ne sera pas conservée."
            }
            isCloudSynced = false
        }
        storeError = failure
        if let failure { AppLog.record(.error, AppLog.Category.storage, "Base de données", detail: failure) }
        // Les mêmes réparations que l'iPhone, une fois par version ; la fusion
        // des doublons, hors du fil principal.
        DataRepair.run(in: ModelContext(container))
        let launched = container
        Task { @MainActor [weak self] in
            _ = await SyncDeduplicator.runInBackground(launched)
            self?.onDataChange?()
        }
        observers.append(NotificationCenter.default.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.remoteChangeArrived() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onDataChange?() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification,
                                                                object: nil, queue: .main) { [weak self] note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { return }
            MainActor.assumeIsolated { self?.record(event) }
        })
    }

    private func record(_ event: NSPersistentCloudKitContainer.Event) {
        let kind: String
        switch event.type {
        case .setup: kind = "préparation"
        case .import: kind = "réception"
        case .export: kind = "envoi"
        @unknown default: kind = "synchronisation"
        }
        if event.endDate == nil {
            syncState = .working(kind)
        } else if let error = event.error {
            syncState = .failed(error.localizedDescription)
            log.error("iCloud \(kind, privacy: .public) : échec \(String(describing: error), privacy: .public)")
        } else {
            syncState = .synced(event.endDate ?? Date())
            let courses = (try? ModelContext(container).fetchCount(FetchDescriptor<Course>())) ?? -1
            log.notice("iCloud \(kind, privacy: .public) : ok (\(courses) cours)")
        }
    }

    /// iCloud importe par lots : on attend que ça se calme, puis on fusionne
    /// les doublons (même règle que l'iPhone, même résultat des deux côtés).
    private func remoteChangeArrived() {
        pendingMerge?.cancel()
        pendingMerge = Task { @MainActor [container, weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            _ = await SyncDeduplicator.runInBackground(container)
            self?.onDataChange?()
        }
    }

    #if DEBUG
    /// Un cours d'essai pour les captures (`-memoryStore -previewSeed`) : la
    /// vraie Série 3 d'Analyse I (le PDF du dépôt) et le vrai site Botafogo.
    private static func seedPreview(_ context: ModelContext) {
        // `-seedCode MATH-111` : un autre code (le cours Ed qui lui correspond).
        let code = CommandLine.arguments.firstIndex(of: "-seedCode").flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }
        let course = Course(code: code ?? "MATH-101", name: "Analyse I (classe inversée)", colorHex: "#4F46E5")
        course.contentSources = ["https://botafogo.epfl.ch/analyse-1-flipped/"]
        // `-seedMoodle 15221` : relier le cours d'essai à un vrai cours Moodle.
        if let index = CommandLine.arguments.firstIndex(of: "-seedMoodle"), index + 1 < CommandLine.arguments.count {
            course.contentSources.append("https://moodle.epfl.ch/course/view.php?id=\(CommandLine.arguments[index + 1])")
        }
        // `-seedSource <adresse>` : une source de plus (un MOOC Courseware…).
        if let index = CommandLine.arguments.firstIndex(of: "-seedSource"), index + 1 < CommandLine.arguments.count {
            course.contentSources.append(CommandLine.arguments[index + 1])
        }
        context.insert(course)
        let pdf = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Analyse I Serie 03.pdf")
        // `-seedSeriesURL <adresse>` : l'énoncé d'une vraie série (un PDF Moodle).
        let address = CommandLine.arguments.firstIndex(of: "-seedSeriesURL").flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }
        let series = ExerciseSeries(course: course, seriesNumber: 3, title: "Série 3", plannedWeek: course.currentWeek,
                                    dueDate: Date().addingTimeInterval(3 * 86400), urlString: address == "none" ? "" : (address ?? pdf.absoluteString))
        context.insert(series)
        for n in 1...6 {
            let exercise = Exercise(series: series, exerciseNumber: "3.\(n)", sortOrder: n)
            exercise.statement = n == 2 ? "Montrer que la suite $x_n = \\frac{an+b}{cn+d}$ est croissante si et seulement si $ad - bc \\ge 0$." : ""
            context.insert(exercise)
            if n <= 2 {
                for (i, label) in ["a", "b", "c"].enumerated() {
                    let question = SubQuestion(exercise: exercise, label: label, text: ["Calculer $x_{n+1} - x_n$.", "Étudier son signe.", "Conclure."][i],
                                               isDone: n == 1, sortOrder: i)
                    context.insert(question)
                }
            }
            if n == 1 { exercise.setDone(true); exercise.correct(.correct) }
            // `-seedReview` : un exercice en reprise, une erreur notée, deux indices (captures).
            if n == 2, CommandLine.arguments.contains("-seedReview") {
                exercise.redoPass = 0
                exercise.redoDueAt = Calendar.current.startOfDay(for: Date())
                exercise.redoWhy = "méthode : le signe du dénominateur oublié"
                exercise.redoFirstMove = "Écris $x_{n+1} - x_n$ comme une seule fraction"
                exercise.redoRequired = true
                let mistake = Mistake(exercise: exercise, kind: .method, summary: "conclu sur le signe sans vérifier que $cn + d > 0$",
                                      correction: "vérifier le signe du dénominateur avant de conclure", notion: "suites monotones", source: "claude")
                context.insert(mistake)
                exercise.recordHint(level: 1, text: "C'est une question de monotonie : regarde la différence de deux termes")
                exercise.recordHint(level: 2, text: "Étudie le signe de $x_{n+1} - x_n$ sur un dénominateur commun")
            }
        }
        // `-seedBotafogoSeries` : la vraie Série 6 du site (ses pages d'exercices), en cours.
        if CommandLine.arguments.contains("-seedBotafogoSeries") {
            let site = "https://botafogo.epfl.ch/analyse-1-flipped/"
            let botafogo = ExerciseSeries(course: course, seriesNumber: 6, title: "Série 6", plannedWeek: course.currentWeek,
                                          dueDate: Date().addingTimeInterval(2 * 86400), urlString: site + "?cours=series/AN_serie_06")
            context.insert(botafogo)
            let slugs = ["complexes_racines_1", "complexes_equations_diverses", "complexes_equation_polynomiale_2", "complexes_factorisation_polynome",
                         "complexes_factorisation_polynome_degre_3", "complexes_VF", "suites_monotone_sous_suite_diverge"]
            for (n, slug) in slugs.enumerated() {
                let exercise = Exercise(series: botafogo, exerciseNumber: "6.\(n + 1)", sortOrder: n + 1)
                exercise.statementURLString = site + "?cours=exercices/" + slug
                context.insert(exercise)
            }
        }
        for (i, title) in ["Suites réelles : définitions", "Suites monotones et bornées", "Limites et opérations"].enumerated() {
            context.insert(TheoryItem(course: course, sectionNumber: 3, number: "3.\(i + 1)", title: title, kind: .video,
                                      durationSeconds: 900, plannedWeek: course.currentWeek, sortOrder: i))
        }
        try? context.save()
    }
    #endif

    /// Le binaire a-t-il le droit iCloud (signé avec l'équipe et son profil) ?
    static var hasICloudEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) else { return false }
        return (value as? [String])?.contains("CloudKit") == true
    }
}
