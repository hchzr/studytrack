// Port de StudyTrack/Domain/StudyMapAI.swift : ce qu'on demande à Claude pour
// **comprendre** la fiche — une phrase en clair par notion, ses liens avec les
// autres, des schémas, une question — et la lecture de sa réponse, sans rien
// croire sur parole : un lien vers une notion qui n'existe pas tombe.

import { RevisionText, type RevisionSheet } from "./revisionSheet.ts";
import { Diagram, DiagramKind, MindGraph, StudyLinks } from "./studyMapGraph.ts";
import { StudyLink, StudyMap, StudyResource, type StudyRelation } from "./studyMap.ts";

export const StudyMapAI = {
  instructions: `Tu aides un·e étudiant·e de l'EPFL à COMPRENDRE sa fiche de révision, pas seulement à la relire. Tu reçois toutes les notions de la fiche (chacune a un identifiant entre crochets, comme [e12]).
Réponds UNIQUEMENT avec un objet JSON :
{"entries":[{"id":"e12","gist":"…","why":"…","example":"…","question":"…","answer":"…"}],
 "links":[{"from":"e12","to":"e5","relation":"needs","note":"…"}],
 "schemas":[{"title":"…","kind":"flow","summary":"…","nodes":[{"id":"n1","label":"…","entry":"e12"}],"edges":[{"from":"n1","to":"n2","label":"…"}]}]}

• entries — pour les notions importantes (pas toutes ; les plus utiles pour comprendre le cours) :
  – gist : l'idée en une phrase, dite avec des mots, SANS formule (« Le noyau, c'est tout ce que l'application écrase sur zéro. »).
  – why : à quoi ça sert, ou pourquoi on en a besoin (une phrase).
  – example : un exemple concret et court (formules en LaTeX entre $…$ permises).
  – question + answer : UNE question qui teste la compréhension (pas la récitation), et sa réponse courte.
• links — les vraies dépendances, peu nombreuses (3 au plus par notion) :
  – needs : « from » a besoin de « to » pour être compris ; implies : « from » implique « to » ;
    uses : « from » se sert de « to » (preuve, méthode) ; contrast : à ne pas confondre ; example : « from » est un exemple de « to ».
  – note : pourquoi, en quelques mots. N'invente pas de lien qui n'est pas dans le cours.
• schemas — 4 à 8 au total, chacun utile pour comprendre un chapitre :
  – kind : flow (les étapes d'une méthode), dependencies (qui découle de quoi), tree (arbre de décision : quelle méthode choisir, avec des étiquettes « oui »/« non » sur les flèches) ou comparison (au lieu de nodes/edges : "columns":["A","B"], "rows":[["Critère","valeur A","valeur B"]]).
  – 12 nœuds au plus, des libellés courts. « entry » : l'identifiant de la notion de la fiche, si le nœud en est une.
Écris dans la langue de la fiche. N'invente rien qui ne soit pas dans la fiche.
`,

  /** La même consigne pour **un seul chapitre**. */
  get chapterInstructions(): string {
    return StudyMapAI.instructions
      .replace("4 à 8 au total, chacun utile pour comprendre un chapitre",
        "1 à 3 au total, tous pour CE chapitre (la fiche reçue n'est que ce chapitre)")
      .replace("toutes les notions de la fiche", "toutes les notions d'UN chapitre de la fiche");
  },

  /** Le message : la fiche, notion par notion, avec les identifiants `e1`, `e2`… (rendus à part). */
  prompt(course: string, sheet: RevisionSheet, bodyLimit = 220, entryLimit = 400, chapter: string | null = null): { text: string; ids: Record<string, string> } {
    const lines = ["COURS : " + course];
    const scoped = sheet.chapter(chapter);
    if (scoped !== null) lines.push("CHAPITRE : " + scoped.title);
    lines.push("");
    const ids: Record<string, string> = {};
    let current = "";
    for (const item of sheet.keyedIn(chapter).slice(0, entryLimit)) {
      if (item.chapterID !== current) {
        current = item.chapterID;
        lines.push("");
        lines.push("## " + item.chapterTitle);
      }
      const id = `e${item.index + 1}`;
      ids[id] = item.key;
      const body = item.entry.body.replace(/\n/g, " ").replace(/^[ \t]+|[ \t]+$/g, "");
      lines.push(`[${id}] (${item.entry.kind}) ${item.entry.title} — ${Array.from(body).slice(0, bodyLimit).join("")}`);
    }
    return { text: lines.join("\n"), ids };
  },

  // MARK: Lire la réponse

  /** Les clés de la fiche retrouvées d'après l'identifiant de la réponse, la clé elle-même ou le titre. */
  resolver(sheet: RevisionSheet, ids: Record<string, string>): (raw: unknown) => string | null {
    const keyed = sheet.keyed;
    const keys = new Set(keyed.map((item) => item.key));
    const byTitle = new Map<string, string>();
    for (const item of keyed) {
      const title = RevisionText.fold(item.entry.title);
      if (!byTitle.has(title)) byTitle.set(title, item.key);
    }
    return (raw: unknown): string | null => {
      if (typeof raw !== "string") return null;
      const text = raw.replace(/^\s+|\s+$/g, "");
      if (text === "") return null;
      const fromIds = ids[text] ?? ids[text.toLowerCase()];
      if (fromIds !== undefined) return fromIds;
      if (keys.has(text)) return text;
      return byTitle.get(RevisionText.fold(text)) ?? null;
    };
  },

  /**
   * La carte d'avant, complétée par la réponse de Claude : ses phrases en clair, ses
   * liens (avec ceux qu'on déduit des citations, et **sans toucher à ceux posés à la
   * main**), ses schémas. `null` si la réponse n'est pas lisible.
   */
  apply(answer: string, sheet: RevisionSheet, ids: Record<string, string>, to: StudyMap,
        now: Date = new Date(), chapter: string | null = null): StudyMap | null {
    const start = answer.indexOf("{");
    const end = answer.lastIndexOf("}");
    if (start < 0 || end < 0 || start >= end) return null;
    let object: unknown;
    try { object = JSON.parse(answer.slice(start, end + 1)); } catch { return null; }
    if (object === null || typeof object !== "object" || Array.isArray(object)) return null;
    const root = object as Record<string, unknown>;
    const resolve = StudyMapAI.resolver(sheet, ids);
    const result = cloneStudyMap(to);

    for (const value of arrayOf(root["entries"])) {
      const entry = objectOf(value);
      if (entry === null) continue;
      const key = resolve(entry["id"]);
      if (key === null) continue;
      const item: { gist?: string; why?: string; example?: string; check?: { question: string; answer: string } } = {};
      const gist = clean(entry["gist"]);
      const why = clean(entry["why"]);
      const example = clean(entry["example"]);
      if (gist !== null) item.gist = gist;
      if (why !== null) item.why = why;
      if (example !== null) item.example = example;
      const question = clean(entry["question"]);
      const response = clean(entry["answer"]);
      if (question !== null && response !== null) item.check = { question, answer: response };
      if (item.gist !== undefined || item.why !== undefined || item.example !== undefined || item.check !== undefined) {
        result.enrichment[key] = item;
      }
    }

    let generated = StudyLinks.cited(sheet);
    if (chapter !== null) {
      // Les liens que Claude avait posés ailleurs restent ; ceux entre notions de ce chapitre sont refaits.
      const mine = new Set(sheet.keyedIn(chapter).map((item) => item.key));
      generated = generated.concat(to.links.filter((link) => !link.userMade && !(mine.has(link.from) && mine.has(link.to))));
    }
    for (const value of arrayOf(root["links"])) {
      const link = objectOf(value);
      if (link === null) continue;
      const from = resolve(link["from"]);
      const target = resolve(link["to"]);
      const relation = parseRelation(typeof link["relation"] === "string" ? link["relation"] as string : "");
      if (from === null || target === null || relation === null) continue;
      generated.push(new StudyLink({ from, to: target, relation, note: clean(link["note"]) }));
    }
    result.links = StudyLinks.merged(to.links, generated, new Set(sheet.keyed.map((item) => item.key)));

    const diagrams: Diagram[] = [];
    arrayOf(root["schemas"]).forEach((value, index) => {
      const raw = objectOf(value);
      if (raw === null) return;
      const title = clean(raw["title"]);
      if (title === null) return;
      const kind = DiagramKind.fromRaw(RevisionText.fold(typeof raw["kind"] === "string" ? raw["kind"] as string : "")) ?? "flow";
      const prefix = chapter !== null ? chapter + "/" : "";
      const suffix = Array.from(RevisionText.fold(title)).filter((c) => /^\p{L}$/u.test(c)).slice(0, 16).join("");
      const schema = new Diagram({ id: `${prefix}s${index}-${suffix}`, title, summary: clean(raw["summary"]), kind });
      schema.chapter = chapter;
      if (kind === "comparison") {
        const columns = Array.isArray(raw["columns"])
          ? (raw["columns"] as unknown[]).map(clean).filter((c): c is string => c !== null) : null;
        const rows = Array.isArray(raw["rows"])
          ? (raw["rows"] as unknown[]).map((row) => Array.isArray(row) ? row.map((cell) => clean(cell) ?? "") : [])
          : null;
        schema.columns = columns;
        schema.rows = rows;
        if (columns === null || columns.length === 0 || rows === null || rows.length === 0) return;
      } else {
        const seen = new Set<string>();
        for (const nodeValue of arrayOf(raw["nodes"])) {
          const node = objectOf(nodeValue);
          if (node === null) continue;
          const id = clean(node["id"]);
          const label = clean(node["label"]);
          if (id === null || label === null || seen.has(id)) continue;
          seen.add(id);
          schema.nodes.push({
            id, label,
            ...(clean(node["detail"]) !== null ? { detail: clean(node["detail"]) as string } : {}),
            ...(resolve(node["entry"]) !== null ? { entry: resolve(node["entry"]) as string } : {}),
          });
        }
        for (const edgeValue of arrayOf(raw["edges"])) {
          const edge = objectOf(edgeValue);
          if (edge === null) continue;
          const from = clean(edge["from"]);
          const target = clean(edge["to"]);
          if (from === null || target === null || !seen.has(from) || !seen.has(target) || from === target) continue;
          schema.edges.push({
            from, to: target,
            ...(clean(edge["label"]) !== null ? { label: clean(edge["label"]) as string } : {}),
          });
        }
        if (schema.nodes.length < 2) return;
      }
      diagrams.push(schema);
    });
    if (diagrams.length !== 0) {
      // Seuls les schémas de la même portée sont remplacés.
      result.diagrams = to.diagrams.filter((diagram) => diagram.chapter !== chapter).concat(diagrams);
    }
    if (chapter !== null) {
      const done: Record<string, Date> = { ...(result.enrichedChapters ?? {}) };
      done[chapter] = now;
      result.enrichedChapters = done;
    } else {
      result.enrichedAt = now;
    }
    return result;
  },

  /** Une nouvelle fiche : ce qui était à l'étudiant·e reste, ce qui ne désigne plus rien tombe. */
  rebased(map: StudyMap, onto: RevisionSheet): StudyMap {
    const keys = new Set(onto.keyed.map((item) => item.key));
    const result = cloneStudyMap(map);
    result.progress = filterRecord(map.progress, keys);
    result.notes = filterRecord(map.notes, keys);
    result.enrichment = filterRecord(map.enrichment, keys);
    result.links = map.links.filter((link) => keys.has(link.from) && keys.has(link.to));
    result.layout = {};
    for (const [key, point] of Object.entries(map.layout)) {
      if (keys.has(key) || key === MindGraph.rootID || key.startsWith("chap:") || key.startsWith("custom:") || key.startsWith("◆")) {
        result.layout[key] = point;
      }
    }
    result.customNodes = map.customNodes.map((node) => ({ ...node }));
    const chapterIDs = new Set(onto.chapters.map((chapter) => chapter.id));
    if (map.chapterNotebooks !== null) {
      result.chapterNotebooks = {};
      for (const [key, value] of Object.entries(map.chapterNotebooks)) {
        if (chapterIDs.has(key)) result.chapterNotebooks[key] = value;
      }
    }
    if (map.enrichedChapters !== null) {
      result.enrichedChapters = {};
      for (const [key, value] of Object.entries(map.enrichedChapters)) {
        if (chapterIDs.has(key)) result.enrichedChapters[key] = value;
      }
    }
    result.resources = map.resources.map((resource) => new StudyResource({
      id: resource.id, kind: resource.kind, title: resource.title, url: resource.url,
      fileName: resource.fileName, addedAt: resource.addedAt,
      chapter: resource.chapter !== null && !chapterIDs.has(resource.chapter) ? null : resource.chapter,
    }));
    result.diagrams = map.diagrams.map((schema) => new Diagram({
      id: schema.id,
      title: schema.title,
      summary: schema.summary,
      kind: schema.kind,
      chapter: schema.chapter !== null && !chapterIDs.has(schema.chapter) ? null : schema.chapter,
      nodes: schema.nodes.map((node) => ({
        id: node.id,
        label: node.label,
        ...(node.detail !== undefined ? { detail: node.detail } : {}),
        ...(node.entry !== undefined && keys.has(node.entry) ? { entry: node.entry } : {}),
      })),
      edges: schema.edges.map((edge) => ({ ...edge })),
      columns: schema.columns !== null ? [...schema.columns] : null,
      rows: schema.rows !== null ? schema.rows.map((row) => [...row]) : null,
    }));
    return result;
  },
};

function parseRelation(raw: string): StudyRelation | null {
  const value = RevisionText.fold(raw).replace(/^\s+|\s+$/g, "");
  const exact = (["needs", "implies", "uses", "contrast", "example"] as const)
    .find((relation) => relation === value);
  if (exact !== undefined) return exact;
  if (value.startsWith("besoin") || value.startsWith("necessit") || value.startsWith("requi") || value.startsWith("prerequ")) return "needs";
  if (value.startsWith("impl")) return "implies";
  if (value.startsWith("util") || value.startsWith("sert") || value.startsWith("use")) return "uses";
  if (value.startsWith("contr") || value.startsWith("confond") || value.startsWith("oppo")) return "contrast";
  if (value.startsWith("exem") || value.startsWith("exam")) return "example";
  return null;
}

function clean(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const text = raw.replace(/^\s+|\s+$/g, "");
  return text === "" ? null : text;
}

function arrayOf(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function objectOf(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : null;
}

function filterRecord<T>(record: Record<string, T>, keys: Set<string>): Record<string, T> {
  const result: Record<string, T> = {};
  for (const [key, value] of Object.entries(record)) if (keys.has(key)) result[key] = value;
  return result;
}

/** Une copie de la carte : Swift copie la structure, on ne modifie pas celle d'avant. */
function cloneStudyMap(map: StudyMap): StudyMap {
  const copy = new StudyMap();
  copy.version = map.version;
  copy.links = map.links.map((link) => new StudyLink({
    from: link.from, to: link.to, relation: link.relation, note: link.note, userMade: link.userMade,
  }));
  copy.progress = {};
  for (const [key, value] of Object.entries(map.progress)) copy.progress[key] = { level: value.level, at: new Date(value.at) };
  copy.notes = { ...map.notes };
  copy.enrichment = {};
  for (const [key, value] of Object.entries(map.enrichment)) {
    copy.enrichment[key] = {
      ...(value.gist !== undefined ? { gist: value.gist } : {}),
      ...(value.why !== undefined ? { why: value.why } : {}),
      ...(value.example !== undefined ? { example: value.example } : {}),
      ...(value.check !== undefined ? { check: { question: value.check.question, answer: value.check.answer } } : {}),
    };
  }
  copy.customNodes = map.customNodes.map((node) => ({ ...node }));
  copy.layout = {};
  for (const [key, point] of Object.entries(map.layout)) copy.layout[key] = { x: point.x, y: point.y };
  copy.collapsed = new Set(map.collapsed);
  copy.diagrams = map.diagrams.map((diagram) => Diagram.fromJSON(diagram.toJSON()) as Diagram);
  copy.notebookURL = map.notebookURL;
  copy.chapterNotebooks = map.chapterNotebooks !== null ? { ...map.chapterNotebooks } : null;
  copy.enrichedChapters = null;
  if (map.enrichedChapters !== null) {
    copy.enrichedChapters = {};
    for (const [key, value] of Object.entries(map.enrichedChapters)) copy.enrichedChapters[key] = new Date(value);
  }
  copy.resources = map.resources.map((resource) => new StudyResource({
    id: resource.id, kind: resource.kind, title: resource.title, url: resource.url,
    fileName: resource.fileName, addedAt: new Date(resource.addedAt), chapter: resource.chapter,
  }));
  copy.enrichedAt = map.enrichedAt !== null ? new Date(map.enrichedAt) : null;
  return copy;
}
