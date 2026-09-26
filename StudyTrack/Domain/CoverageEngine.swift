import Foundation

/// Gravité d'un manque de suivi.
enum CoverageSeverity: Int, Comparable, CaseIterable {
    /// Le suivi ne peut pas fonctionner : quelque chose manque structurellement.
    case blocking = 0
    /// Le suivi fonctionne, mais il est incomplet et le restera si on n'y touche pas.
    case warning = 1
    /// Confort : rien n'est faux, quelque chose serait simplement utile.
    case info = 2

    static func < (lhs: CoverageSeverity, rhs: CoverageSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .blocking: return "à corriger"
        case .warning: return "incomplet"
        case .info: return "à compléter"
        }
    }

    var icon: String {
        switch self {
        case .blocking: return "exclamationmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }
}

/// Famille d'un manque — sert à regrouper l'écran, pas à trier.
enum CoverageCategory: String, CaseIterable, Identifiable {
    case content, planning, correction, theory, exams, foundation

    var id: String { rawValue }

    var label: String {
        switch self {
        case .content: return "Contenu"
        case .planning: return "Planification"
        case .correction: return "Corrections"
        case .theory: return "Théorie"
        case .exams: return "Évaluations"
        case .foundation: return "Socle"
        }
    }

    var icon: String {
        switch self {
        case .content: return "list.bullet.rectangle"
        case .planning: return "calendar.badge.clock"
        case .correction: return "checkmark.seal"
        case .theory: return "play.rectangle.fill"
        case .exams: return "graduationcap.fill"
        case .foundation: return "building.columns.fill"
        }
    }
}

/// Un manque constaté, avec de quoi le corriger.
struct CoverageFinding: Identifiable, Equatable {
    var id: String
    var severity: CoverageSeverity
    var category: CoverageCategory
    var title: String
    var detail: String
    /// Code du cours concerné, pour proposer d'y aller.
    var courseCode: String?
    /// Libellé de l'action proposée, s'il y en a une.
    var actionLabel: String?

    init(id: String,
         severity: CoverageSeverity,
         category: CoverageCategory,
         title: String,
         detail: String,
         courseCode: String? = nil,
         actionLabel: String? = nil) {
        self.id = id
        self.severity = severity
        self.category = category
        self.title = title
        self.detail = detail
        self.courseCode = courseCode
        self.actionLabel = actionLabel
    }
}

/// Ce qu'un cours contient, réduit à ce qui décide de la couverture du suivi.
struct CourseCoverageInput: Equatable {
    var code: String
    var name: String
    var isTracked: Bool
    var hasTerm: Bool
    var hasLectures: Bool
    /// Semaine courante du cours.
    var currentWeek: Int
    var termWeeks: Int

    var theoryCount: Int
    /// Éléments de théorie sans durée connue : la charge prévue est sous-estimée.
    var theoryWithoutDuration: Int
    /// Vus mais jamais résumés.
    var theoryWatchedNotSummarized: Int

    var seriesNumbersWithNoExercise: [Int]
    /// Séries dont la semaine planifiée est passée et qui ne sont pas terminées.
    var overdueSeries: [Int]
    /// Séries planifiées hors des bornes du semestre.
    var misplannedSeries: [Int]

    var exerciseCount: Int
    var notDoneExerciseCount: Int
    var doneNotCorrectedCount: Int
    var toRedoCount: Int

    var examCount: Int
    var upcomingExamCount: Int
}

/// Un cours et ses manques.
struct CourseCoverage: Identifiable, Equatable {
    var code: String
    var name: String
    /// Un cours archivé n'est pas audité : il n'est plus suivi, donc il n'a pas à
    /// être complet. L'écran doit pouvoir les distinguer.
    var isTracked: Bool
    var findings: [CoverageFinding]

    var id: String { code }

    var blocking: [CoverageFinding] { findings.filter { $0.severity == .blocking } }
    var warnings: [CoverageFinding] { findings.filter { $0.severity == .warning } }

    /// Un cours est « bien suivi » quand rien n'y manque, ni bloquant ni incomplet.
    /// Les remarques de confort ne comptent pas : elles ne sont pas des défauts.
    var isHealthy: Bool { blocking.isEmpty && warnings.isEmpty }
}

/// Le bilan de couverture de tout le suivi.
struct CoverageReport: Equatable {
    var courses: [CourseCoverage]
    var globalFindings: [CoverageFinding]
    /// Nombre de cours suivis.
    var trackedCount: Int

    var allFindings: [CoverageFinding] {
        (globalFindings + courses.flatMap(\.findings))
            .sorted { lhs, rhs in
                if lhs.severity != rhs.severity { return lhs.severity < rhs.severity }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }

    var healthyCourses: Int { courses.filter { $0.isTracked && $0.isHealthy }.count }

    /// Part des cours suivis dont le suivi est complet.
    ///
    /// Un pourcentage plutôt qu'un score maison : il se vérifie à la main, et il
    /// veut dire quelque chose — « 4 cours sur 5 n'ont aucun manque ».
    var coverage: Double {
        guard trackedCount > 0 else { return 0 }
        return Double(healthyCourses) / Double(trackedCount)
    }

    func count(_ severity: CoverageSeverity) -> Int {
        allFindings.filter { $0.severity == severity }.count
    }

    var isComplete: Bool { allFindings.isEmpty }

    /// Les manques d'une famille, pour regrouper l'écran.
    func findings(in category: CoverageCategory) -> [CoverageFinding] {
        allFindings.filter { $0.category == category }
    }

    var populatedCategories: [CoverageCategory] {
        CoverageCategory.allCases.filter { !findings(in: $0).isEmpty }
    }
}

/// Audite la couverture du suivi : qu'est-ce qui échappe à l'app ?
///
/// L'app savait afficher ce qu'elle contenait ; elle ne disait nulle part ce qui
/// lui **manquait**. Un cours sans série, une série vide, une évaluation jamais
/// saisie passaient inaperçus — et « suivre tout » restait un espoir.
///
/// Fonction **pure** : elle reçoit des valeurs, donc elle se teste sans base.
enum CoverageEngine {

    static func report(courses: [CourseCoverageInput],
                       hasTerm: Bool,
                       hasTimetable: Bool) -> CoverageReport {
        var global: [CoverageFinding] = []

        if !hasTerm {
            global.append(CoverageFinding(
                id: "socle.semestre",
                severity: .blocking,
                category: .foundation,
                title: "Aucun semestre enregistré",
                detail: "Sans dates de semestre, aucun numéro de semaine n'est juste et la charge EPFL ne peut pas être calculée.",
                actionLabel: "Renseigner le semestre"))
        }
        if !hasTimetable {
            global.append(CoverageFinding(
                id: "socle.horaire",
                severity: .info,
                category: .foundation,
                title: "Aucun horaire importé",
                detail: "Importer ton horaire EPFL (.ics) crée tes cours, leurs heures d'amphi et tes séances en une fois.",
                actionLabel: "Importer un horaire"))
        }

        let tracked = courses.filter(\.isTracked)
        if tracked.isEmpty && hasTerm {
            global.append(CoverageFinding(
                id: "socle.cours",
                severity: .blocking,
                category: .foundation,
                title: "Aucun cours suivi",
                detail: "Rien à suivre pour l'instant : ajoute tes classes ou importe ton horaire.",
                actionLabel: "Ajouter un cours"))
        }

        return CoverageReport(courses: courses.map(audit).sorted { $0.code < $1.code },
                              globalFindings: global,
                              trackedCount: tracked.count)
    }

    // MARK: Audit d'un cours

    static func audit(_ course: CourseCoverageInput) -> CourseCoverage {
        var findings: [CoverageFinding] = []
        // Un cours archivé n'a pas à être complet : il n'est plus suivi.
        guard course.isTracked else {
            return CourseCoverage(code: course.code, name: course.name,
                                  isTracked: false, findings: [])
        }

        func add(_ suffix: String,
                 _ severity: CoverageSeverity,
                 _ category: CoverageCategory,
                 _ title: String,
                 _ detail: String,
                 action: String? = nil) {
            findings.append(CoverageFinding(id: "\(course.code).\(suffix)",
                                            severity: severity,
                                            category: category,
                                            title: title,
                                            detail: detail,
                                            courseCode: course.code,
                                            actionLabel: action))
        }

        // ── Socle ────────────────────────────────────────────────────────────
        if !course.hasTerm {
            add("semestre", .blocking, .foundation,
                "Cours rattaché à aucun semestre",
                "Ses semaines et sa charge attendue ne peuvent pas être calculées.",
                action: "Choisir le semestre")
        }
        if !course.hasLectures, course.theoryCount == 0 {
            add("amphi", .info, .foundation,
                "Ni heures d'amphi ni théorie",
                "Vérifie l'interrupteur « Amphi » : s'il a des cours magistraux, la charge attendue est sous-estimée.",
                action: "Vérifier la scolarité")
        }

        // ── Contenu ──────────────────────────────────────────────────────────
        if course.theoryCount == 0 && course.exerciseCount == 0 && course.seriesNumbersWithNoExercise.isEmpty {
            add("vide", .blocking, .content,
                "Cours vide",
                "Aucune théorie, aucun exercice : rien ne peut être suivi pour ce cours.",
                action: "Ouvrir le cours")
        }
        if !course.seriesNumbersWithNoExercise.isEmpty {
            let list = course.seriesNumbersWithNoExercise.map(String.init).joined(separator: ", ")
            add("series-vides", .warning, .content,
                "\(course.seriesNumbersWithNoExercise.count) série\(course.seriesNumbersWithNoExercise.count > 1 ? "s" : "") sans exercice",
                "Série \(list) : l'import n'a reconnu aucun numéro. Ajoute-les à la main, sinon leur avancement restera à zéro.",
                action: "Compléter les séries")
        }

        // ── Planification ────────────────────────────────────────────────────
        if !course.overdueSeries.isEmpty {
            let list = course.overdueSeries.map(String.init).joined(separator: ", ")
            add("retard", .warning, .planning,
                "\(course.overdueSeries.count) série\(course.overdueSeries.count > 1 ? "s" : "") en retard",
                "Série \(list) : la semaine prévue est passée et la série n'est pas terminée alors que le semestre est en semaine \(course.currentWeek).",
                action: "Voir les exercices")
        }
        if !course.misplannedSeries.isEmpty {
            let list = course.misplannedSeries.map(String.init).joined(separator: ", ")
            add("hors-bornes", .info, .planning,
                "\(course.misplannedSeries.count) série\(course.misplannedSeries.count > 1 ? "s" : "") planifiée\(course.misplannedSeries.count > 1 ? "s" : "") hors semestre",
                "Série \(list) : la semaine annoncée sort des \(course.termWeeks) semaines du semestre.",
                action: "Corriger la semaine")
        }

        // ── Théorie ──────────────────────────────────────────────────────────
        if course.theoryWatchedNotSummarized > 0 {
            add("non-resume", .info, .theory,
                "\(course.theoryWatchedNotSummarized) élément\(course.theoryWatchedNotSummarized > 1 ? "s" : "") vu\(course.theoryWatchedNotSummarized > 1 ? "s" : "") sans résumé",
                "Le résumé est ce qui fait tenir la théorie : il reste à écrire.",
                action: "Voir la théorie")
        }
        if course.theoryWithoutDuration > 0 {
            add("sans-duree", .info, .theory,
                "\(course.theoryWithoutDuration) élément\(course.theoryWithoutDuration > 1 ? "s" : "") de théorie sans durée",
                "Sans durée, la charge prévue est sous-estimée et « où j'en suis cette semaine » est faux.",
                action: "Voir la théorie")
        }

        // ── Corrections ──────────────────────────────────────────────────────
        if course.doneNotCorrectedCount > 0 {
            add("a-corriger", .warning, .correction,
                "\(course.doneNotCorrectedCount) exercice\(course.doneNotCorrectedCount > 1 ? "s" : "") fait\(course.doneNotCorrectedCount > 1 ? "s" : "") non corrigé\(course.doneNotCorrectedCount > 1 ? "s" : "")",
                "Un exercice fait sans correction ne dit pas s'il est juste : c'est la moitié du travail qui manque.",
                action: "Corriger")
        }
        if course.toRedoCount > 0 {
            add("a-refaire", .warning, .correction,
                "\(course.toRedoCount) exercice\(course.toRedoCount > 1 ? "s" : "") à refaire",
                "Marqués « à refaire » et toujours non refaits.",
                action: "Voir les exercices")
        }

        // ── Évaluations ──────────────────────────────────────────────────────
        if course.examCount == 0 {
            add("sans-evaluation", .warning, .exams,
                "Aucune évaluation enregistrée",
                "Sans midterm ni examen enregistré, l'agenda ne peut pas t'avertir et rien ne cadre la révision.",
                action: "Ajouter une évaluation")
        } else if course.upcomingExamCount == 0 {
            add("sans-echeance", .info, .exams,
                "Plus aucune échéance à venir",
                "Toutes ses évaluations sont passées. Ajoute la session d'examens si elle n'y est pas.",
                action: "Voir l'agenda")
        }

        return CourseCoverage(code: course.code,
                              name: course.name,
                              isTracked: true,
                              findings: findings.sorted { lhs, rhs in
                                  if lhs.severity != rhs.severity { return lhs.severity < rhs.severity }
                                  return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                              })
    }
}
