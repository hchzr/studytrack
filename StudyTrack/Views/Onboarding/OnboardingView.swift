import SwiftUI
import SwiftData

/// Accueil guidé en trois temps : **toi** (section, semestre) → **tes cours** →
/// **ta première série**.
///
/// Quatre écrans, dont un de présentation et un de dates que presque personne
/// ne change (l'automne commence le même lundi pour tout le monde), retardaient
/// le moment où l'app devient utile. La dernière étape importe une vraie série :
/// on arrive sur « Aujourd'hui » avec quelque chose à faire.
///
/// Aucune donnée fictive n'est créée : l'étudiant·e choisit sa section et ses
/// classes, et indique lesquelles ont des heures de cours (amphi).
struct OnboardingView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.modelContext) private var context

    @Query(sort: \Course.code) private var courses: [Course]
    @Query private var terms: [AcademicTerm]

    @State private var step = OnboardingView.initialStep
    /// Le sens du dernier changement d'étape : « Continuer » pousse vers la
    /// droite, « Retour » revient par la gauche.
    @State private var goingForward = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sectionCode = ""
    @State private var search = ""
    /// Par défaut, le semestre commence **cette semaine**. Pré-remplir « il y a
    /// deux semaines » affichait « Semaine 3 » à un étudiant dont le semestre
    /// venait de commencer : le numéro de semaine se déduit de cette date.
    /// Le semestre d'automne commence le lundi 7 septembre pour tout le monde :
    /// on ne le demande plus, on le sait. Seul le printemps varie.
    @State private var termStart = DateUtils.currentAutumnOrSpringStart().start
    @State private var termWeeks = 14
    @State private var showingCourseForm = false
    @State private var showingImport = false
    @State private var showingSeriesImport = false
    @State private var editingTerm = false
    @State private var resultMessage: String?
    @Query private var series: [ExerciseSeries]

    private let lastStep = 2

    /// Étape de départ. En Release : toujours 0 ; en Debug, `-onboardingStep N`
    /// ouvre directement une étape (cf. `PreviewLaunch`).
    static var initialStep: Int {
        #if DEBUG
        if let value = PreviewLaunch.int(PreviewLaunch.onboardingStepFlag) {
            return min(max(value, 0), 2)
        }
        #endif
        return 0
    }

    private var trackedCourses: [Course] { courses.filter(\.isTracked) }
    private var lectureCourses: [Course] { courses.filter { $0.hasLectures } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                ScrollView {
                    // `LazyVStack` : l'étape « section » construit 28 `ChoiceCard`
                    // (chacune un bouton avec fond et bordure). Les cinq écrans
                    // principaux étaient déjà paresseux, pas celui-ci.
                    LazyVStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                        switch step {
                        case 0: aboutYouStep
                        case 1: coursesStep
                        default: firstSeriesStep
                        }
                    }
                    .padding(Layout.screenPadding)
                    // L'étape « section » est une grille et gagne à occuper la
                    // largeur ; les étapes de texte restent à une mesure lisible.
                    .adaptiveColumn(maxWidth: step == 0 ? Layout.wideWidth : Layout.readableWidth)
                    .id(step)
                    .transition(reduceMotion
                                ? .opacity
                                : .push(from: goingForward ? .trailing : .leading))
                }
                footer
            }
            .background(Color(.systemGroupedBackground))
            .sheet(isPresented: $showingCourseForm) {
                CourseFormView(course: nil, defaultSectionCode: sectionCode)
            }
            .sheet(isPresented: $showingImport) {
                ImportSheet(defaultSectionCode: sectionCode)
            }
            .sheet(isPresented: $showingSeriesImport) {
                SeriesImportSheet(course: nil)
            }
        }
    }

    // MARK: En-tête

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(0...lastStep, id: \.self) { index in
                    Capsule()
                        .fill(index <= step ? Theme.accent : Color.secondary.opacity(0.2))
                        .frame(height: 4)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(titles[step])
                    .font(.title2.weight(.bold))
                Spacer(minLength: Layout.inline)
                // Voir l'app remplie avant de rien saisir : un semestre d'exemple,
                // qui s'efface depuis le profil.
                if step == 0, courses.isEmpty {
                    Button {
                        seedSample()
                    } label: {
                        Label("Exemple", systemImage: "sparkles")
                    }
                    .font(.subheadline)
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Essayer avec des données d'exemple")
                }
            }
            Text(subtitles[step])
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Layout.screenPadding)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private var titles: [String] {
        ["Bienvenue sur StudyTrack", "Tes cours", "Le contenu de tes cours"]
    }

    private var subtitles: [String] {
        ["Ta théorie, tes exercices et ton temps de travail, semaine par semaine. Commence par ta section.",
         "Importe ton horaire EPFL ou ajoute tes classes à la main.",
         "Importe la théorie et les séries depuis Moodle, Courseware ou Botafogo : tout arrive rangé par semaine."]
    }

    // MARK: Étapes

    private func seedSample() {
        SeedData.seedIfNeeded(context, settings: app.settings)
        try? context.save()
        Haptics.success()
        app.settings.hasCompletedOnboarding = true
    }

    /// Étape 1 : le semestre en une ligne (modifiable), puis la section.
    private var aboutYouStep: some View {
        VStack(alignment: .leading, spacing: Layout.cardSpacing) {
            Card {
                VStack(alignment: .leading, spacing: Layout.block) {
                    HStack(spacing: Layout.control) {
                        Image(systemName: "calendar")
                            .foregroundStyle(Theme.accentInk)
                        VStack(alignment: .leading, spacing: Layout.micro) {
                            Text("Semestre").font(.subheadline.weight(.semibold))
                            Text("Du \(DateUtils.shortDay.string(from: termStart)) · \(termWeeks) semaines")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button(editingTerm ? "OK" : "Modifier") {
                            withAnimation(Motion.snappy) { editingTerm.toggle() }
                        }
                        .font(.subheadline)
                        .buttonStyle(.borderless)
                    }
                    if editingTerm {
                        DatePicker("Début (semaine 1)", selection: $termStart, displayedComponents: .date)
                        Stepper("Durée : \(termWeeks) semaines", value: $termWeeks, in: 8...24)
                    }
                }
            }
            sectionStep
        }
    }

    private var sectionStep: some View {
        VStack(alignment: .leading, spacing: Layout.cardSpacing) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Rechercher (ex : informatique, IN, IC)", text: $search)
                    .autocorrectionDisabled()
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Effacer la recherche")
                }
            }
            .padding(12)
            .background(Theme.softBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            let results = EPFLCatalog.search(search)
            if results.isEmpty {
                EmptyCard(icon: "questionmark.circle",
                          title: "Aucune section trouvée",
                          message: "Essaie un autre mot-clé, ou continue sans section et renseigne-la plus tard.")
            } else {
                ForEach(groupedResults(results), id: \.faculty) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: group.faculty)
                        // Grille : 28 sections en une colonne sur iPad donnaient des
                        // lignes de 1030 pt, avec le bouton radio à 900 pt de son
                        // libellé. En grille adaptative, iPhone garde une colonne et
                        // l'iPad en obtient deux ou trois.
                        LazyVGrid(columns: sectionColumns,
                                  alignment: .leading,
                                  spacing: Layout.control) {
                            ForEach(group.sections) { section in
                                ChoiceCard(icon: nil,
                                           title: section.name,
                                           subtitle: section.code,
                                           isSelected: sectionCode == section.code) {
                                    sectionCode = section.code
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var sectionColumns: [GridItem] {
        [GridItem(.adaptive(minimum: Layout.gridCardMin), spacing: Layout.control)]
    }

    private func groupedResults(_ results: [EPFLSection]) -> [(faculty: String, sections: [EPFLSection])] {
        var order: [String] = []
        var buckets: [String: [EPFLSection]] = [:]
        for section in results {
            if buckets[section.faculty] == nil {
                order.append(section.faculty)
                buckets[section.faculty] = []
            }
            buckets[section.faculty]?.append(section)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    private var coursesStep: some View {
        VStack(alignment: .leading, spacing: Layout.cardSpacing) {
            // Tant qu'il n'y a aucun cours, la carte vide porte les deux
            // gestes ; ensuite, ils se rangent en une ligne discrète. Quatre
            // boutons pleins à l'écran — dont deux « ajouter » — laissaient
            // chercher lequel était le bon.
            if !courses.isEmpty {
                HStack(spacing: Layout.control) {
                    Button {
                        showingImport = true
                    } label: {
                        Label("Importer l'horaire", systemImage: "calendar.badge.plus")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                    Button {
                        showingCourseForm = true
                    } label: {
                        Label("Ajouter un cours", systemImage: "plus")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .font(.subheadline.weight(.medium))
            }

            if let resultMessage {
                Text(resultMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if courses.isEmpty {
                VStack(spacing: Layout.control) {
                    EmptyCard(icon: "calendar.badge.plus",
                              title: "Importe ton horaire EPFL",
                              message: "Le fichier .ics de ton horaire crée tes cours d'un coup, avec leurs heures de cours et d'exercices.",
                              actionTitle: "Importer mon horaire") {
                        showingImport = true
                    }
                    Button {
                        showingCourseForm = true
                    } label: {
                        Text("ou ajouter un cours à la main")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                }
            } else {
                Card(title: "Mes classes",
                     icon: "books.vertical.fill",
                     trailing: "\(trackedCourses.count) suivies") {
                    VStack(spacing: 0) {
                        ForEach(courses) { course in
                            courseToggleRow(course)
                            if course.id != courses.last?.id { Divider().padding(.vertical, 4) }
                        }
                    }
                }

                Card(title: "Heures de cours (amphi)",
                     icon: "building.columns.fill") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Active l'interrupteur pour les cours qui ont réellement des heures d'amphi. Ça n'est pas le cas de tous : les cours sans amphi ne réservent alors aucune heure « cours » dans la charge attendue.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 12) {
                            StatCard(icon: "building.columns.fill",
                                     value: "\(lectureCourses.count)/\(courses.count)",
                                     title: "avec amphi", onCard: true)
                            StatCard(icon: "clock.fill",
                                     value: DateUtils.hoursLabel(hours: courses.reduce(0) { $0 + ($1.hasLectures ? $1.weeklyLectureHours : 0) }),
                                     title: "par semaine", onCard: true)
                            StatCard(icon: "book.fill",
                                     value: DateUtils.hoursLabel(hours: courses.reduce(0) { $0 + $1.weeklyExerciseHours }),
                                     title: "exercices / sem.", onCard: true)
                        }
                    }
                }
            }
        }
    }

    private func courseToggleRow(_ course: Course) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(hex: course.colorHex))
                .frame(width: 4, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(course.displayCode).font(.subheadline.weight(.semibold))
                Text(course.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                Toggle("Suivi", isOn: Binding(
                    get: { course.isTracked },
                    set: { course.isTracked = $0; try? context.save() }
                ))
                .labelsHidden()
                .accessibilityLabel("Suivre \(course.code)")

                Toggle("A un cours", isOn: Binding(
                    get: { course.hasLectures },
                    set: { course.hasLectures = $0; try? context.save() }
                ))
                .labelsHidden()
                .tint(.blue)
                .accessibilityLabel("\(course.code) a des heures de cours")
            }
        }
    }

    /// Étape 3 : le contenu des cours, depuis leurs sites — facultatif.
    ///
    /// C'était « ta première série » en PDF. Mais une série ne dit rien de la
    /// théorie, ni des semaines : importer la page Moodle du cours remplit les
    /// deux d'un coup, et la progression hebdomadaire a enfin de quoi s'afficher.
    private var firstSeriesStep: some View {
        VStack(alignment: .leading, spacing: Layout.cardSpacing) {
            Card {
                VStack(alignment: .leading, spacing: Layout.block) {
                    Label("Depuis le site du cours", systemImage: "square.and.arrow.down.on.square")
                        .font(.headline)
                    Text("Connecte-toi à Moodle ou Courseware dans l'app, ouvre un cours : vidéos, supports et séries sont lus semaine par semaine, et tu relis avant d'importer. Le polycopié d'Analyse de Botafogo s'importe sans connexion.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        app.router.openContentImport()
                    } label: {
                        Label(importedTheory + series.count == 0 ? "Importer un cours" : "Importer un autre cours",
                              systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(trackedCourses.isEmpty)
                    Button {
                        showingSeriesImport = true
                    } label: {
                        Label("Ou le PDF d'une série", systemImage: "doc.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(trackedCourses.isEmpty)
                    if trackedCourses.isEmpty {
                        Text("Ajoute d'abord un cours à l'étape précédente.")
                            .font(.caption)
                            .foregroundStyle(Color.orange.accessibleInk)
                    }
                }
            }
            if importedTheory + series.count > 0 {
                Card(title: "Déjà importé", icon: "checkmark.circle.fill") {
                    VStack(alignment: .leading, spacing: Layout.snug) {
                        ForEach(trackedCourses.filter { !$0.theoryItems.isEmpty || !$0.series.isEmpty }) { course in
                            Text("\(course.displayCode) · \(course.theoryItems.count) théorie · \(course.series.count) série\(course.series.count > 1 ? "s" : "")")
                                .font(.subheadline)
                        }
                    }
                }
            }
            Text("Tu peux passer cette étape : chaque cours a un bouton « + › Importer ». Section, semestre et cours restent modifiables depuis le profil.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var importedTheory: Int { trackedCourses.reduce(0) { $0 + $1.theoryItems.count } }

    // MARK: Pied

    private var footer: some View {
        HStack(spacing: 12) {
            if step > 0 {
                Button {
                    Haptics.tap()
                    goingForward = false
                    withAnimation(Motion.step) { step -= 1 }
                } label: {
                    Text("Retour")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
            }

            Button {
                Haptics.tap()
                advance()
            } label: {
                Text(step == lastStep ? (series.isEmpty ? "Passer et terminer" : "Terminer") : "Continuer")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(step == 0 && sectionCode.isEmpty && !search.isEmpty && EPFLCatalog.search(search).isEmpty)
        }
        .padding(Layout.screenPadding)
        .background(.bar)
    }

    private func advance() {
        if step < lastStep {
            goingForward = true
            withAnimation(Motion.step) { step += 1 }
        } else {
            finish()
        }
    }

    private func finish() {
        let term = resolvedTerm()
        for course in courses where course.term == nil {
            course.term = term
        }
        if !sectionCode.isEmpty {
            app.settings.sectionCode = sectionCode
            for course in courses where course.sectionCode.isEmpty {
                course.sectionCode = sectionCode
            }
        }
        try? context.save()
        app.settings.hasCompletedOnboarding = true
        // La demande de notifications arrive **ici**, au terme d'une configuration
        // que l'étudiant·e vient de faire — et non plus au lancement de l'app, où
        // une alerte système sans contexte recouvrait le premier écran.
        let notifications = app.notifications
        Task { _ = await notifications.requestAuthorization() }
    }

    private func resolvedTerm() -> AcademicTerm {
        // Un semestre existe déjà (créé par l'import de l'horaire) : les dates
        // saisies ici le corrigent au lieu d'en créer un second.
        if let existing = AcademicTerm.resolve(from: terms) {
            let start = DateUtils.startOfWeek(termStart)
            existing.startDate = start
            existing.totalWeeks = termWeeks
            existing.endDate = DateUtils.addTeachingWeeks(termWeeks, to: start)
            existing.year = Calendar.current.component(.year, from: start)
            existing.season = DateUtils.monthNumber(start) >= 8 ? .autumn : .spring
            return existing
        }
        let term = AcademicTerm(year: Calendar.current.component(.year, from: termStart),
                                season: DateUtils.monthNumber(termStart) >= 8 ? .autumn : .spring,
                                startDate: DateUtils.startOfWeek(termStart),
                                endDate: DateUtils.addTeachingWeeks(termWeeks, to: DateUtils.startOfWeek(termStart)),
                                totalWeeks: termWeeks)
        context.insert(term)
        return term
    }
}

extension AppContainer {
    /// Nom lisible de la section, avec repli quand aucune n'est choisie.
    func sectionDisplayName(_ code: String) -> String {
        guard !code.isEmpty else { return "Non renseignée" }
        return EPFLCatalog.section(code: code).map { "\($0.name) (\($0.code))" } ?? code
    }
}


