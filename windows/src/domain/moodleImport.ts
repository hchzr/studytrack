// Un cours tel que Moodle le décrit, et comment on le relie à l'app
// (Polymestre/Domain/MoodleImport.swift).

import {
  ScrapedCourse, ScrapedItem, ScrapedSection,
} from "./courseContentImport.ts";
import { BotafogoParser } from "./courseContentImport.ts";
import { Institution } from "./institution.ts";
import {
  MoodleActivity, MoodleCourseSnapshot, MoodleSection,
} from "./moodleCourseAnalyzer.ts";

/** Un cours tel que Moodle le décrit : son identifiant et ses noms. */
export class MoodleCourseRef {
  id: number;
  fullname: string;
  shortname: string;

  constructor(o: { id: number; fullname: string; shortname: string }) {
    this.id = o.id;
    this.fullname = o.fullname;
    this.shortname = o.shortname;
  }

  get url(): URL {
    return Institution.current.moodleURL(`/course/view.php?id=${this.id}`)
      ?? new URL(`https://moodle.epfl.ch/course/view.php?id=${this.id}`);
  }

  /** « MATH-101(e) » → « MATH-101 ». */
  get baseCode(): string { return MoodleCourseMatcher.baseCode(this.shortname); }

  /** « (e) », la section Moodle, quand il y en a une. */
  get variant(): string | null {
    const open = this.shortname.indexOf("(");
    const close = this.shortname.lastIndexOf(")");
    if (open < 0 || close < 0 || !(open < close)) return null;
    return this.shortname.slice(open + 1, close);
  }
}

/** Le résultat d'une recherche : unique, ambiguë, ou rien. */
export type MoodleMatch =
  | { type: "unique"; ref: MoodleCourseRef }
  | { type: "ambiguous"; refs: MoodleCourseRef[] }
  | { type: "none" };

export const MoodleCourseMatcher = {
  /** Le code EPFL d'un nom court ou d'un titre : « MATH-101(e) » → « MATH-101 ». */
  baseCode(text: string): string {
    const range = /[A-Z]{2,6}-\d{3}[A-Z]?/.exec(text);
    if (range === null) return text.trim().toUpperCase();
    return range[0];
  },

  /** Le cours Moodle d'un cours de l'app, parmi des candidats. */
  match(code: string, candidates: MoodleCourseRef[], enrolled: MoodleCourseRef[] = []): MoodleMatch {
    const wanted = code.trim().toUpperCase();
    const base = MoodleCourseMatcher.baseCode(wanted);
    // Le code exact (« MATH-101(e) ») l'emporte, s'il est écrit ainsi dans l'app.
    const exact = [...enrolled, ...candidates].find((ref) => ref.shortname.toUpperCase() === wanted);
    if (exact !== undefined) return { type: "unique", ref: exact };
    const enrolledHits = enrolled.filter((ref) => ref.baseCode === base);
    if (enrolledHits.length === 1) return { type: "unique", ref: enrolledHits[0] };
    const hits = candidates.filter((ref) => ref.baseCode === base);
    if (hits.length === 1) return { type: "unique", ref: hits[0] };
    if (enrolledHits.length > 0) return { type: "ambiguous", refs: enrolledHits };
    return hits.length === 0 ? { type: "none" }
      : { type: "ambiguous", refs: [...hits].sort((a, b) => a.shortname < b.shortname ? -1 : a.shortname > b.shortname ? 1 : 0) };
  },

  /** L'identifiant Moodle retenu pour un cours, s'il a déjà été importé. */
  linkedID(sources: string[]): number | null {
    for (const source of sources) {
      if (!source.includes("moodle")) continue;
      let url: URL;
      try {
        url = new URL(source);
      } catch {
        continue;
      }
      if (!url.pathname.includes("/course/view.php")) continue;
      const id = url.searchParams.get("id");
      if (id === null) continue;
      const value = swiftInt(id);
      if (value !== null) return value;
    }
    return null;
  },
};

const flexibleString = (value: unknown): string | null => {
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return null;
};

const swiftInt = (text: string): number | null => {
  if (!/^[+-]?\d+$/.test(text.trim())) return null;
  return Number(text.trim());
};

interface StateSection {
  id: string;
  number: number | null;
  title: string;
  cmlist: string[];
  visible: boolean | null;
  component: string | null;
  itemid: string | null;
}

interface StateModule {
  id: string;
  name: string;
  module: string | null;
  url: string | null;
  uservisible: boolean | null;
}

interface State {
  section: StateSection[];
  cm: StateModule[];
}

/** Lit la réponse de `core_courseformat_get_state` — le plan d'un cours Moodle 4. */
export const MoodleStateParser = {
  state(fromStateJSON: string): State | null {
    let raw: unknown;
    try {
      raw = JSON.parse(fromStateJSON);
    } catch {
      return null;
    }
    if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return null;
    const object = raw as Record<string, any>;
    if (!Array.isArray(object["section"]) || !Array.isArray(object["cm"])) return null;
    const sections: StateSection[] = [];
    for (const value of object["section"]) {
      if (value === null || typeof value !== "object" || Array.isArray(value)) continue;
      const o = value as Record<string, any>;
      const id = flexibleString(o["id"]);
      if (id === null) return null;
      const cmlistRaw = o["cmlist"];
      const cmlist: string[] = Array.isArray(cmlistRaw)
        ? cmlistRaw.map((x: unknown) => flexibleString(x)).filter((x: string | null): x is string => x !== null)
        : [];
      sections.push({
        id,
        number: typeof o["number"] === "number" && Number.isFinite(o["number"]) ? Math.trunc(o["number"]) : null,
        title: typeof o["title"] === "string" ? o["title"] : "",
        cmlist,
        visible: typeof o["visible"] === "boolean" ? o["visible"] : null,
        component: typeof o["component"] === "string" ? o["component"] : null,
        itemid: flexibleString(o["itemid"]),
      });
    }
    const cm: StateModule[] = [];
    for (const value of object["cm"]) {
      if (value === null || typeof value !== "object" || Array.isArray(value)) continue;
      const o = value as Record<string, any>;
      const id = flexibleString(o["id"]);
      if (id === null) return null;
      cm.push({
        id,
        name: typeof o["name"] === "string" ? o["name"] : "",
        module: typeof o["module"] === "string" ? o["module"] : null,
        url: typeof o["url"] === "string" ? o["url"] : null,
        uservisible: typeof o["uservisible"] === "boolean" ? o["uservisible"] : null,
      });
    }
    return { section: sections, cm };
  },

  /** Le plan du cours, dans la forme commune aux trois sources. */
  course(fromStateJSON: string, title: string, url: string): ScrapedCourse | null {
    const state = MoodleStateParser.state(fromStateJSON);
    if (state === null) return null;
    const modules = new Map(state.cm.map((module) => [module.id, module]));
    const delegated = new Map<string, StateSection>();
    for (const section of state.section) {
      if (section.component === "mod_subsection" && section.itemid !== null && !delegated.has(section.itemid)) {
        delegated.set(section.itemid, section);
      }
    }

    const items = (section: StateSection, depth: number): ScrapedItem[] => {
      const result: ScrapedItem[] = [];
      for (const id of section.cmlist) {
        const module = modules.get(id);
        if (module === undefined || module.uservisible === false) continue;
        if (module.module === "subsection") {
          const inner = delegated.get(id);
          if (inner !== undefined && depth < 2) {
            result.push(...items(inner, depth + 1));
            continue;
          }
        }
        result.push(ScrapedItem.make(module.name, { url: module.url ?? "", type: module.module ?? "" }));
      }
      return result;
    };

    const sections = state.section
      .filter((section) => section.component !== "mod_subsection" && section.visible !== false)
      .map((section) => ScrapedSection.make(section.title, items(section, 0)));
    if (!sections.some((section) => section.items.length > 0)) return null;
    return ScrapedCourse.make("moodle", title, url, sections);
  },

  /** Le cours, activité par activité, pour `MoodleCourseAnalyzer`. */
  snapshot(fromStateJSON: string, title: string, url: string): MoodleCourseSnapshot | null {
    const state = MoodleStateParser.state(fromStateJSON);
    if (state === null) return null;
    const modules = new Map(state.cm.map((module) => [module.id, module]));
    const delegated = new Map<string, StateSection>();
    for (const section of state.section) {
      if (section.component === "mod_subsection" && section.itemid !== null && !delegated.has(section.itemid)) {
        delegated.set(section.itemid, section);
      }
    }

    const activities = (section: StateSection, depth: number): MoodleActivity[] => {
      const result: MoodleActivity[] = [];
      for (const id of section.cmlist) {
        const module = modules.get(id);
        if (module === undefined) continue;
        if (module.module === "subsection") {
          const inner = delegated.get(id);
          if (inner !== undefined && depth < 2) {
            result.push(...activities(inner, depth + 1));
            continue;
          }
        }
        const kind = module.module ?? "";
        const fallback = (Institution.current.moodle?.base ?? "https://moodle.epfl.ch")
          + `/mod/${kind}/view.php?id=${module.id}`;
        result.push(new MoodleActivity({
          id: module.id,
          name: BotafogoParser.decode(module.name),
          module: kind,
          url: module.url ?? fallback,
          isVisible: module.uservisible !== false,
        }));
      }
      return result;
    };

    const sections = state.section
      .filter((section) => section.component !== "mod_subsection" && section.visible !== false)
      .map((section, index) => new MoodleSection({
        number: section.number ?? index,
        title: BotafogoParser.decode(section.title),
        activities: activities(section, 0),
      }));
    return new MoodleCourseSnapshot({ title, url, sections });
  },

  /** La réponse d'une recherche ou de la liste des inscriptions. */
  courses(fromJSON: string): MoodleCourseRef[] {
    let raw: unknown;
    try {
      raw = JSON.parse(fromJSON);
    } catch {
      return [];
    }
    if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return [];
    const rows = (raw as Record<string, any>)["courses"];
    if (!Array.isArray(rows)) return [];
    const result: MoodleCourseRef[] = [];
    for (const row of rows) {
      if (row === null || typeof row !== "object" || Array.isArray(row)) continue;
      const o = row as Record<string, any>;
      if (typeof o["id"] !== "number" || !Number.isFinite(o["id"])) continue;
      result.push(new MoodleCourseRef({
        id: Math.trunc(o["id"]),
        fullname: BotafogoParser.decode(typeof o["fullname"] === "string" ? o["fullname"]
          : typeof o["displayname"] === "string" ? o["displayname"] : ""),
        shortname: BotafogoParser.decode(typeof o["shortname"] === "string" ? o["shortname"] : ""),
      }));
    }
    return result;
  },
};

// MARK: - Accueil : les cours de l'étudiant·e

export interface PlannedCourse {
  code: string;
  name: string;
  ref: MoodleCourseRef;
}

export const MoodleOnboarding = {
  courses(fromRefs: MoodleCourseRef[]): PlannedCourse[] {
    const seen = new Set<string>();
    const result: PlannedCourse[] = [];
    for (const ref of fromRefs) {
      const code = MoodleOnboarding.courseCode(ref);
      if (code === null || seen.has(code)) continue;
      seen.add(code);
      result.push({ code, name: MoodleOnboarding.cleanName(ref.fullname, code), ref });
    }
    return result;
  },

  /** « MATH-101(pi) » → « MATH-101 » ; rien sans code de cours EPFL. */
  courseCode(ref: MoodleCourseRef): string | null {
    for (const text of [ref.shortname, ref.fullname]) {
      const range = /\b[A-Z]{2,5}-\d{3}(?:\([a-z]+\))?/.exec(text);
      if (range !== null) return MoodleCourseMatcher.baseCode(range[0]);
    }
    return null;
  },

  /** « Analyse I (classe inversée) (MATH-101(pi)) » → « Analyse I (classe inversée) ». */
  cleanName(fullname: string, code: string): string {
    let name = fullname;
    const escaped = code.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    name = name.replace(new RegExp(`\\s*[\\(\\[]?\\s*${escaped}(\\([a-z]+\\))?\\s*[\\)\\]]?\\s*$`), "");
    name = name.split(code).join("");
    name = name.replace(/^[ \-–·|:\s]+|[ \-–·|:\s]+$/g, "");
    return name === "" ? code : name;
  },
};

export type { State, StateModule, StateSection };
