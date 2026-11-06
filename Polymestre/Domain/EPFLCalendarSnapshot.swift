import Foundation

/// Instantané du calendrier académique de l'EPFL, relevé sur la page publique.
///
/// **Pourquoi embarqué** : le jour de la rentrée, l'app doit connaître la date de
/// début du semestre **sans réseau** — c'est elle qui commande tous les numéros de
/// semaine. Un calendrier qui ne se remplit qu'en ligne donnerait « semaine 1 »
/// toute la journée à quelqu'un qui n'a pas de connexion.
///
/// Cet instantané n'est pas figé pour autant : `AcademicCalendarService` sait
/// relire la page et le remplacer (Profil › Vie de l'EPFL › Actualiser).
///
/// Source : `AcademicCalendarParser.sourceURL`, relevé le 16 septembre 2026.
enum EPFLCalendarSnapshot {

    static let capturedOn = "16 septembre 2026"

    struct Entry {
        var year: Int
        var month: Int
        var day: Int
        var kind: MilestoneKind
        var important: Bool
        var approximate: Bool
        var term: String
        var title: String

        init(_ year: Int, _ month: Int, _ day: Int, _ kind: MilestoneKind,
             _ important: Bool, _ approximate: Bool, _ term: String, _ title: String) {
            self.year = year
            self.month = month
            self.day = day
            self.kind = kind
            self.important = important
            self.approximate = approximate
            self.term = term
            self.title = title
        }
    }

    /// Les échéances, dans l'ordre du document.
    static let entries: [Entry] = [
        Entry(2025, 12, 15, .opening, false, true, "Semestre printemps 25-26", "Ouverture du formulaire FRAC"),
        Entry(2025, 12, 15, .opening, false, true, "Semestre printemps 25-26", "Ouverture des inscriptions anticipées"),
        Entry(2025, 12, 31, .publication, false, true, "Semestre printemps 25-26", "Publication de l’horaires du semestre"),
        Entry(2026, 1, 7, .opening, false, false, "Semestre printemps 25-26", "Ouverture des inscriptions générales Master (cycle master, PDM et admission année sup.)"),
        Entry(2026, 1, 8, .opening, false, false, "Semestre printemps 25-26", "Ouverture des inscriptions générales Bachelor (cycle bachelor, passerelle HES et Echange)"),
        Entry(2026, 2, 2, .opening, false, false, "Semestre printemps 25-26", "Ouverture des inscriptions pour les matières à places limitées dans les mineurs"),
        Entry(2026, 2, 13, .opening, false, false, "Semestre printemps 25-26", "Ouverture des inscriptions générales pour l’année propédeutique (BA2, mise à niveau et BA4 si cycle propé. réussi en hiver)"),
        Entry(2026, 2, 16, .teachingStart, true, false, "Semestre printemps 25-26", "Début des enseignements (sauf mise à niveau)"),
        Entry(2026, 2, 23, .teachingStart, false, false, "Semestre printemps 25-26", "Début des enseignements de la mise à niveau"),
        Entry(2026, 2, 27, .deadline, false, false, "Semestre printemps 25-26", "Délai pour le formulaire FRAC"),
        Entry(2026, 2, 27, .deadline, false, false, "Semestre printemps 25-26", "Délai pour les inscriptions"),
        Entry(2026, 3, 1, .opening, false, true, "Semestre printemps 25-26", "Ouverture du retrait des examens"),
        Entry(2026, 3, 11, .other, false, false, "Semestre printemps 25-26", "Course d’études (BA4 et MA2)"),
        Entry(2026, 3, 16, .other, false, false, "Semestre printemps 25-26", "Début du retour indicatif sur les enseignements"),
        Entry(2026, 3, 22, .other, false, false, "Semestre printemps 25-26", "Fin du retour indicatif sur les enseignements"),
        Entry(2026, 3, 23, .publication, false, false, "Semestre printemps 25-26", "Publication du retour indicatif sur les enseignements"),
        Entry(2026, 3, 31, .deadline, false, false, "Semestre printemps 25-26", "Délai pour le retrait de la mise à niveau sans échec"),
        Entry(2026, 4, 2, .break, false, false, "Semestre printemps 25-26", "Interruption des enseignements (fin de journée)"),
        Entry(2026, 4, 3, .holiday, false, false, "Semestre printemps 25-26", "Vendredi saint (jour férié)"),
        Entry(2026, 4, 6, .holiday, false, false, "Semestre printemps 25-26", "Lundi de Pâques (jour férié)"),
        Entry(2026, 4, 13, .break, false, false, "Semestre printemps 25-26", "Reprise des enseignements"),
        Entry(2026, 4, 30, .publication, false, true, "Semestre printemps 25-26", "Publication de l’horaire des examens"),
        Entry(2026, 5, 1, .deadline, false, false, "Semestre printemps 25-26", "Délai pour le retrait des examens"),
        Entry(2026, 5, 14, .holiday, false, false, "Semestre printemps 25-26", "Ascension (jour férié)"),
        Entry(2026, 5, 18, .evaluation, false, false, "Semestre printemps 25-26", "Début de l’évaluation approfondie pour tous les cours"),
        Entry(2026, 5, 25, .holiday, false, false, "Semestre printemps 25-26", "Lundi de Pentecôte (jour férié)"),
        Entry(2026, 5, 29, .teachingEnd, true, false, "Semestre printemps 25-26", "Fin des enseignements (sauf mise à niveau)"),
        Entry(2026, 6, 5, .teachingEnd, false, false, "Semestre printemps 25-26", "Fin des enseignements de la mise à niveau"),
        Entry(2026, 6, 7, .evaluation, false, false, "Semestre printemps 25-26", "Fin de l’évaluation approfondie pour tous les cours"),
        Entry(2026, 6, 15, .examStart, true, false, "Semestre printemps 25-26", "Début des examens (sauf mise à niveau)"),
        Entry(2026, 6, 22, .examStart, false, false, "Semestre printemps 25-26", "Début des examens de la mise à niveau"),
        Entry(2026, 7, 4, .examEnd, true, false, "Semestre printemps 25-26", "Fin des examens"),
        Entry(2026, 7, 14, .evaluation, false, false, "Semestre printemps 25-26", "Publication de l’évaluation approfondie pour tous les cours"),
        Entry(2026, 7, 24, .publication, false, false, "Semestre printemps 25-26", "Publication des décisions (échecs ou réussites)"),
        Entry(2026, 8, 1, .publication, false, true, "Semestre printemps 25-26", "Envoi des bulletins de notes"),
        Entry(2026, 5, 31, .opening, false, true, "Semestre automne 26-27", "Ouverture des inscriptions anticipées"),
        Entry(2026, 5, 31, .opening, false, true, "Semestre automne 26-27", "Ouverture du formulaire FRAC"),
        Entry(2026, 7, 31, .publication, false, true, "Semestre automne 26-27", "Publication de l’horaire du semestre"),
        Entry(2026, 8, 1, .holiday, false, false, "Semestre automne 26-27", "Fête nationale (jour férié)"),
        Entry(2026, 8, 5, .opening, false, false, "Semestre automne 26-27", "Ouverture des inscriptions générales Master (cycle Master, projet de Master, passerelle HES et examen d’admission en année supérieure)"),
        Entry(2026, 8, 6, .opening, false, false, "Semestre automne 26-27", "Ouverture des inscriptions générales propédeutique et Bachelor (cycle propédeutique, cycle Bachelor et mobilité)"),
        Entry(2026, 8, 26, .opening, false, false, "Semestre automne 26-27", "Ouverture des inscriptions pour les matières à places limitées dans les mineurs"),
        Entry(2026, 9, 4, .other, false, false, "Semestre automne 26-27", "Séances d’information dans le cadre de la Journée d’accueil"),
        Entry(2026, 9, 7, .teachingStart, false, false, "Semestre automne 26-27", "Début des enseignements"),
        Entry(2026, 9, 18, .deadline, false, false, "Semestre automne 26-27", "Délai pour le formulaire FRAC"),
        Entry(2026, 9, 18, .deadline, false, false, "Semestre automne 26-27", "Délai pour les inscriptions"),
        Entry(2026, 9, 21, .holiday, false, false, "Semestre automne 26-27", "Lundi du Jeûne fédéral (jour férié)"),
        Entry(2026, 10, 1, .opening, false, true, "Semestre automne 26-27", "Ouverture du retrait des examens"),
        Entry(2026, 10, 5, .other, false, false, "Semestre automne 26-27", "Début du retour indicatif sur les enseignements"),
        Entry(2026, 10, 9, .deadline, false, false, "Semestre automne 26-27", "Délai pour le retrait du cours de mathématiques spéciales sans échec"),
        Entry(2026, 10, 11, .other, false, false, "Semestre automne 26-27", "Fin du retour indicatif sur les enseignements"),
        Entry(2026, 10, 12, .publication, false, false, "Semestre automne 26-27", "Publication du retour indicatif sur les enseignements"),
        Entry(2026, 10, 16, .break, false, false, "Semestre automne 26-27", "Interruption des enseignements (fin de journée)"),
        Entry(2026, 10, 26, .break, false, false, "Semestre automne 26-27", "Reprise des enseignements"),
        Entry(2026, 10, 31, .deadline, false, false, "Semestre automne 26-27", "Délai pour le retrait de l’année propédeutique sans échec"),
        Entry(2026, 11, 15, .publication, false, true, "Semestre automne 26-27", "Publication de l’horaire des examens"),
        Entry(2026, 11, 20, .deadline, false, false, "Semestre automne 26-27", "Délai pour le retrait des examens"),
        Entry(2026, 12, 7, .evaluation, false, false, "Semestre automne 26-27", "Début de l’évaluation approfondie pour tous les cours"),
        Entry(2026, 12, 18, .teachingEnd, false, false, "Semestre automne 26-27", "Fin des enseignements"),
        Entry(2026, 12, 25, .holiday, false, false, "Semestre automne 26-27", "Noël (jour férié)"),
        Entry(2026, 12, 26, .holiday, false, false, "Semestre automne 26-27", "Saint-Etienne (jour férié)"),
        Entry(2027, 1, 1, .holiday, false, false, "Semestre automne 26-27", "Nouvel An (jour férié)"),
        Entry(2027, 1, 2, .holiday, false, false, "Semestre automne 26-27", "2 janvier (jour férié)"),
        Entry(2027, 1, 11, .evaluation, false, false, "Semestre automne 26-27", "Fin de l’évaluation approfondie pour tous les cours"),
        Entry(2027, 1, 11, .examStart, false, false, "Semestre automne 26-27", "Début des examens"),
        Entry(2027, 1, 30, .examEnd, false, false, "Semestre automne 26-27", "Fin des examens"),
        Entry(2027, 2, 9, .evaluation, false, false, "Semestre automne 26-27", "Publication de l’évaluation approfondie pour tous les cours"),
        Entry(2027, 2, 12, .publication, false, false, "Semestre automne 26-27", "Publication des décisions de l’année propédeutique (échecs et réussites)"),
        Entry(2027, 2, 19, .publication, false, false, "Semestre automne 26-27", "Publication des décisions (sauf année propédeutique) (échecs et réussites des cycles d’études)"),
        Entry(2027, 2, 28, .publication, false, true, "Semestre automne 26-27", "Envoi des bulletins de notes de l’année propédeutique"),
        Entry(2027, 3, 1, .publication, false, true, "Semestre automne 26-27", "Envoi des bulletins de notes (sauf année propédeutique)"),
    ]

    /// Les échéances converties en valeurs.
    static func milestones(calendar: Calendar = .current) -> [AcademicMilestoneValue] {
        entries.compactMap { entry in
            guard let date = calendar.date(from: DateComponents(year: entry.year,
                                                                month: entry.month,
                                                                day: entry.day)) else { return nil }
            return AcademicMilestoneValue(
                id: AcademicCalendarParser.identifier(date: date, title: entry.title, calendar: calendar),
                title: entry.title,
                date: date,
                kind: entry.kind,
                isImportant: entry.important,
                isApproximate: entry.approximate,
                termLabel: entry.term)
        }
        .sorted { $0.date < $1.date }
    }

    /// Les bornes du semestre **d'automne** d'une année, telles que l'EPFL les
    /// publie. Sert de source à la règle de rentrée quand la date est connue.
    static func autumnTeachingStart(year: Int, calendar: Calendar = .current) -> Date? {
        entries.first { entry in
            entry.year == year && entry.month == 9 && entry.kind == .teachingStart
        }.flatMap { entry in
            calendar.date(from: DateComponents(year: entry.year, month: entry.month, day: entry.day))
        }
    }
}
