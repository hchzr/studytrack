// Port de StudyTrack/Domain/LocalFileCatalog.swift : tout ce qu'un assistant
// peut lire d'un cours, **sans réseau** — la liste, pas les octets. Pur : les
// modèles entrent, des lignes sortent.

import type { Course } from "../models/course.ts";
import type { NotesDocument } from "./notesLibrary.ts";
import { NotebookExport } from "./notebookExport.ts";
import { MoodleLinks } from "./botafogoProgram.ts";
import type { RevisionSheet } from "./revisionSheet.ts";
import type { StudyMap } from "./studyMap.ts";

/** D'où viennent les octets. */
export type CatalogSource =
  | { kind: "text"; text: string }
  | { kind: "remote"; url: URL }
  | { kind: "disk"; url: URL }
  | { kind: "data"; data: Uint8Array; fileName: string };

export interface CatalogEntry {
  id: string;
  courseID: string;
  courseCode: string;
  courseName: string;
  type: string;
  title: string;
  seriesNumber: number | null;
  week: number | null;
  /** Nom de fichier, sans extension quand elle n'est connue qu'au téléchargement. */
  baseName: string;
  source: CatalogSource;
  address: string | null;
  /** La série dont le PDF est aussi gardé par l'app (son cache sert d'abord). */
  seriesID: string | null;
}

/** Un cahier du dossier de notes, déjà rattaché à son cours. */
export interface CatalogNotebook {
  courseID: string;
  document: NotesDocument;
  url: URL;
}

const types = ["enonce", "corrige", "examen", "corrige-examen", "support", "document", "ressource",
  "cahier", "notes", "fiche", "corrige-texte", "notes-examen"];

const supportKinds = new Set(["pdf", "slides", "notes", "solution"]);

const documentExtensions = new Set([
  "pdf", "ppt", "pptx", "key", "doc", "docx", "xls", "xlsx", "odt", "odp", "ods",
  "txt", "md", "tex", "csv", "zip", "png", "jpg", "jpeg", "ipynb",
]);

export const LocalFileCatalog = {
  types,

  // MARK: Liste

  entries(courses: Course[], notebooks: CatalogNotebook[] = []): CatalogEntry[] {
    const result: CatalogEntry[] = [];
    for (const course of courses) {
      if (!course.isTracked) continue;
      const code = course.displayCode;
      const slugCode = LocalFileCatalog.slug(code);
      const entry = (
        id: string, type: string, title: string, base: string, source: CatalogSource,
        series: { seriesNumber: number; plannedWeek: number } | null = null,
        week: number | null = null, address: string | null = null,
      ): CatalogEntry => ({
        id,
        courseID: course.id,
        courseCode: code,
        courseName: course.name,
        type,
        title,
        seriesNumber: series?.seriesNumber ?? null,
        week: week ?? (series !== null && series.plannedWeek > 0 ? series.plannedWeek : null),
        baseName: base,
        source,
        address,
        seriesID: null,
      });

      if (course.notes.replace(/^\s+|\s+$/g, "") !== "") {
        result.push(entry(`notes:${course.id}`, "notes", `Notes — ${course.name}`, `${slugCode}-notes.md`, { kind: "text", text: course.notes }));
      }
      const sheet = course.revisionSheet as unknown as RevisionSheet | null;
      if (sheet !== null) {
        const text = NotebookExport.sheetText(course.name, sheet, course.studyMap as unknown as StudyMap);
        if (text !== "") {
          result.push(entry(`fiche:${course.id}`, "fiche", `Fiche de révision — ${course.name}`, `${slugCode}-fiche.md`, { kind: "text", text }));
        }
      }

      for (const series of course.sortedSeries) {
        const n = String(series.seriesNumber).padStart(2, "0");
        // Un titre qui dit déjà « Série 3 » n'est pas répété.
        const label = series.title === "" ? `Série ${series.seriesNumber}`
          : (LocalFileCatalog.fold(series.title).includes(`serie ${series.seriesNumber}`)
            || LocalFileCatalog.fold(series.title).includes(`serie${series.seriesNumber}`)
            ? series.title : `Série ${series.seriesNumber} — ${series.title}`);
        const statementURL = LocalFileCatalog.documentURL(series.urlString);
        if (statementURL !== null) {
          const line = entry(`serie:${series.id}`, "enonce", `${label} (énoncé)`, `serie-${n}-enonce`,
            { kind: "remote", url: statementURL }, series, null, series.urlString);
          line.seriesID = series.id;
          result.push(line);
        }
        const solutionURL = LocalFileCatalog.documentURL(series.solutionURLString);
        if (solutionURL !== null) {
          result.push(entry(`corrige:${series.id}`, "corrige", `${label} (corrigé)`, `serie-${n}-corrige`,
            { kind: "remote", url: solutionURL }, series, null, series.solutionURLString));
        }
        const solved = series.sortedExercises.filter((exercise) => exercise.solution.replace(/^\s+|\s+$/g, "") !== "");
        if (solved.length !== 0) {
          const body = [`# Corrigé — ${code}, série ${series.seriesNumber}`]
            .concat(solved.map((exercise) => `## Exercice ${exercise.exerciseNumber}${exercise.title === "" ? "" : " — " + exercise.title}\n\n${exercise.solution}`))
            .join("\n\n");
          result.push(entry(`corrige-texte:${series.id}`, "corrige-texte", `Corrigé rédigé — série ${series.seriesNumber}`,
            `serie-${n}-corrige-redige.md`, { kind: "text", text: body }, series));
        }
      }

      for (const exam of course.pastExams) {
        const name = LocalFileCatalog.slug(`${exam.year}-${exam.title}`);
        const examURL = LocalFileCatalog.documentURL(exam.urlString);
        if (examURL !== null) {
          result.push(entry(`examen:${exam.id}`, "examen", `${exam.title} (${exam.year})`, `examen-${name}`,
            { kind: "remote", url: examURL }, null, null, exam.urlString));
        }
        const examSolution = LocalFileCatalog.documentURL(exam.solutionURLString);
        if (examSolution !== null) {
          result.push(entry(`corrige-examen:${exam.id}`, "corrige-examen", `${exam.title} (${exam.year}) — corrigé`,
            `examen-${name}-corrige`, { kind: "remote", url: examSolution }, null, null, exam.solutionURLString));
        }
        if (exam.notes.replace(/^\s+|\s+$/g, "") !== "") {
          result.push(entry(`notes-examen:${exam.id}`, "notes-examen", `Notes — ${exam.title}`,
            `examen-${name}-notes.md`, { kind: "text", text: exam.notes }));
        }
      }

      // Transparents, notes et PDF rattachés aux éléments de théorie, puis les documents du cours.
      const seen = new Set<string>();
      for (const item of course.sortedTheoryItems) {
        for (const link of item.links) {
          if (!supportKinds.has(link.kind)) continue;
          const url = LocalFileCatalog.documentURL(link.url);
          if (url === null || seen.has(link.url)) continue;
          seen.add(link.url);
          result.push(entry(`support:${item.id}:${LocalFileCatalog.hash(link.url)}`, "support",
            `${item.number} ${item.title} — ${link.title}`,
            `${LocalFileCatalog.slug(item.number)}-${LocalFileCatalog.slug(link.title)}-${LocalFileCatalog.hash(link.url)}`,
            { kind: "remote", url }, null, item.plannedWeek > 0 ? item.plannedWeek : null, link.url));
        }
      }
      for (const document of course.documents) {
        if (!supportKinds.has(document.kind)) continue;
        const url = LocalFileCatalog.documentURL(document.url);
        if (url === null || seen.has(document.url)) continue;
        seen.add(document.url);
        result.push(entry(`document:${course.id}:${LocalFileCatalog.hash(document.url)}`, "document",
          document.group === "" ? document.title : `${document.group} — ${document.title}`,
          `${LocalFileCatalog.slug(document.title)}-${LocalFileCatalog.hash(document.url)}`,
          { kind: "remote", url }, null, null, document.url));
      }

      for (const resource of course.sortedResources) {
        const title = resource.title === "" ? resource.fileName : resource.title;
        if (resource.fileData !== null && resource.fileName !== "") {
          result.push(entry(`ressource:${resource.id}`, "ressource", title,
            `${LocalFileCatalog.slug(title)}-${LocalFileCatalog.hash(resource.id)}`,
            { kind: "data", data: resource.fileData, fileName: resource.fileName }));
        } else if (["pdf", "file", "image"].includes(resource.kindRaw) && LocalFileCatalog.documentURL(resource.address) !== null) {
          const url = LocalFileCatalog.documentURL(resource.address)!;
          if (seen.has(resource.address)) continue;
          seen.add(resource.address);
          result.push(entry(`ressource:${resource.id}`, "ressource", title,
            `${LocalFileCatalog.slug(title)}-${LocalFileCatalog.hash(resource.id)}`,
            { kind: "remote", url }, null, null, resource.address));
        }
      }

      for (const notebook of notebooks) {
        if (notebook.courseID !== course.id) continue;
        const document = notebook.document;
        const kind = document.isSolution ? "corrigé" : "copie";
        const label = [document.notebook, document.title].filter((part) => part !== "").join(" — ");
        const line = entry(`cahier:${LocalFileCatalog.hash(document.path)}`, "cahier", `${label} (${kind})`,
          `${LocalFileCatalog.slug(document.notebook)}-${LocalFileCatalog.slug(document.title)}-${LocalFileCatalog.hash(document.path)}`,
          { kind: "disk", url: notebook.url }, null, document.week);
        if (document.seriesNumber !== null) line.seriesNumber = document.seriesNumber;
        result.push(line);
      }
    }
    return result;
  },

  // MARK: Filtres

  filter(entries: CatalogEntry[], course: Course | null, type: string | null, series: number | null, query: string | null): CatalogEntry[] {
    // Par mots, sans accents ni ponctuation : « aide mémoire » trouve « Aide-mémoire ».
    const words = query === null ? [] : LocalFileCatalog.wordsOf(query);
    return entries.filter((entry) => {
      if (course !== null && entry.courseID !== course.id) return false;
      if (type !== null && type !== "" && entry.type !== type) return false;
      if (series !== null && entry.seriesNumber !== series) return false;
      if (words.length !== 0) {
        const haystack = LocalFileCatalog.wordsOf(`${entry.courseCode} ${entry.title} ${entry.baseName}`).join(" ");
        if (!words.every((word) => haystack.includes(word))) return false;
      }
      return true;
    });
  },

  // MARK: Outils

  /** L'adresse d'un **document** (et non d'une page web). */
  documentURL(address: string): URL | null {
    if (address === "") return null;
    let url: URL;
    try { url = new URL(address); } catch { return null; }
    if (url.protocol === "file:") return url;
    if (!(url.protocol.startsWith("http"))) return null;
    if (MoodleLinks.activityModule(url) !== null || MoodleLinks.isDocument(address)) return url;
    if ((url.host ?? "").includes("dropbox.com")) return url;
    const extension = pathExtension(url.pathname);
    return documentExtensions.has(extension) ? url : null;
  },

  wordsOf(text: string): string[] {
    return LocalFileCatalog.fold(text).split(/[^\p{L}\p{N}]+/u).filter((word) => word !== "");
  },

  fold(text: string): string {
    return text.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase().replace(/^\s+|\s+$/g, "");
  },

  /** Un nom de fichier lisible : minuscules, sans accents, des tirets. */
  slug(text: string): string {
    const parts = LocalFileCatalog.fold(text).split(/[^\p{L}\p{N}]+/u).filter((part) => part !== "");
    return parts.length === 0 ? "fichier" : Array.from(parts.join("-")).slice(0, 80).join("");
  },

  /** Une empreinte courte et stable (FNV-1a) : désambiguïse deux documents de même titre. */
  hash(text: string): string {
    let value = 0xcbf29ce484222325n;
    for (const byte of new TextEncoder().encode(text)) {
      value = BigInt.asUintN(64, (value ^ BigInt(byte)) * 0x100000001b3n);
    }
    return value.toString(16).slice(0, 8);
  },

  // MARK: Pages

  /** « 1-5,8 » → [0, 1, 2, 3, 4, 7] ; `null` si rien d'utilisable. */
  pageIndices(spec: string, total: number): number[] | null {
    if (total <= 0) return null;
    const seen = new Set<number>();
    const result: number[] = [];
    for (const part of spec.split(/[,;]/)) {
      const bounds = part.split("-").map((piece) => {
        const text = piece.replace(/^\s+|\s+$/g, "");
        return /^[+-]?\d+$/.test(text) ? Number(text) : null;
      });
      if (bounds.length !== 1 && bounds.length !== 2) continue;
      const low = bounds[0];
      if (low === null) continue;
      const high = bounds.length === 2 ? (bounds[1] ?? total) : low;
      if (low < 1 || high < low) continue;
      for (let page = low; page <= Math.min(high, total); page++) {
        if (!seen.has(page)) { seen.add(page); result.push(page - 1); }
      }
    }
    return result.length === 0 ? null : result;
  },
};

function pathExtension(path: string): string {
  const parts = path.split("/").filter((part) => part !== "");
  const file = parts[parts.length - 1] ?? "";
  const dot = file.lastIndexOf(".");
  return dot < 0 ? "" : file.slice(dot + 1).toLowerCase();
}
