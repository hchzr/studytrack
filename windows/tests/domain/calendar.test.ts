// Port de la section « Calendrier académique de l'EPFL : lecture de la vraie page » de
// Validation/main.swift. Un `it` par check Swift, le libellé du check pour nom.
import { describe, expect, it } from "vitest";

import { AcademicCalendarParser } from "../../src/domain/academicCalendar.ts";
import { DateUtils } from "../../src/domain/dateUtils.ts";
import { EPFLCalendarSnapshot } from "../../src/domain/epflCalendarSnapshot.ts";
import type { AcademicMilestoneValue } from "../../src/models/academicMilestone.ts";

describe("Calendrier académique de l'EPFL : lecture de la vraie page", () => {
  // Le HTML est un extrait **authentique** de la page publique : c'est ce qui rend
  // ce test utile. Un parseur testé sur une structure inventée ne prouve rien.
  const epflHTML = `
<p><strong>Semestre automne 26-27</strong></p>
<table><tbody>
<tr><td>Fin juillet 2026</td><td><a href="x">Publication de l&#8217;horaire du semestre</a></td></tr>
<tr><td>1 ao&#251;t 2026</td><td>F&#234;te nationale (jour f&#233;ri&#233;)</td></tr>
<tr><td><strong>7 septembre 2026</strong></td><td><strong>D&#233;but des enseignements</strong></td></tr>
<tr><td>21 septembre 2026</td><td>Lundi du Je&#251;ne f&#233;d&#233;ral (jour f&#233;ri&#233;)</td></tr>
<tr><td>16 octobre 2026</td><td>Interruption des enseignements (fin de journ&#233;e)</td></tr>
<tr><td>26 octobre 2026</td><td>Reprise des enseignements</td></tr>
<tr><td>Mi-novembre 2026</td><td>Publication de l&#8217;horaire des examens</td></tr>
<tr><td>20 novembre 2026</td><td><a href="y">D&#233;lai pour le&nbsp;retrait des examens</a></td></tr>
<tr><td>18 d&#233;cembre 2026</td><td>Fin des enseignements</td></tr>
<tr><td>11 janvier 2027</td><td>D&#233;but des examens</td></tr>
<tr><td>30 janvier 2027</td><td>Fin des examens</td></tr>
</tbody></table>
<p><strong>Semestre printemps 25-26</strong></p>
<table><tbody>
<tr><td><strong>16 f&#233;vrier 2026</strong></td><td><strong>D&#233;but des enseignements (sauf mise &#224; niveau)</strong></td></tr>
<tr><td>3 avril 2026</td><td>Vendredi saint (jour f&#233;ri&#233;)</td></tr>
<tr><td><strong>4 juillet 2026</strong></td><td><strong>Fin des examens</strong></td></tr>
</tbody></table>
`;
  const parsedCalendar = AcademicCalendarParser.parse(epflHTML);

  it("14 lignes lues sur la page", () => {
    expect(parsedCalendar.length).toBe(14);
  });
  it("chaque échéance porte une date", () => {
    expect(parsedCalendar.every((m) => m.date.getTime() >= 0)).toBe(true);
  });

  // Les deux semestres contiennent un « Début des enseignements » : on cible
  // celui d'automne, comme le ferait l'écran pour le semestre en cours.
  const milestone = (title: string, term = "automne"): AcademicMilestoneValue | undefined =>
    parsedCalendar.find((m) => m.title.includes(title) && m.termLabel.includes(term));

  it("« Début des enseignements » de l'automne est lu", () => {
    expect(milestone("Début des enseignements")?.title.includes("mise à niveau")).toBe(false);
  });
  it("…rattaché à son semestre", () => {
    expect(milestone("Début des enseignements")?.termLabel).toBe("Semestre automne 26-27");
  });
  it("…classé comme début des cours", () => {
    expect(milestone("Début des enseignements")?.kind).toBe("teachingStart");
  });
  it("…et marqué important, comme l'EPFL le fait", () => {
    expect(milestone("Début des enseignements")?.isImportant).toBe(true);
  });

  // La date qui commande toute l'app.
  const epflAutumn2026 = AcademicCalendarParser.parseDate("7 septembre 2026");
  it("« 7 septembre 2026 » est lue", () => {
    expect(epflAutumn2026).not.toBeNull();
  });
  it("…au 7 septembre 2026", () => {
    const d = epflAutumn2026!.date;
    expect([d.getFullYear(), d.getMonth() + 1, d.getDate()]).toEqual([2026, 9, 7]);
  });
  it("…qui est bien un lundi", () => {
    expect(epflAutumn2026!.date.getDay()).toBe(1);
  });
  it("…comme date exacte", () => {
    expect(epflAutumn2026!.approximate).toBe(false);
  });
  it("la règle de rentrée et la page de l'EPFL donnent la même date", () => {
    expect(DateUtils.autumnStart(2026).getTime()).toBe(epflAutumn2026?.date.getTime());
  });

  // Les dates approximatives : l'EPFL ne donne pas de jour, on le dit.
  const midNovember = AcademicCalendarParser.parseDate("Mi-novembre 2026");
  it("« Mi-novembre » est marquée approximative", () => {
    expect(midNovember?.approximate).toBe(true);
  });
  it("…au 15 du mois", () => {
    expect(midNovember!.date.getDate()).toBe(15);
  });
  it("« Fin décembre » au dernier jour du mois", () => {
    expect(AcademicCalendarParser.parseDate("Fin décembre 2025")!.date.getDate()).toBe(31);
  });
  it("« Début mars » au 1er", () => {
    expect(AcademicCalendarParser.parseDate("Début mars 2026")!.date.getDate()).toBe(1);
  });
  it("février 2027 n'est pas bissextile : 28", () => {
    expect(AcademicCalendarParser.parseDate("Fin février 2027")!.date.getDate()).toBe(28);
  });
  it("février 2028 est bissextile : 29", () => {
    expect(AcademicCalendarParser.parseDate("Fin février 2028")!.date.getDate()).toBe(29);
  });
  it("un texte sans date ne produit rien", () => {
    expect(AcademicCalendarParser.parseDate("pas une date")).toBeNull();
  });
  it("une cellule vide ne produit rien", () => {
    expect(AcademicCalendarParser.parseDate("")).toBeNull();
  });

  // Classification.
  it("jour férié reconnu", () => {
    expect(AcademicCalendarParser.kind("Vendredi saint (jour férié)")).toBe("holiday");
  });
  it("interruption reconnue", () => {
    expect(AcademicCalendarParser.kind("Interruption des enseignements (fin de journée)")).toBe("break");
  });
  it("délai reconnu", () => {
    expect(AcademicCalendarParser.kind("Délai pour le retrait des examens")).toBe("deadline");
  });
  it("ouverture reconnue", () => {
    expect(AcademicCalendarParser.kind("Ouverture des inscriptions anticipées")).toBe("opening");
  });
  it("fin des examens reconnue", () => {
    expect(AcademicCalendarParser.kind("Fin des examens")).toBe("examEnd");
  });
  it("envoi de bulletins classé en publication", () => {
    expect(AcademicCalendarParser.kind("Envoi des bulletins de notes")).toBe("publication");
  });
  it("l'inconnu ne force pas une nature", () => {
    expect(AcademicCalendarParser.kind("Autre chose")).toBe("other");
  });

  // HTML : sans les balises ni les entités.
  it("balises et entités retirées", () => {
    expect(AcademicCalendarParser.plainText("<td>D&#233;lai pour le&nbsp;retrait</td>")).toBe("Délai pour le retrait");
  });
  it("balises imbriquées retirées", () => {
    expect(AcademicCalendarParser.plainText('<a href="x">Deux <strong>mots</strong></a>')).toBe("Deux mots");
  });
  it("espaces normalisés", () => {
    expect(AcademicCalendarParser.plainText("<td>   espaces   multiples  </td>")).toBe("espaces multiples");
  });

  // Clé stable : deux lectures de la même page ne doivent pas dupliquer.
  it("les identifiants sont stables d'une lecture à l'autre", () => {
    const first = new Set(AcademicCalendarParser.parse(epflHTML).map((m) => m.id));
    const again = new Set(AcademicCalendarParser.parse(epflHTML).map((m) => m.id));
    expect(first).toEqual(again);
    expect(first.size).toBe(14);
  });

  // ── Instantané embarqué ───────────────────────────────────────────────────
  const snapshot = EPFLCalendarSnapshot.milestones();
  it("instantané embarqué : 71 échéances", () => {
    expect(snapshot.length).toBe(71);
  });
  it("chaque échéance porte une clé EPFL", () => {
    expect(snapshot.every((m) => m.id.startsWith("epfl."))).toBe(true);
  });
  it("l'instantané est chronologique", () => {
    expect(snapshot.map((m) => m.date.getTime())).toEqual(snapshot.map((m) => m.date.getTime()).sort((a, b) => a - b));
  });
  it("l'instantané n'est pas vide", () => {
    expect(snapshot.length).toBeGreaterThan(0);
  });

  // Les quatre bornes du semestre d'automne 2026-2027, vérifiables à la main.
  const snapshotDate = (title: string, term?: string): Date | undefined =>
    snapshot.find((m) => m.title === title && (term === undefined || m.termLabel.includes(term)))?.date;
  const day = (date: Date | undefined): string => (date ? DateUtils.shortDay(date) : "—");
  it("automne 2026 : début des cours le 7 septembre", () => {
    expect(day(snapshotDate("Début des enseignements", "automne 26-27"))).toBe("lun. 7 sept.");
  });
  it("…fin des cours le 18 décembre", () => {
    expect(day(snapshotDate("Fin des enseignements", "automne 26-27"))).toBe("ven. 18 déc.");
  });
  it("…début des examens le 11 janvier", () => {
    expect(day(snapshotDate("Début des examens", "automne 26-27"))).toBe("lun. 11 janv.");
  });
  it("…fin des examens le 30 janvier", () => {
    expect(day(snapshotDate("Fin des examens", "automne 26-27"))).toBe("sam. 30 janv.");
  });

  it("le début d'automne est extractible de l'instantané", () => {
    expect(EPFLCalendarSnapshot.autumnTeachingStart(2026)?.getTime()).toBe(epflAutumn2026?.date.getTime());
  });
  it("une année non publiée ne rend pas de date inventée", () => {
    expect(EPFLCalendarSnapshot.autumnTeachingStart(2025)).toBeNull();
  });

  it("l'instantané contient les jours fériés", () => {
    expect(snapshot.some((m) => m.kind === "holiday")).toBe(true);
  });
  it("…et les délais", () => {
    expect(snapshot.some((m) => m.kind === "deadline")).toBe(true);
  });
  it("13 échéances approximatives, signalées comme telles", () => {
    expect(snapshot.filter((m) => m.isApproximate).length).toBe(13);
  });
});
