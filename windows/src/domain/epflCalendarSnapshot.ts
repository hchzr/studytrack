// L'instantané du calendrier académique de l'EPFL (StudyTrack/Domain/EPFLCalendarSnapshot.swift).
//
// `Calendar.current` devient l'heure locale de la machine (les tests tournent à Europe/Zurich).

import type { AcademicMilestoneValue } from "../models/academicMilestone.ts";
import type { MilestoneKind } from "../models/enums.ts";
import { AcademicCalendarParser } from "./academicCalendar.ts";

/// `EPFLCalendarSnapshot.Entry`.
export interface EPFLCalendarEntry {
  year: number;
  month: number;
  day: number;
  kind: MilestoneKind;
  important: boolean;
  approximate: boolean;
  term: string;
  title: string;
}

/// `Entry(year, month, day, kind, important, approximate, term, title)`.
function entry(year: number, month: number, day: number, kind: MilestoneKind,
  important: boolean, approximate: boolean, term: string, title: string): EPFLCalendarEntry {
  return { year, month, day, kind, important, approximate, term, title };
}

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
export const EPFLCalendarSnapshot = {
  capturedOn: "16 septembre 2026",

  /// Les échéances, dans l'ordre du document.
  entries: [
    entry(2025, 12, 15, "opening", false, true, "Semestre printemps 25-26", "Ouverture du formulaire FRAC"),
    entry(2025, 12, 15, "opening", false, true, "Semestre printemps 25-26", "Ouverture des inscriptions anticipées"),
    entry(2025, 12, 31, "publication", false, true, "Semestre printemps 25-26", "Publication de l’horaires du semestre"),
    entry(2026, 1, 7, "opening", false, false, "Semestre printemps 25-26", "Ouverture des inscriptions générales Master (cycle master, PDM et admission année sup.)"),
    entry(2026, 1, 8, "opening", false, false, "Semestre printemps 25-26", "Ouverture des inscriptions générales Bachelor (cycle bachelor, passerelle HES et Echange)"),
    entry(2026, 2, 2, "opening", false, false, "Semestre printemps 25-26", "Ouverture des inscriptions pour les matières à places limitées dans les mineurs"),
    entry(2026, 2, 13, "opening", false, false, "Semestre printemps 25-26", "Ouverture des inscriptions générales pour l’année propédeutique (BA2, mise à niveau et BA4 si cycle propé. réussi en hiver)"),
    entry(2026, 2, 16, "teachingStart", true, false, "Semestre printemps 25-26", "Début des enseignements (sauf mise à niveau)"),
    entry(2026, 2, 23, "teachingStart", false, false, "Semestre printemps 25-26", "Début des enseignements de la mise à niveau"),
    entry(2026, 2, 27, "deadline", false, false, "Semestre printemps 25-26", "Délai pour le formulaire FRAC"),
    entry(2026, 2, 27, "deadline", false, false, "Semestre printemps 25-26", "Délai pour les inscriptions"),
    entry(2026, 3, 1, "opening", false, true, "Semestre printemps 25-26", "Ouverture du retrait des examens"),
    entry(2026, 3, 11, "other", false, false, "Semestre printemps 25-26", "Course d’études (BA4 et MA2)"),
    entry(2026, 3, 16, "other", false, false, "Semestre printemps 25-26", "Début du retour indicatif sur les enseignements"),
    entry(2026, 3, 22, "other", false, false, "Semestre printemps 25-26", "Fin du retour indicatif sur les enseignements"),
    entry(2026, 3, 23, "publication", false, false, "Semestre printemps 25-26", "Publication du retour indicatif sur les enseignements"),
    entry(2026, 3, 31, "deadline", false, false, "Semestre printemps 25-26", "Délai pour le retrait de la mise à niveau sans échec"),
    entry(2026, 4, 2, "break", false, false, "Semestre printemps 25-26", "Interruption des enseignements (fin de journée)"),
    entry(2026, 4, 3, "holiday", false, false, "Semestre printemps 25-26", "Vendredi saint (jour férié)"),
    entry(2026, 4, 6, "holiday", false, false, "Semestre printemps 25-26", "Lundi de Pâques (jour férié)"),
    entry(2026, 4, 13, "break", false, false, "Semestre printemps 25-26", "Reprise des enseignements"),
    entry(2026, 4, 30, "publication", false, true, "Semestre printemps 25-26", "Publication de l’horaire des examens"),
    entry(2026, 5, 1, "deadline", false, false, "Semestre printemps 25-26", "Délai pour le retrait des examens"),
    entry(2026, 5, 14, "holiday", false, false, "Semestre printemps 25-26", "Ascension (jour férié)"),
    entry(2026, 5, 18, "evaluation", false, false, "Semestre printemps 25-26", "Début de l’évaluation approfondie pour tous les cours"),
    entry(2026, 5, 25, "holiday", false, false, "Semestre printemps 25-26", "Lundi de Pentecôte (jour férié)"),
    entry(2026, 5, 29, "teachingEnd", true, false, "Semestre printemps 25-26", "Fin des enseignements (sauf mise à niveau)"),
    entry(2026, 6, 5, "teachingEnd", false, false, "Semestre printemps 25-26", "Fin des enseignements de la mise à niveau"),
    entry(2026, 6, 7, "evaluation", false, false, "Semestre printemps 25-26", "Fin de l’évaluation approfondie pour tous les cours"),
    entry(2026, 6, 15, "examStart", true, false, "Semestre printemps 25-26", "Début des examens (sauf mise à niveau)"),
    entry(2026, 6, 22, "examStart", false, false, "Semestre printemps 25-26", "Début des examens de la mise à niveau"),
    entry(2026, 7, 4, "examEnd", true, false, "Semestre printemps 25-26", "Fin des examens"),
    entry(2026, 7, 14, "evaluation", false, false, "Semestre printemps 25-26", "Publication de l’évaluation approfondie pour tous les cours"),
    entry(2026, 7, 24, "publication", false, false, "Semestre printemps 25-26", "Publication des décisions (échecs ou réussites)"),
    entry(2026, 8, 1, "publication", false, true, "Semestre printemps 25-26", "Envoi des bulletins de notes"),
    entry(2026, 5, 31, "opening", false, true, "Semestre automne 26-27", "Ouverture des inscriptions anticipées"),
    entry(2026, 5, 31, "opening", false, true, "Semestre automne 26-27", "Ouverture du formulaire FRAC"),
    entry(2026, 7, 31, "publication", false, true, "Semestre automne 26-27", "Publication de l’horaire du semestre"),
    entry(2026, 8, 1, "holiday", false, false, "Semestre automne 26-27", "Fête nationale (jour férié)"),
    entry(2026, 8, 5, "opening", false, false, "Semestre automne 26-27", "Ouverture des inscriptions générales Master (cycle Master, projet de Master, passerelle HES et examen d’admission en année supérieure)"),
    entry(2026, 8, 6, "opening", false, false, "Semestre automne 26-27", "Ouverture des inscriptions générales propédeutique et Bachelor (cycle propédeutique, cycle Bachelor et mobilité)"),
    entry(2026, 8, 26, "opening", false, false, "Semestre automne 26-27", "Ouverture des inscriptions pour les matières à places limitées dans les mineurs"),
    entry(2026, 9, 4, "other", false, false, "Semestre automne 26-27", "Séances d’information dans le cadre de la Journée d’accueil"),
    entry(2026, 9, 7, "teachingStart", false, false, "Semestre automne 26-27", "Début des enseignements"),
    entry(2026, 9, 18, "deadline", false, false, "Semestre automne 26-27", "Délai pour le formulaire FRAC"),
    entry(2026, 9, 18, "deadline", false, false, "Semestre automne 26-27", "Délai pour les inscriptions"),
    entry(2026, 9, 21, "holiday", false, false, "Semestre automne 26-27", "Lundi du Jeûne fédéral (jour férié)"),
    entry(2026, 10, 1, "opening", false, true, "Semestre automne 26-27", "Ouverture du retrait des examens"),
    entry(2026, 10, 5, "other", false, false, "Semestre automne 26-27", "Début du retour indicatif sur les enseignements"),
    entry(2026, 10, 9, "deadline", false, false, "Semestre automne 26-27", "Délai pour le retrait du cours de mathématiques spéciales sans échec"),
    entry(2026, 10, 11, "other", false, false, "Semestre automne 26-27", "Fin du retour indicatif sur les enseignements"),
    entry(2026, 10, 12, "publication", false, false, "Semestre automne 26-27", "Publication du retour indicatif sur les enseignements"),
    entry(2026, 10, 16, "break", false, false, "Semestre automne 26-27", "Interruption des enseignements (fin de journée)"),
    entry(2026, 10, 26, "break", false, false, "Semestre automne 26-27", "Reprise des enseignements"),
    entry(2026, 10, 31, "deadline", false, false, "Semestre automne 26-27", "Délai pour le retrait de l’année propédeutique sans échec"),
    entry(2026, 11, 15, "publication", false, true, "Semestre automne 26-27", "Publication de l’horaire des examens"),
    entry(2026, 11, 20, "deadline", false, false, "Semestre automne 26-27", "Délai pour le retrait des examens"),
    entry(2026, 12, 7, "evaluation", false, false, "Semestre automne 26-27", "Début de l’évaluation approfondie pour tous les cours"),
    entry(2026, 12, 18, "teachingEnd", false, false, "Semestre automne 26-27", "Fin des enseignements"),
    entry(2026, 12, 25, "holiday", false, false, "Semestre automne 26-27", "Noël (jour férié)"),
    entry(2026, 12, 26, "holiday", false, false, "Semestre automne 26-27", "Saint-Etienne (jour férié)"),
    entry(2027, 1, 1, "holiday", false, false, "Semestre automne 26-27", "Nouvel An (jour férié)"),
    entry(2027, 1, 2, "holiday", false, false, "Semestre automne 26-27", "2 janvier (jour férié)"),
    entry(2027, 1, 11, "evaluation", false, false, "Semestre automne 26-27", "Fin de l’évaluation approfondie pour tous les cours"),
    entry(2027, 1, 11, "examStart", false, false, "Semestre automne 26-27", "Début des examens"),
    entry(2027, 1, 30, "examEnd", false, false, "Semestre automne 26-27", "Fin des examens"),
    entry(2027, 2, 9, "evaluation", false, false, "Semestre automne 26-27", "Publication de l’évaluation approfondie pour tous les cours"),
    entry(2027, 2, 12, "publication", false, false, "Semestre automne 26-27", "Publication des décisions de l’année propédeutique (échecs et réussites)"),
    entry(2027, 2, 19, "publication", false, false, "Semestre automne 26-27", "Publication des décisions (sauf année propédeutique) (échecs et réussites des cycles d’études)"),
    entry(2027, 2, 28, "publication", false, true, "Semestre automne 26-27", "Envoi des bulletins de notes de l’année propédeutique"),
    entry(2027, 3, 1, "publication", false, true, "Semestre automne 26-27", "Envoi des bulletins de notes (sauf année propédeutique)"),
  ] as readonly EPFLCalendarEntry[],

  /// Les échéances converties en valeurs.
  milestones(): AcademicMilestoneValue[] {
    const values: AcademicMilestoneValue[] = [];
    for (const e of EPFLCalendarSnapshot.entries) {
      const date = new Date(e.year, e.month - 1, e.day);
      values.push({
        id: AcademicCalendarParser.identifier(date, e.title),
        title: e.title,
        date,
        kind: e.kind,
        isImportant: e.important,
        isApproximate: e.approximate,
        termLabel: e.term,
        sourceURL: AcademicCalendarParser.sourceURL,
      });
    }
    return values.sort((a, b) => a.date.getTime() - b.date.getTime());
  },

  /// Les bornes du semestre **d'automne** d'une année, telles que l'EPFL les
  /// publie. Sert de source à la règle de rentrée quand la date est connue.
  autumnTeachingStart(year: number): Date | null {
    const found = EPFLCalendarSnapshot.entries.find((e) => e.year === year && e.month === 9 && e.kind === "teachingStart");
    return found ? new Date(found.year, found.month - 1, found.day) : null;
  },
};
