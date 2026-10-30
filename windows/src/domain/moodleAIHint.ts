// Ce qu'un modèle de langage a compris d'une activité Moodle que les règles ne
// savent pas lire (StudyTrack/Domain/MoodleAIHint.swift).

import { Plural } from "./plural.ts";
import { swiftInt } from "../services/seriesPDFParser.ts";
import type { ActivityKind, MoodleCourseSnapshot } from "./moodleCourseAnalyzer.ts";
import { MoodleCourseAIReferences } from "./moodleCourseAnalyzer.ts";
import { MoodleCourseAnalyzer } from "./moodleCourseAnalyzer.ts";
import type { ScrapedCourse, ScrapedSection } from "./courseContentImport.ts";
import { icuRegExp } from "./icuRegExp.ts";

export interface MoodleAIHint {
  kind: ActivityKind | null;
  week: number | null;
  seriesNumber: number | null;
}

export const MoodleAIHint = {
  make(o: { kind?: ActivityKind | null; week?: number | null; seriesNumber?: number | null } = {}): MoodleAIHint {
    return { kind: o.kind ?? null, week: o.week ?? null, seriesNumber: o.seriesNumber ?? null };
  },
  equals(a: MoodleAIHint, b: MoodleAIHint): boolean {
    return a.kind === b.kind && a.week === b.week && a.seriesNumber === b.seriesNumber;
  },
};

/** Une série comprise par le modèle : son numéro, sa semaine, et les références de son énoncé et de son corrigé. */
export interface MoocSeriesPlan {
  number: number;
  week: number | null;
  statement: string | null;
  solution: string | null;
}

export const MoocSeriesPlan = {
  make(o: { number: number; week?: number | null; statement?: string | null; solution?: string | null }): MoocSeriesPlan {
    return { number: o.number, week: o.week ?? null, statement: o.statement ?? null, solution: o.solution ?? null };
  },
  equals(a: MoocSeriesPlan, b: MoocSeriesPlan): boolean {
    return a.number === b.number && a.week === b.week && a.statement === b.statement && a.solution === b.solution;
  },
};

/** Ce que le modèle répond. */
export interface MoodleCourseAIAnswer {
  hints: Record<string, MoodleAIHint>;
  moocWeeks: Record<string, number>;
  /** Les leçons du MOOC à regarder, par référence (« m1.3.2 ») : la semaine. */
  moocLessons: Record<string, number>;
  series: MoocSeriesPlan[];
  guide: Record<number, string>;
}

export const MoodleCourseAI = {
  /** `MoodleCourseAI.SeriesPlan` (Validation/main.swift). */
  SeriesPlan: MoocSeriesPlan,

  /**
   * La consigne, partagée par la fonction serveur et le modèle embarqué.
   *
   * **Recopiée** dans `supabase/functions/analyze-course/index.ts` : la changer
   * ici, c'est la changer là-bas et redéployer.
   */
  instructions: `Tu lis un cours de l'EPFL comme un·e étudiant·e attentif·ve, pour une app de suivi d'études. Tu reçois les sections Moodle (titre, semaine si connue, texte et consignes, liens cités « Lnn »), chaque activité (id, type Moodle, nom, où mène le lien, ce qu'est la cible et le début de son texte), et parfois le PLAN DU COURS et les MOOC cités (chapitres numérotés). Le cours peut avoir n'importe quelle forme : comprends-le d'après son contenu, pas d'après des habitudes.
Réponds UNIQUEMENT par un objet JSON :
{"activities":[{"id":"123","kind":"theory","week":3,"series":null}],"series":[{"number":3,"week":3,"statement":"a123","solution":"a124"}],"mooc":[{"week":3,"lessons":["m1.2.4","m1.2.5"]}],"weeks":[{"week":3,"todo":"…"}]}
- activities : une entrée par activité reçue, avec son id exact. kind : "theory" (cours, enregistrement, transparents, notes, polycopié, chapitre à lire), "series" (énoncé d'exercices à faire), "solution" (corrigé), "deadline" (rendu noté, devoir, projet, quiz noté), "document" (organisation, formulaire, ressource générale, ancien examen, matériel facultatif), "ignore" (forum, annonce, sondage, lien sans contenu). week : la semaine du semestre (1 à N) où l'activité se travaille — d'après la section, une date, un numéro (« Lecture 7 » avec deux cours par semaine → semaine 4) ou une consigne ; null si inconnue. series : son numéro de série pour "series" et "solution", sinon null.
- series : chaque série d'exercices du cours, une entrée par numéro. statement : la référence (« a » + id d'activité, ou « Lnn » pour un lien du texte d'une section) qui mène à l'ÉNONCÉ LUI-MÊME, la page ou le PDF où sont les exercices. Choisis d'après ce que contient la cible (son début de texte), pas seulement d'après le nom : un lien « série 4 » qui mène à un chapitre de MOOC sans ces exercices n'est pas l'énoncé ; une page « énoncé/corrigé » ou « corrigé » qui contient aussi les énoncés peut l'être. solution : le corrigé s'il est à une autre adresse, sinon null. week : la semaine où la série se fait.
- Les exercices et quiz d'un MOOC ne sont des séries que si le cours (consignes, plan) demande de les faire.
- mooc : si un MOOC est fourni, ce qu'il faut en regarder chaque semaine — d'après le plan, les consignes des sections ou les liens de chaque semaine. Une entrée par semaine : {"week":N,"lessons":["m1.3.2","m1.3.3"]} avec les références des LEÇONS (mX.Y.Z) demandées cette semaine-là, et seulement elles (un plan qui dit « vidéos 1.6 à 1.8 » → ces trois leçons ; un chapitre coupé sur deux semaines → ses leçons réparties). Quand le cours demande un chapitre entier (« MOOC 2 : vidéos Module 3 »), donne {"week":N,"id":"<id du chapitre>"} : « Module 3 » est l'entrée « module 3 » du MOOC 2 (préambules hors numérotation). La semaine est celle de la ligne du plan ou de la section : ne la décale jamais. Uniquement des références et des id de la liste ; rien d'optionnel.
- weeks : pour CHAQUE semaine du semestre où le plan ou Moodle prévoit quelque chose, y compris les semaines à venir, la consigne en une phrase courte (160 caractères au plus), concrète, à l'infinitif : quoi regarder (enregistrement, chapitres du MOOC et leurs numéros), quoi lire, quelle série faire, ce qui est à rendre. Uniquement d'après ce que tu as reçu.
- Si d'AUTRES SOURCES du cours sont fournies (polycopié en ligne, site du cours), sers-t'en pour les consignes : chapitres à lire ou à regarder, séries à faire, semaine par semaine.
- N'invente aucun id ni aucune référence.`,

  /** Les références de liens données au modèle. */
  references(snapshot: MoodleCourseSnapshot): Map<string, { url: string; solution: string | null }> {
    return MoodleCourseAIReferences(snapshot);
  },

  /** Le cours, compact : ce que le modèle lit. */
  payload(forSnapshot: MoodleCourseSnapshot, termStart: Date | null, totalWeeks: number,
          plan: string | null = null, moocs: ScrapedCourse[] = []): Record<string, unknown> {
    const lines: string[] = [];
    let counter = 0;
    for (const section of forSnapshot.sections) {
      const week = MoodleCourseAnalyzer.week(section, termStart, totalWeeks);
      lines.push(`## Section ${section.number} : ${MoodleCourseAnalyzer.sectionTitle(section)}` + (week !== null ? ` [semaine ${week}]` : ""));
      const text = MoodleCourseAI.compact(section.text, 700);
      if (text !== "") lines.push(`Texte : « ${text} »`);
      for (const link of section.links) {
        counter += 1;
        lines.push(`Lien L${counter} : ${link.title === "" ? "(sans titre)" : link.title} → ${MoodleCourseAI.shortURL(link.url)}`);
      }
      for (const activity of section.activities) {
        if (!activity.isVisible) continue;
        let line = `- id=${activity.id} [${activity.module}] ${activity.name}`;
        let target: URL | null = null;
        try {
          target = new URL(activity.link);
        } catch {
          target = null;
        }
        if (target !== null && target.hostname !== "" && !activity.link.includes(`/mod/${activity.module}/view.php`)) {
          line += ` → ${MoodleCourseAI.shortURL(activity.link)}`;
        } else if (target !== null && target.hostname !== "") {
          line += ` → ${target.hostname}`;
        }
        if (activity.solutionTarget !== null && activity.solutionTarget !== "") {
          line += ` (corrigé à côté : ${MoodleCourseAI.shortURL(activity.solutionTarget)})`;
        }
        if (activity.destination !== null) line += ` {${activity.destination}}`;
        if (activity.preview !== null) {
          const preview = MoodleCourseAI.compact(activity.preview, 260);
          if (preview !== "") line += ` « ${preview} »`;
        }
        lines.push(line);
      }
    }
    const payload: Record<string, unknown> = { course: forSnapshot.title, weeks: totalWeeks, outline: lines.join("\n") };
    if (plan !== null && plan !== "") payload["plan"] = [...plan].slice(0, 12_000).join("");
    if (moocs.length > 0) {
      const moocLines: string[] = [];
      moocs.forEach((mooc, index) => {
        // Les chapitres numérotés comme les « Module N » des plans de cours.
        let module = 0;
        moocLines.push(`# MOOC ${index + 1} : ${mooc.title}`);
        mooc.sections.forEach((chapter) => {
          if (chapter.id === undefined) return;
          const videos = chapter.items.reduce((n, lesson) => n + (lesson.videoCount ?? 0), 0);
          let label: string;
          if (MoodleCourseAI.isFrontMatter(chapter)) {
            label = `${chapter.title} [hors module]`;
          } else {
            module += 1;
            label = `module ${module} — ${chapter.title}`;
          }
          const firstIndex = mooc.sections.findIndex((candidate) => candidate.id === chapter.id);
          const chapterIndex = firstIndex >= 0 ? firstIndex + 1 : 0;
          const lessons = chapter.items.map((lesson, offset) => {
            const count = lesson.videoCount ?? (lesson.links ?? []).filter((link) => link.kind === "video").length;
            const what = count > 0
              ? ` (${Plural.count(count, `${count} vidéo`, `${count} vidéos`)})`
              : (isMoocExercise(lesson) ? " [exercices]" : "");
            return `  · m${index + 1}.${chapterIndex}.${offset + 1} ${lesson.title}${what}`;
          });
          moocLines.push([`- id=${chapter.id} : ${label} (${videos} vidéos)`, ...lessons].join("\n"));
        });
      });
      payload["mooc"] = moocLines.join("\n");
    }
    return payload;
  },

  // MARK: Quand redemander

  /** La **structure** du cours : ses sections, ses activités, ses liens, ses MOOC, et s'il a un plan. */
  structure(ofSnapshot: MoodleCourseSnapshot, moocs: ScrapedCourse[] = [], hasPlan = false): string {
    const lines: string[] = [];
    for (const section of ofSnapshot.sections) {
      lines.push(`S${section.number}|${MoodleCourseAnalyzer.sectionTitle(section)}`);
      for (const activity of section.activities) {
        if (!activity.isVisible) continue;
        lines.push(`${activity.id}|${activity.module}|${activity.name}|${MoodleCourseAI.stableLink(activity.link)}`);
      }
      for (const link of section.links) lines.push(`L|${MoodleCourseAI.stableLink(link.url)}`);
    }
    moocs.forEach((mooc, index) => {
      for (const chapter of mooc.sections) {
        lines.push(`M${index}|${chapter.id ?? chapter.title}|${chapter.items.length}`);
      }
    });
    lines.push(hasPlan ? "plan" : "sans plan");
    return lines.join("\n");
  },

  /** Une adresse sans ce qui change d'une lecture à l'autre. */
  stableLink(address: string): string {
    let url: URL;
    try {
      url = new URL(address);
    } catch {
      return address;
    }
    const path = url.pathname.replace(/\/content\/\d+\//g, "/content/");
    return url.hostname + path;
  },

  /** Faut-il garder la réponse déjà reçue ? */
  reuses(cachedStructure: string | null, cachedFull: string | null, cachedAt: Date | null,
         structure: string, full: string, now: Date, maxAge = 7 * 86_400): boolean {
    if (cachedStructure === null || cachedStructure !== structure) return false;
    if (cachedFull === full) return true;
    if (cachedAt === null) return false;
    return (now.getTime() - cachedAt.getTime()) / 1000 < maxAge;
  },

  /** `proginsc.epfl.ch/wwwhiver/series/serie04/serie.html` : l'hôte et le chemin disent ce qu'est un lien. */
  shortURL(address: string): string {
    let url: URL;
    try {
      url = new URL(address);
    } catch {
      return [...address].slice(0, 120).join("");
    }
    const path = safeDecode(url.pathname);
    return [...(url.hostname + path)].slice(0, 120).join("");
  },

  compact(text: string, limit: number): string {
    const flat = trimWhitespaces(text.replace(/\s+/g, " "));
    return [...flat].length > limit ? [...flat].slice(0, limit).join("") + "…" : flat;
  },

  answer(raw: string): MoodleCourseAIAnswer {
    const result: MoodleCourseAIAnswer = {
      hints: MoodleCourseAI.parse(raw), moocWeeks: {}, moocLessons: {}, series: [], guide: {},
    };
    const start = raw.indexOf("{");
    const end = raw.lastIndexOf("}");
    if (start < 0 || end < start) return result;
    let json: Record<string, any>;
    try {
      const parsed = JSON.parse(raw.slice(start, end + 1));
      if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) return result;
      json = parsed as Record<string, any>;
    } catch {
      return result;
    }
    const int = (value: unknown): number | null => {
      if (typeof value === "number" && Number.isFinite(value)) return Math.trunc(value);
      if (typeof value === "string") return swiftInt(trimWhitespaces(value));
      return null;
    };
    const ref = (value: unknown): string | null => {
      let text = typeof value === "string" ? value
        : typeof value === "number" ? String(value) : null;
      if (text === null) return null;
      text = trimWhitespaces(text);
      if (text === "" || text.toLowerCase() === "null") return null;
      if ([...text].every((c) => /\p{N}/u.test(c))) text = "a" + text;
      return text;
    };
    for (const entry of Array.isArray(json["mooc"]) ? json["mooc"] : []) {
      if (entry === null || typeof entry !== "object") continue;
      const week = int(entry["week"]);
      if (week === null || week <= 0) continue;
      if (typeof entry["id"] === "string" && entry["id"] !== "") {
        result.moocWeeks[entry["id"]] = Math.min(result.moocWeeks[entry["id"]] ?? week, week);
      }
      for (const lesson of Array.isArray(entry["lessons"]) ? entry["lessons"] : []) {
        if (typeof lesson !== "string") continue;
        const value = trimWhitespaces(lesson).toLowerCase();
        if (!/^m\d+\.\d+\.\d+$/.test(value)) continue;
        result.moocLessons[value] = Math.min(result.moocLessons[value] ?? week, week);
      }
    }
    for (const entry of Array.isArray(json["series"]) ? json["series"] : []) {
      if (entry === null || typeof entry !== "object") continue;
      const number = int(entry["number"]);
      if (number === null || number <= 0 || result.series.some((s) => s.number === number)) continue;
      const week = int(entry["week"]);
      result.series.push(MoocSeriesPlan.make({
        number,
        week: week !== null && week > 0 ? week : null,
        statement: ref(entry["statement"]),
        solution: ref(entry["solution"]),
      }));
    }
    for (const entry of Array.isArray(json["weeks"]) ? json["weeks"] : []) {
      if (entry === null || typeof entry !== "object") continue;
      const week = int(entry["week"]);
      if (week === null || week <= 0) continue;
      const todo = typeof entry["todo"] === "string" ? entry["todo"].trim() : "";
      if (todo === "") continue;
      result.guide[week] = [...todo].slice(0, 400).join("");
    }
    return result;
  },

  /** Les leçons désignées par le modèle (« m1.3.2 »), par identifiant de bloc (ou adresse) : leur semaine. */
  lessonWeeks(answer: MoodleCourseAIAnswer, moocs: ScrapedCourse[]): Record<string, number> {
    const result: Record<string, number> = {};
    for (const [reference, week] of Object.entries(answer.moocLessons)) {
      const parts = reference.slice(1).split(".").map((part) => swiftInt(part));
      if (parts.length !== 3 || parts.some((p) => p === null)) continue;
      const moocIndex = parts[0]! - 1;
      if (moocIndex < 0 || moocIndex >= moocs.length) continue;
      const chapters = moocs[moocIndex].sections;
      const chapterIndex = parts[1]! - 1;
      if (chapterIndex < 0 || chapterIndex >= chapters.length) continue;
      const lessons = chapters[chapterIndex].items;
      const lessonIndex = parts[2]! - 1;
      if (lessonIndex < 0 || lessonIndex >= lessons.length) continue;
      const lesson = lessons[lessonIndex];
      const key = lesson.id ?? (lesson.url === "" ? null : lesson.url);
      if (key === null) continue;
      result[key] = Math.min(result[key] ?? week, week);
    }
    return result;
  },

  /** Un chapitre hors programme, reconnu à son titre **ou à ses leçons**. */
  isFrontMatter(chapterOrTitle: ScrapedSection | string): boolean {
    if (typeof chapterOrTitle === "string") {
      const folded = foldLocale(chapterOrTitle);
      return icuRegExp(String.raw`\b(bienvenue|welcome|preambule|preamble|quiz|examen|exam|annexe|appendix|ressources)\b`).test(folded);
    }
    if (MoodleCourseAI.isFrontMatter(chapterOrTitle.title)) return true;
    const lessons = chapterOrTitle.items.map((item) => foldLocale(item.title));
    const welcome = lessons.some((lesson) => icuRegExp(String.raw`\b(bienvenue|welcome|informations pratiques|installation|preambule|prise en main)\b`).test(lesson));
    const assessed = lessons.some((lesson) => icuRegExp(String.raw`\b(controle des connaissances|quiz|exercices?)\b`).test(lesson));
    return welcome && !assessed;
  },

  /** La réponse du modèle, tolérante : texte autour, champs manquants. */
  parse(raw: string): Record<string, MoodleAIHint> {
    const start = raw.indexOf("{");
    const end = raw.lastIndexOf("}");
    if (start < 0 || end < start) return {};
    let json: Record<string, any>;
    try {
      const parsed = JSON.parse(raw.slice(start, end + 1));
      if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) return {};
      json = parsed as Record<string, any>;
    } catch {
      return {};
    }
    const activities = Array.isArray(json["activities"]) ? json["activities"] : [];
    const result: Record<string, MoodleAIHint> = {};
    for (const entry of activities) {
      if (entry === null || typeof entry !== "object") continue;
      const id = typeof entry["id"] === "string" ? entry["id"]
        : typeof entry["id"] === "number" ? String(entry["id"]) : null;
      if (id === null) continue;
      let kind: ActivityKind | null;
      switch (typeof entry["kind"] === "string" ? entry["kind"].toLowerCase() : "") {
        case "theory": case "video": case "lecture": kind = "lecture"; break;
        case "series": case "exercise": case "exercises": kind = "series"; break;
        case "solution": kind = "solution"; break;
        case "deadline": case "assignment": kind = "deadline"; break;
        case "document": case "resource": kind = "document"; break;
        case "ignore": kind = "ignore"; break;
        default: kind = null; break;
      }
      const week = typeof entry["week"] === "number" ? Math.trunc(entry["week"]) : null;
      const series = typeof entry["series"] === "number" ? Math.trunc(entry["series"]) : null;
      result[id] = MoodleAIHint.make({
        kind,
        week: week !== null && week > 0 ? week : null,
        seriesNumber: series !== null && series > 0 ? series : null,
      });
    }
    return result;
  },
};

/** `MoodleCourseAI.isFrontMatter(_ chapter:)` utilise la même reconnaissance par mots. */
function foldLocale(text: string): string {
  return text.normalize("NFD").replace(/\p{M}+/gu, "").toLowerCase();
}

function isMoocExercise(lesson: import("./courseContentImport.ts").ScrapedItem): boolean {
  return /\b(exercices?|exercises?|quiz+|quizzes|problemes?|problems?|series?|evaluation|assessment|test|devoir|homework|graded)\b/
    .test(foldLocale(lesson.title));
}

function safeDecode(text: string): string {
  try {
    return decodeURIComponent(text);
  } catch {
    return text;
  }
}

function trimWhitespaces(text: string): string {
  return text.replace(/^[\p{Zs}\t]+|[\p{Zs}\t]+$/gu, "");
}
