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
        // `-seedFiche` : une fiche de révision et sa carte (liens, schémas, phrases en clair) pour les captures.
        if CommandLine.arguments.contains("-seedFiche") { seedFiche(course) }
        try? context.save()
    }

    /// Une petite fiche d'analyse (trois chapitres, quatorze notions) et ce que Claude en écrirait : de quoi
    /// voir la carte, les schémas, le parcours et la page d'une notion.
    private static func seedFiche(_ course: Course) {
        typealias E = RevisionSheet.Entry
        func e(_ id: String, _ kind: E.Kind, _ title: String, _ body: String) -> E { E(id: id, kind: kind, title: title, body: body, source: "Cours") }
        let sheet = RevisionSheet(origin: .ai, generatedAt: Date(), chapters: [
            .init(id: "c0", title: "Suites réelles", entries: [
                e("a", .definition, "Définition 1.1 (suite bornée)", "Une suite $(u_n)$ est bornée s'il existe $M$ tel que $|u_n| \\le M$ pour tout $n$."),
                e("b", .definition, "Définition 1.2 (limite)", "$u_n \\to \\ell$ si pour tout $\\varepsilon > 0$ il existe $N$ tel que $|u_n - \\ell| < \\varepsilon$ dès que $n \\ge N$."),
                e("c", .theorem, "Théorème 1.3 (suite monotone bornée)", "Par la définition 1.1 : toute suite monotone et bornée converge."),
                e("d", .method, "Montrer qu'une suite converge", "1. Est-elle monotone ? 2. Est-elle bornée ? Alors le théorème 1.3 conclut. Sinon, la proposition 2.1."),
                e("e", .pitfall, "Piège : borné n'est pas convergent", "Une suite bornée peut osciller : $(-1)^n$ est bornée sans converger."),
            ]),
            .init(id: "c1", title: "Suites de Cauchy", entries: [
                e("f", .definition, "Définition 2.0 (suite de Cauchy)", "$(u_n)$ est de Cauchy si $|u_n - u_m|$ devient petit quand $n,m$ grandissent."),
                e("g", .proposition, "Proposition 2.1 (Cauchy implique convergence)", "Dans $\\mathbb{R}$, par la définition 2.0 : une suite de Cauchy converge."),
                e("h", .pitfall, "Piège : Cauchy dans $\\mathbb{Q}$", "Dans $\\mathbb{Q}$ une suite de Cauchy peut ne pas converger."),
            ]),
            .init(id: "c2", title: "Séries numériques", entries: [
                e("i", .definition, "Définition 3.1 (série)", "La série $\\sum u_n$ converge si la suite de ses sommes partielles converge (définition 1.2)."),
                e("j", .theorem, "Théorème 3.2 (condition nécessaire)", "Si $\\sum u_n$ converge alors $u_n \\to 0$ ; par la définition 3.1."),
                e("k", .method, "Étudier la convergence d'une série", "Terme général → 0 ? (théorème 3.2) Puis comparer, ou critère de d'Alembert."),
                e("l", .formula, "Formule 3.3 (série géométrique)", "$\\sum_{n\\ge 0} q^n = \\frac{1}{1-q}$ si $|q| < 1$."),
                e("m", .pitfall, "Piège : la réciproque du théorème 3.2", "$u_n \\to 0$ ne suffit pas : la série harmonique diverge."),
                e("n", .example, "Exemple : série harmonique", "$\\sum 1/n$ diverge bien que $1/n \\to 0$."),
            ]),
        ])
        course.revisionSheet = sheet
        let answer = """
        {"entries":[
         {"id":"e3","gist":"Une suite qui ne fait que monter sans dépasser un plafond finit forcément par se poser quelque part.","why":"C'est le moyen le plus rapide de prouver qu'une limite existe sans la connaître.","example":"$u_n = 1 - 1/n$ monte et reste sous 1.","question":"Pourquoi faut-il « bornée » dans le théorème ?","answer":"Sans plafond, une suite qui monte peut aller à l'infini : elle ne converge pas."},
         {"id":"e2","gist":"La limite, c'est le nombre dont les termes finissent par rester aussi proches qu'on veut.","why":"Toute l'analyse repose sur cette définition.","question":"Que veut dire « pour tout epsilon » ?","answer":"Aussi petite que soit la distance demandée, on la respecte à partir d'un certain rang."},
         {"id":"e10","gist":"Si une série converge, ses termes doivent s'éteindre.","why":"Un test d'élimination immédiat.","question":"La réciproque est-elle vraie ?","answer":"Non : la série harmonique."},
         {"id":"e7","gist":"Les termes se rapprochent entre eux : ils doivent donc se rapprocher de quelque chose."}],
         "links":[{"from":"e3","to":"e1","relation":"needs","note":"un plafond et un plancher"},{"from":"e3","to":"e2","relation":"needs","note":"converger, c'est avoir une limite"},
                  {"from":"e7","to":"e6","relation":"needs"},{"from":"e5","to":"e3","relation":"contrast","note":"borné seul ne suffit pas"},
                  {"from":"e10","to":"e9","relation":"needs"},{"from":"e9","to":"e2","relation":"uses","note":"somme partielle qui converge"},
                  {"from":"e13","to":"e10","relation":"contrast","note":"la réciproque est fausse"},{"from":"e14","to":"e13","relation":"example"}],
         "schemas":[
          {"title":"Montrer qu'une suite converge","kind":"tree","summary":"Quelle méthode choisir selon ce qu'on sait de la suite.","nodes":[
            {"id":"q1","label":"La suite est-elle monotone ?"},{"id":"q2","label":"Est-elle bornée ?","entry":"e1"},{"id":"r1","label":"Elle converge","entry":"e3","detail":"théorème 1.3"},
            {"id":"q3","label":"Est-elle de Cauchy ?","entry":"e6"},{"id":"r2","label":"Chercher autre chose","detail":"sous-suites, comparaison"}],
           "edges":[{"from":"q1","to":"q2","label":"oui"},{"from":"q1","to":"q3","label":"non"},{"from":"q2","to":"r1","label":"oui"},{"from":"q2","to":"r2","label":"non"},{"from":"q3","to":"r1","label":"oui"},{"from":"q3","to":"r2","label":"non"}]},
          {"title":"Qui découle de quoi","kind":"dependencies","nodes":[
            {"id":"a","label":"Limite","entry":"e2"},{"id":"b","label":"Suite bornée","entry":"e1"},{"id":"c","label":"Monotone bornée converge","entry":"e3"},{"id":"d","label":"Cauchy converge","entry":"e7"},{"id":"e","label":"Série","entry":"e9"},{"id":"f","label":"Terme général → 0","entry":"e10"}],
           "edges":[{"from":"a","to":"c"},{"from":"b","to":"c"},{"from":"a","to":"d"},{"from":"a","to":"e"},{"from":"e","to":"f"}]},
          {"title":"Suite ou série","kind":"comparison","columns":["Suite","Série"],"rows":[["Objet","$u_n$","$\\sum u_n$"],["Converge si","$u_n \\to \\ell$","les sommes partielles convergent"],["Condition nécessaire","aucune","$u_n \\to 0$"]]}]}
        """
        var map = StudyMap()
        let (_, ids) = StudyMapAI.prompt(course: course.name, sheet: sheet)
        // Le LaTeX est écrit avec une seule barre oblique ci-dessus : en JSON, chacune se double.
        map = StudyMapAI.apply(answer: answer.replacingOccurrences(of: "\\", with: "\\\\"), sheet: sheet, ids: ids, to: map) ?? map
        let keyed = sheet.keyed
        map.progress[keyed[0].key] = .init(level: .solid, at: Date())
        map.progress[keyed[1].key] = .init(level: .solid, at: Date())
        map.progress[keyed[2].key] = .init(level: .shaky, at: Date())
        map.customNodes = [.init(id: "i1", title: "Penser à l'escalier de Cantor ?", note: nil, parent: keyed[2].key)]
        course.studyMap = map
    }
    #endif

    /// Le binaire a-t-il le droit iCloud (signé avec l'équipe et son profil) ?
    static var hasICloudEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) else { return false }
        return (value as? [String])?.contains("CloudKit") == true
    }
}
