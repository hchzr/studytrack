import Foundation
import CoreData
import Observation
import OSLog
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

    init() {
        let schema = StudyTrackSchema.current
        #if DEBUG
        // `-memoryStore` : une base vide en mémoire, sans iCloud (essais,
        // captures à côté de l'app réelle, sans toucher à ses données).
        if CommandLine.arguments.contains("-memoryStore") {
            // `cloudKitDatabase: .none` est indispensable : par défaut (`.automatic`),
            // une base « en mémoire » d'une app qui a le droit iCloud se
            // synchronise quand même — le cours d'essai de `-previewSeed` est
            // ainsi parti dans le vrai iCloud (`PreviewSeedCleanup` le retire).
            container = try! ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
            isCloudSynced = false
            if CommandLine.arguments.contains("-previewSeed") {
                let container = self.container
                Task { @MainActor in Self.seedPreview(container.mainContext) }
            }
            return
        }
        #endif
        // Hors du bac à sable, la base a son dossier (voir `MacSandboxMigration`).
        let cloud = MacSandboxMigration.isSandboxed
            ? ModelConfiguration(schema: schema, isStoredInMemoryOnly: false,
                                 cloudKitDatabase: .private(Self.cloudContainerID))
            : ModelConfiguration(schema: schema, url: MacSandboxMigration.storeURL,
                                 cloudKitDatabase: .private(Self.cloudContainerID))
        if let container = try? ModelContainer(for: schema, migrationPlan: StudyTrackMigrationPlan.self,
                                               configurations: [cloud]) {
            self.container = container
            isCloudSynced = true
        } else {
            let local = MacSandboxMigration.isSandboxed
                ? ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none)
                : ModelConfiguration(schema: schema, url: MacSandboxMigration.storeURL, cloudKitDatabase: .none)
            self.container = (try? ModelContainer(for: schema, configurations: [local]))
                ?? (try! ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)]))
            isCloudSynced = false
        }
        SyncDeduplicator.run(in: ModelContext(container))
        PreviewSeedCleanup.run(in: ModelContext(container))
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
            SyncDeduplicator.run(in: ModelContext(container))
        PreviewSeedCleanup.run(in: ModelContext(container))
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
        }
        for (i, title) in ["Suites réelles : définitions", "Suites monotones et bornées", "Limites et opérations"].enumerated() {
            context.insert(TheoryItem(course: course, sectionNumber: 3, number: "3.\(i + 1)", title: title, kind: .video,
                                      durationSeconds: 900, plannedWeek: course.currentWeek, sortOrder: i))
        }
        try? context.save()
    }
    #endif
}
