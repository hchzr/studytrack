#if DEBUG
import Foundation

/// Un semestre de première année vraisemblable, pour l'import simulé
/// (`-onboardingDemo`) : de vrais noms d'activités Moodle, des sections par
/// semaine, des séries, des vidéos et une échéance.
enum DemoSemester {
    struct Course {
        var code: String
        var name: String
        var color: String
        var topics: [String]
        /// Sa série et son corrigé sont-ils dans un dossier (et non en fichiers) ?
        var seriesInFolder = false
        var midterm: Int? = nil

        var sections: [MoodleSection] {
            var list = [MoodleSection(number: 0, title: "Informations générales", activities: [
                MoodleActivity(id: "\(code)-news", name: "Annonces", module: "forum", url: ""),
                MoodleActivity(id: "\(code)-plan", name: "Plan du cours et évaluation", module: "resource", url: ""),
            ])]
            for (index, topic) in topics.enumerated() {
                let week = index + 1
                var activities = [
                    MoodleActivity(id: "\(code)-v\(week)", name: "Vidéos — \(topic)", module: "url", url: ""),
                    MoodleActivity(id: "\(code)-p\(week)", name: "Notes de cours, chapitre \(week)", module: "resource", url: ""),
                ]
                if seriesInFolder {
                    activities.append(MoodleActivity(id: "\(code)-s\(week)", name: "Exercices semaine \(week)", module: "folder", url: ""))
                } else {
                    activities.append(MoodleActivity(id: "\(code)-s\(week)", name: "Série \(week)", module: "resource", url: ""))
                    activities.append(MoodleActivity(id: "\(code)-c\(week)", name: "Série \(week) — corrigé", module: "resource", url: ""))
                }
                if week == midterm {
                    activities.append(MoodleActivity(id: "\(code)-m", name: "Examen intermédiaire — consignes", module: "assign", url: ""))
                }
                list.append(MoodleSection(number: week, title: "Semaine \(week) · \(topic)", activities: activities))
            }
            return list
        }

        var draft: ContentDraft {
            var draft = ContentDraft(source: .moodle, courseTitle: name, url: "", sections: [])
            let start = Calendar.current.date(byAdding: .day, value: -24, to: Date()) ?? Date()
            draft.sections = topics.enumerated().map { index, topic in
                let week = index + 1
                var items = [ContentDraftItem(kind: .theory, number: "\(week).1", title: topic, url: "",
                                              videoCount: 2 + week % 3, seriesNumber: nil, theoryKind: .video)]
                if week % 7 != 0 {
                    items.append(ContentDraftItem(kind: .series, number: "\(week)", title: "Série \(week)", url: "",
                                                  videoCount: 0, seriesNumber: week, theoryKind: .reading))
                }
                if week == midterm {
                    var exam = ContentDraftItem(kind: .deadline, number: "", title: "Examen intermédiaire", url: "",
                                                videoCount: 0, seriesNumber: nil, theoryKind: .reading)
                    exam.date = Calendar.current.date(byAdding: .day, value: 7 * index + 3, to: start)
                    items.append(exam)
                }
                return ContentDraftSection(title: "Semaine \(week)", week: week, weekIsInferred: false,
                                           isIncluded: true, items: items)
            }
            return draft
        }
    }

    static let courses: [Course] = [
        Course(code: "MATH-101", name: "Analyse I", color: "#0891B2",
               topics: ["Nombres réels", "Suites", "Limites de suites", "Séries numériques", "Fonctions continues",
                        "Dérivées", "Théorème des accroissements finis", "Révisions", "Développements limités",
                        "Intégrale de Riemann", "Primitives", "Intégrales impropres", "Équations différentielles", "Révisions"],
               midterm: 8),
        Course(code: "MATH-111", name: "Algèbre linéaire", color: "#4F46E5",
               topics: ["Systèmes linéaires", "Matrices", "Inverse d'une matrice", "Espaces vectoriels", "Bases et dimension",
                        "Applications linéaires", "Rang", "Déterminants", "Valeurs propres", "Diagonalisation",
                        "Produit scalaire", "Gram-Schmidt", "Moindres carrés", "Révisions"]),
        Course(code: "CS-107", name: "Introduction à la programmation", color: "#059669",
               topics: ["Variables et types", "Conditions", "Boucles", "Fonctions", "Tableaux", "Chaînes de caractères",
                        "Révisions", "Classes et objets", "Encapsulation", "Héritage", "Polymorphisme", "Exceptions",
                        "Collections", "Projet"],
               seriesInFolder: true),
        Course(code: "PHYS-101", name: "Physique générale : mécanique", color: "#D97706",
               topics: ["Cinématique", "Lois de Newton", "Frottements", "Travail et énergie", "Quantité de mouvement",
                        "Chocs", "Révisions", "Rotation", "Moment cinétique", "Oscillateurs", "Gravitation",
                        "Référentiels non inertiels", "Solide indéformable", "Révisions"],
               midterm: 7),
    ]

    static func label(for activity: MoodleActivity) -> String {
        switch activity.module {
        case "url": return "Vidéo"
        case "folder": return "Dossier · 2 PDF"
        case "assign": return "Devoir"
        case "page": return "Page"
        default: return "PDF"
        }
    }
}
#endif
