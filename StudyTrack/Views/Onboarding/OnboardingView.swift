import SwiftUI
import SwiftData

/// Accueil guidé : section → cours → semestre.
///
/// Aucune donnée fictive n'est créée : l'étudiant·e choisit sa section et ses
/// classes, et indique lesquelles ont des heures de cours (amphi).
struct OnboardingView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.modelContext) private var context

    @Query(sort: \Course.code) private var courses: [Course]
    @Query private var terms: [AcademicTerm]

    @State private var step = OnboardingView.initialStep
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
    @State private var resultMessage: String?

    private let lastStep = 3

    /// Étape de départ. En Release : toujours 0 ; en Debug, `-onboardingStep N`
    /// ouvre directement une étape (cf. `PreviewLaunch`).
    static var initialStep: Int {
        #if DEBUG
        if let value = PreviewLaunch.int(PreviewLaunch.onboardingStepFlag) {
            return min(max(value, 0), 3)
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
                        case 0: welcomeStep
                        case 1: sectionStep
                        case 2: coursesStep
                        default: termStep
                        }
                    }
                    .padding(Layout.screenPadding)
                    // L'étape « section » est une grille et gagne à occuper la
                    // largeur ; les étapes de texte restent à une mesure lisible.
                    .adaptiveColumn(maxWidth: step == 1 ? Layout.wideWidth : Layout.readableWidth)
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
            Text(titles[step])
                .font(.title2.weight(.bold))
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
        ["Bienvenue sur StudyTrack", "Ta section", "Tes cours", "Ton semestre"]
    }

    private var subtitles: [String] {
        ["Suis ta théorie, tes exercices et ton temps de travail — sans rien oublier.",
         "Choisis ta section EPFL : elle sera associée à tes cours.",
         "Ajoute tes classes et indique celles qui ont des heures de cours (amphi).",
         "Indique les dates du semestre pour que le suivi hebdomadaire soit juste."]
    }

    // MARK: Étapes

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: Layout.cardSpacing) {
            Card {
                VStack(alignment: .leading, spacing: 16) {
                    feature(icon: TaskType.video.icon,
                            title: "Théorie, quel que soit le support",
                            detail: "Vidéo 1.1, chapitre 2.3, lecture ou diapositives — durée quand elle existe, date de travail et date de résumé.")
                    Divider()
                    feature(icon: TaskType.exercise.icon,
                            title: "Exercices et bonus",
                            detail: "Exercice 1.1, 1.2… avec le sureté de réponse en vert / orange / rouge.")
                    Divider()
                    feature(icon: TaskType.correction.icon,
                            title: "Corrections",
                            detail: "Juste, moyennement juste ou faux, et ce qui est à refaire.")
                    Divider()
                    feature(icon: "clock.fill",
                            title: "Temps de travail et charge EPFL",
                            detail: "Chrono par matière et par type, comparé aux heures attendues.")
                    Divider()
                    feature(icon: "person.3.fill",
                            title: "Groupes et horaire",
                            detail: "Classements, planning partagé, import de ton horaire .ics.")
                }
            }

            // Aucune donnée n'est inventée sans le demander. Mais on peut la
            // **demander** : un semestre d'exemple montre l'app remplie en un tap,
            // et s'efface depuis Profil › Données.
            Card {
                VStack(alignment: .leading, spacing: Layout.block) {
                    Text("Tu veux d'abord voir l'app remplie ?")
                        .font(.subheadline.weight(.semibold))
                    Text("Un semestre d'exemple (trois cours, des séries, dix jours de sessions) s'installe, et se supprime en un geste depuis le profil.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        seedSample()
                    } label: {
                        Label("Essayer avec des données d'exemple", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!courses.isEmpty)
                }
            }
        }
    }

    private func seedSample() {
        SeedData.seedIfNeeded(context, settings: app.settings)
        try? context.save()
        Haptics.success()
        app.settings.hasCompletedOnboarding = true
    }

    private func feature(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Theme.accentInk)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: Layout.tight) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
                                ChoiceCard(icon: "graduationcap.fill",
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
            HStack(spacing: 10) {
                Button {
                    showingImport = true
                } label: {
                    Label("Importer mon horaire", systemImage: "calendar.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    showingCourseForm = true
                } label: {
                    Label("Ajouter", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            if let resultMessage {
                Text(resultMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if courses.isEmpty {
                EmptyCard(icon: "books.vertical",
                          title: "Aucun cours pour l'instant",
                          message: "Importe ton horaire EPFL (.ics) pour créer tes cours automatiquement, ou ajoute-les à la main.",
                          actionTitle: "Ajouter un cours") {
                    showingCourseForm = true
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
                                     title: "avec amphi",
                                     tint: .blue)
                            StatCard(icon: "clock.fill",
                                     value: DateUtils.hoursLabel(hours: courses.reduce(0) { $0 + ($1.hasLectures ? $1.weeklyLectureHours : 0) }),
                                     title: "par semaine",
                                     tint: .purple)
                            StatCard(icon: "book.fill",
                                     value: DateUtils.hoursLabel(hours: courses.reduce(0) { $0 + $1.weeklyExerciseHours }),
                                     title: "exercices / sem.",
                                     tint: .green)
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

    private var termStep: some View {
        VStack(alignment: .leading, spacing: Layout.cardSpacing) {
            Card(title: "Dates du semestre", icon: "calendar") {
                VStack(alignment: .leading, spacing: 16) {
                    DatePicker("Début (semaine 1)", selection: $termStart, displayedComponents: .date)
                    Stepper("Durée : \(termWeeks) semaines", value: $termWeeks, in: 8...24)
                    Divider()
                    DetailRow(icon: "flag.checkered",
                              label: "Fin estimée",
                              value: DateUtils.shortDay.string(from: DateUtils.addWeeks(termWeeks, to: termStart)))
                }
            }

            Card(title: "Récapitulatif", icon: "checklist") {
                VStack(alignment: .leading, spacing: 12) {
                    DetailRow(icon: "graduationcap.fill",
                              label: "Section",
                              value: app.sectionDisplayName(sectionCode))
                    DetailRow(icon: "books.vertical.fill",
                              label: "Cours suivis",
                              value: "\(trackedCourses.count)")
                    DetailRow(icon: "building.columns.fill",
                              label: "Avec heures de cours",
                              value: "\(lectureCourses.count)")
                    DetailRow(icon: "clock.fill",
                              label: "Heures par crédit",
                              value: "\(Int(app.settings.hoursPerCredit)) h")
                }
            }

            Text("Tout est modifiable ensuite : les cours depuis l'onglet Cours, la section et la charge depuis le profil.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Pied

    private var footer: some View {
        HStack(spacing: 12) {
            if step > 0 {
                Button {
                    Haptics.tap()
                    withAnimation { step -= 1 }
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
                Text(step == lastStep ? "Terminer" : "Continuer")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(step == 1 && sectionCode.isEmpty && !search.isEmpty && EPFLCatalog.search(search).isEmpty)
        }
        .padding(Layout.screenPadding)
        .background(.bar)
    }

    private func advance() {
        if step < lastStep {
            withAnimation { step += 1 }
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
            existing.endDate = DateUtils.addWeeks(termWeeks, to: start)
            existing.year = Calendar.current.component(.year, from: start)
            existing.season = DateUtils.monthNumber(start) >= 8 ? .autumn : .spring
            return existing
        }
        let term = AcademicTerm(year: Calendar.current.component(.year, from: termStart),
                                season: DateUtils.monthNumber(termStart) >= 8 ? .autumn : .spring,
                                startDate: DateUtils.startOfWeek(termStart),
                                endDate: DateUtils.addWeeks(termWeeks, to: DateUtils.startOfWeek(termStart)),
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


