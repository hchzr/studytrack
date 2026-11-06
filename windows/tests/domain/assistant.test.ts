// Port des sections de Validation/main.swift qui portent sur l'assistant :
//   « Export pour un assistant (source du serveur MCP) », « Serveur MCP local
//   (fichiers du Mac) », « Assistant : commandes appliquées par l'app »,
//   « Session Supabase conservée entre deux lancements », « Le cadre du tuteur »,
//   « Claude dans le mode étude » et l'extension Claude Desktop.
// Chaque `check` Swift devient un `it` du même libellé.

import { describe, expect, it } from "vitest";
import { createServer } from "node:http";
import { request as httpRequest } from "node:http";

import {
  AcademicMilestone, Course, Exercise, ExerciseSeries, ModelStore, PastExam, SavedResource, SeedData,
  StudySession, SubQuestion, TheoryItem,
} from "../../src/models/index.ts";
import { AssistantExport } from "../../src/domain/assistantExport.ts";
import { LocalFileCatalog } from "../../src/domain/localFileCatalog.ts";
import type { NotesDocument } from "../../src/domain/notesLibrary.ts";
import { AssistantCommand, AssistantCommandApplier } from "../../src/domain/assistantCommands.ts";
import { StoredSession } from "../../src/domain/supabaseSession.ts";
import { TutorFramework, TutorNext, TutorState } from "../../src/domain/tutorFramework.ts";
import { ClaudeTutor, RichMarkup, type ClaudeAttachment } from "../../src/domain/claudeTutor.ts";
import { ClaudeCommand, ClaudeModels, ClaudeProject, ClaudeProjectFile, ClaudeServer } from "../../src/domain/claudeProject.ts";
import { ClaudeDesktopExtension } from "../../src/domain/claudeDesktopExtension.ts";
import {
  LocalHTTPRequest, LocalMCPRPC, LocalMCPServer, type LocalMCPHost, type LocalMCPProvider,
} from "../../src/domain/localMCP.ts";
import "../../src/domain/registerCodecs.ts";

function check(condition: boolean, label: string): void {
  it(label, () => { expect(condition).toBe(true); });
}

const eq = <T>(a: T, b: T): boolean => JSON.stringify(a) === JSON.stringify(b);

const store = new ModelStore();
SeedData.seed(store);
const courses = store.fetch(Course);
const sessions = store.fetch(StudySession);

describe("Export pour un assistant (source du serveur MCP)", () => {
  const exportCourses = courses.filter((course) => course.isTracked);
  const base = {
    courses: exportCourses, sessions, milestones: [] as AcademicMilestone[], groups: [],
    hoursPerCredit: 30, displayName: "Test",
  };
  const exportData = AssistantExport.make(base);
  check(exportData["format"] === "polymestre.assistant", `le format est annoncé — ${String(exportData["format"] ?? "-")}`);
  check(exportData["version"] === AssistantExport.formatVersion, "la version du format est portée");
  check(typeof exportData["generatedAt"] === "string", "l'horodatage est présent");

  const exportedCourses = exportData["courses"] as Record<string, unknown>[];
  check(exportedCourses.length === exportCourses.length, `tous les cours suivis sont exportés (${exportedCourses.length})`);
  check(exportedCourses.every((course) => typeof course["code"] === "string" && typeof course["name"] === "string"),
    "chaque cours a un code et un nom");

  const firstCourse = exportedCourses[0];
  const series = firstCourse?.["series"] as Record<string, unknown>[] | undefined;
  const firstSeries = series?.[0];
  const exercises = firstSeries?.["exercises"] as Record<string, unknown>[] | undefined;
  const firstExercise = exercises?.[0];
  if (firstExercise !== undefined) {
    check(typeof firstExercise["number"] === "string", "un exercice porte son numéro");
    check(typeof firstExercise["done"] === "boolean", "…et son état");
    check(typeof firstExercise["bonus"] === "boolean", "…et s'il est facultatif");
  } else {
    check(false, "le cours d'exemple a des séries et des exercices exportés");
  }

  // Le JSON doit être sérialisable : c'est ce que le serveur MCP lit.
  const exportJSON = AssistantExport.data(base);
  check(exportJSON !== null, "l'instantané est sérialisable");
  if (exportJSON !== null) {
    const reparsed = JSON.parse(exportJSON) as Record<string, unknown>;
    check(reparsed["format"] === "polymestre.assistant", "…et se relit après un aller-retour JSON");
    check((reparsed["courses"] as Record<string, unknown>[]).length !== 0, "les cours survivent");
  }
  // Un export sans cours ne doit pas produire un objet vide mais valide.
  const emptyExport = AssistantExport.make({
    courses: [], sessions: [], milestones: [], groups: [], hoursPerCredit: 25, displayName: "",
  });
  check(emptyExport["format"] === "polymestre.assistant", "un export vide garde son format");
  check((emptyExport["courses"] as Record<string, unknown>[]).length === 0, "…et une liste de cours vide plutôt qu'absente");

  // v3 : notes, fiche, corrigés rédigés et fichiers — seulement sur demande.
  const contentCourse = exportCourses[0];
  const contentSeries = contentCourse?.sortedSeries[0];
  const contentExercise = contentSeries?.sortedExercises[0];
  if (contentCourse !== undefined && contentSeries !== undefined && contentExercise !== undefined) {
    const before = {
      notes: contentCourse.notes, solution: contentExercise.solution, hint: contentExercise.hint,
      url: contentSeries.urlString, solutionURL: contentSeries.solutionURLString,
    };
    contentCourse.notes = "Théorème d'unicité de la limite.";
    contentExercise.solution = "On lit la limite sur le graphe.";
    contentExercise.hint = "Pense à epsilon.";
    contentSeries.urlString = "https://moodle.example/serie.pdf";
    contentSeries.solutionURLString = "https://moodle.example/corrige.pdf";
    const runExport = (includeContent: boolean, files: Record<string, unknown>[] = []): Record<string, unknown> =>
      AssistantExport.make({
        courses: [contentCourse], sessions: [], milestones: [], groups: [], hoursPerCredit: 30,
        displayName: "Test", includeContent, files,
      });
    const exerciseEntry = (data: Record<string, unknown>): Record<string, unknown> | undefined => {
      const list = (data["courses"] as Record<string, unknown>[])[0]?.["series"] as Record<string, unknown>[];
      return (list?.[0]?.["exercises"] as Record<string, unknown>[])?.[0];
    };
    const seriesEntry = (data: Record<string, unknown>): Record<string, unknown> | undefined =>
      ((data["courses"] as Record<string, unknown>[])[0]?.["series"] as Record<string, unknown>[])?.[0];

    const plain = runExport(false, [{ id: "x" }]);
    check(AssistantExport.formatVersion === 3, "le format est en version 3");
    check((plain["sharing"] as Record<string, boolean>)["files"] === false, "sans réglage, le partage des fichiers est annoncé éteint");
    check(plain["files"] === undefined, "…aucun fichier n'est annoncé (même si on en passe)");
    const plainCourse = (plain["courses"] as Record<string, unknown>[])[0];
    check(plainCourse?.["notes"] === undefined && plainCourse?.["revisionSheet"] === undefined && plainCourse?.["pastExams"] === undefined,
      "…ni notes, ni fiche, ni anciens examens");
    check(exerciseEntry(plain)?.["solution"] === undefined && exerciseEntry(plain)?.["hint"] === undefined, "…ni corrigé rédigé, ni indice");
    check(seriesEntry(plain)?.["url"] === undefined && seriesEntry(plain)?.["solutionUrl"] === undefined, "…ni adresse de série");

    const rich = runExport(true, [{ id: "serie:1", sha: "abc" }]);
    check((rich["sharing"] as Record<string, boolean>)["files"] === true, "le réglage allumé est annoncé");
    check((rich["files"] as Record<string, unknown>[])[0]?.["id"] === "serie:1", "l'index des fichiers voyage");
    const richCourse = (rich["courses"] as Record<string, unknown>[])[0];
    check(richCourse?.["notes"] === "Théorème d'unicité de la limite.", "les notes de cours sont exportées");
    check(Array.isArray(richCourse?.["pastExams"]) && Array.isArray(richCourse?.["resources"]), "anciens examens et ressources : listes présentes");
    check(exerciseEntry(rich)?.["solution"] === "On lit la limite sur le graphe.", "le corrigé rédigé d'un exercice est exporté");
    check(exerciseEntry(rich)?.["hint"] === "Pense à epsilon.", "…et son indice");
    check(seriesEntry(rich)?.["url"] === "https://moodle.example/serie.pdf"
      && seriesEntry(rich)?.["solutionUrl"] === "https://moodle.example/corrige.pdf", "les adresses de la série et de son corrigé sont exportées");
    check(emptyExport["files"] === undefined, "un export vide n'annonce aucun fichier");

    contentCourse.notes = "a".repeat(AssistantExport.notesLimit + 500);
    contentExercise.solution = "b".repeat(AssistantExport.solutionLimit + 500);
    const clipped = runExport(true);
    const clippedNotes = ((clipped["courses"] as Record<string, unknown>[])[0]?.["notes"] as string) ?? "";
    check(clippedNotes.endsWith("[…tronqué]") && clippedNotes.length < AssistantExport.notesLimit + 50,
      `des notes démesurées sont tronquées (${clippedNotes.length} car.)`);
    check(((exerciseEntry(clipped)?.["solution"] as string) ?? "").length < AssistantExport.solutionLimit + 50,
      "…et un corrigé démesuré aussi");
    check((JSON.parse(JSON.stringify(rich))["files"] as unknown[]).length === 1, "l'instantané v3 se relit après un aller-retour JSON");

    contentCourse.notes = before.notes;
    contentExercise.solution = before.solution;
    contentExercise.hint = before.hint;
    contentSeries.urlString = before.url;
    contentSeries.solutionURLString = before.solutionURL;
  } else {
    check(false, "le cours d'exemple a une série et un exercice pour l'export v3");
  }
});

describe("Serveur MCP local (fichiers du Mac)", () => {
  // Le portage garde le protocole et le contrôle d'accès ; la couche socket
  // (Network.framework) est remplacée par un hôte Node dans ce test.
  class FakeFilesProvider implements LocalMCPProvider {
    serverName = "polymestre-files";
    instructions = "essai";
    get tools(): Record<string, unknown>[] {
      return [{ name: "list_files", inputSchema: { type: "object" } }, { name: "read_file", inputSchema: { type: "object" } }];
    }
    async call(name: string, args: Record<string, unknown>): Promise<Record<string, unknown>> {
      return LocalMCPRPC.textResult(`${name}:${String(args["id"] ?? "-")}${args["inline"] === true ? "+inline" : ""}`);
    }
  }

  function nodeHost(): LocalMCPHost {
    let server: ReturnType<typeof createServer> | null = null;
    return {
      start(port, handle) {
        return new Promise((resolve) => {
          const created = createServer((request, response) => {
            const chunks: Uint8Array[] = [];
            request.on("data", (chunk: Uint8Array) => chunks.push(chunk));
            request.on("end", async () => {
              const body = Buffer.concat(chunks);
              const bound = (created.address() as { port: number } | null)?.port ?? 0;
              const headers: Record<string, string> = {};
              for (const [key, value] of Object.entries(request.headers)) {
                if (value !== undefined) headers[key.toLowerCase()] = Array.isArray(value) ? value.join(", ") : value;
              }
              const local = new LocalHTTPRequest({
                method: request.method ?? "GET",
                path: request.url ?? "/",
                headers,
                body: new Uint8Array(body),
              });
              const raw = Buffer.from(await handle(local, bound));
              // `respond` rend une réponse HTTP complète : on la rejoue telle quelle.
              const split = raw.indexOf("\r\n\r\n");
              const head = raw.subarray(0, split).toString("utf8").split("\r\n");
              const status = Number(head[0]?.split(" ")[1] ?? 200);
              const outHeaders: Record<string, string> = {};
              for (const line of head.slice(1)) {
                const colon = line.indexOf(":");
                if (colon > 0) outHeaders[line.slice(0, colon)] = line.slice(colon + 1).trim();
              }
              response.writeHead(status, outHeaders);
              response.end(raw.subarray(split + 4));
            });
          });
          created.on("error", () => resolve(null));
          created.listen(port, "127.0.0.1", () => {
            const address = created.address() as { port: number } | null;
            server = created;
            resolve(address?.port ?? null);
          });
        });
      },
      stop() {
        // Les connexions gardées ouvertes (keep-alive) se ferment aussi : sinon
        // l'ancienne socket répond encore (vu sur la CI Windows).
        server?.closeAllConnections();
        server?.close();
        server = null;
      },
    };
  }

  const token = LocalMCPRPC.makeToken();
  check(token.length >= 43 && /^[A-Za-z0-9_-]+$/.test(token), "jeton local : 256 bits en base64url");

  const server = new LocalMCPServer(token, new FakeFilesProvider(), nodeHost());

  const send = async (path: string, method = "POST", body?: unknown, headers: Record<string, string> = {}, atPort?: number): Promise<{ status: number; json: unknown }> => {
    const port = atPort ?? server.port;
    return new Promise((resolve) => {
      const payload = body === undefined ? undefined : JSON.stringify(body);
      const request = httpRequest({
        // Une socket neuve à chaque requête : jamais celle d'un serveur arrêté.
        host: "127.0.0.1", port, path, method, agent: false, headers: {
          ...(payload !== undefined ? { "Content-Type": "application/json", "Content-Length": String(Buffer.byteLength(payload)) } : {}),
          ...headers,
        },
      }, (response) => {
        const chunks: Buffer[] = [];
        response.on("data", (chunk: Buffer) => chunks.push(chunk));
        response.on("end", () => {
          const text = Buffer.concat(chunks).toString("utf8");
          let json: unknown = null;
          try { json = text === "" ? null : JSON.parse(text); } catch { json = text; }
          resolve({ status: response.statusCode ?? 0, json });
        });
      });
      request.on("error", () => resolve({ status: -1, json: null }));
      if (payload !== undefined) request.write(payload);
      request.end();
    });
  };
  const result = async (body: Record<string, unknown>): Promise<Record<string, unknown> | null> => {
    const response = await send(`/${token}`, "POST", body);
    return response.status === 200 ? ((response.json as Record<string, unknown>)?.["result"] as Record<string, unknown>) ?? null : null;
  };

  it("le serveur local écoute sur 127.0.0.1 avec son jeton dans l'adresse", async () => {
    const port = await server.start(0);
    expect(port !== null && port > 0 && server.url === `http://127.0.0.1:${port}/${token}`).toBe(true);
  });

  it("initialize : version et nom du serveur", async () => {
    const initialize = await result({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18" } });
    expect(initialize?.["protocolVersion"] === "2025-06-18"
      && ((initialize?.["serverInfo"] as Record<string, unknown>)?.["name"] === "polymestre-files")).toBe(true);
  });

  it("…et les instructions pour l'assistant", async () => {
    const initialize = await result({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18" } });
    expect(initialize?.["instructions"]).toBe("essai");
  });

  it("tools/list rend les outils", async () => {
    const list = await result({ jsonrpc: "2.0", id: 2, method: "tools/list" });
    expect((list?.["tools"] as unknown[]).length).toBe(2);
  });

  it("tools/call transmet l'outil et ses arguments", async () => {
    const called = await result({ jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "read_file", arguments: { id: "serie:1" } } });
    expect(((called?.["content"] as Record<string, unknown>[])[0]?.["text"])).toBe("read_file:serie:1");
  });

  it("un outil inconnu est refusé", async () => {
    const response = await send(`/${token}`, "POST", { jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "rm_rf" } });
    expect(response.status).toBe(200);
    expect(((response.json as Record<string, unknown>)?.["error"] as Record<string, unknown>)?.["code"]).toBe(-32602);
  });

  it("une notification reçoit 202", async () => {
    const response = await send(`/${token}`, "POST", { jsonrpc: "2.0", method: "notifications/initialized" });
    expect(response.status).toBe(202);
  });

  it("un lot de requêtes est répondu en lot", async () => {
    const response = await send(`/${token}`, "POST", [
      { jsonrpc: "2.0", id: 1, method: "ping" }, { jsonrpc: "2.0", id: 2, method: "ping" },
    ]);
    expect(response.status).toBe(200);
    expect((response.json as unknown[]).length).toBe(2);
  });

  it("un mauvais jeton est refusé (401)", async () => {
    expect((await send(`/${"x".repeat(token.length)}`, "POST", { jsonrpc: "2.0", id: 1, method: "ping" })).status).toBe(401);
  });
  it("sans jeton : refusé (401)", async () => {
    expect((await send("/", "POST", { jsonrpc: "2.0", id: 1, method: "ping" })).status).toBe(401);
  });
  it("une requête de navigateur (en-tête Origin) est refusée, même avec le bon jeton", async () => {
    expect((await send(`/${token}`, "POST", { jsonrpc: "2.0", id: 1, method: "ping" }, { Origin: "https://evil.example" })).status).toBe(403);
  });
  it("un autre hôte (DNS rebinding) est refusé", async () => {
    expect((await send(`/${token}`, "POST", { jsonrpc: "2.0", id: 1, method: "ping" }, { Host: "evil.example" })).status).toBe(403);
  });
  it("GET : 405 (pas de flux SSE)", async () => {
    expect((await send(`/${token}`, "GET")).status).toBe(405);
  });
  it("un corps illisible : 400", async () => {
    expect((await send(`/${token}`, "POST", undefined)).status).toBe(400);
  });

  // L'analyse HTTP à la main.
  const partial = new TextEncoder().encode("POST /x HTTP/1.1\r\nContent-Length: 5\r\n\r\nab");
  check(LocalHTTPRequest.parse(partial) === null, "analyse : un corps incomplet attend la suite");
  const complete = LocalHTTPRequest.parse(new TextEncoder().encode("POST /x?y=1 HTTP/1.1\r\nHost: a\r\nContent-Length: 2\r\n\r\nab"));
  check(complete !== null && complete.ok && complete.request.method === "POST" && complete.request.path === "/x?y=1"
    && complete.request.headers["host"] === "a" && new TextDecoder().decode(complete.request.body) === "ab",
  "analyse : méthode, chemin, en-têtes, corps");
  const tooLarge = LocalHTTPRequest.parse(new TextEncoder().encode("POST /x HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n"));
  check(tooLarge !== null && !tooLarge.ok && tooLarge.error === "tooLarge", "analyse : un corps démesuré est refusé");
  const chunked = LocalHTTPRequest.parse(new TextEncoder().encode("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"));
  check(chunked !== null && !chunked.ok && chunked.error === "chunked", "analyse : l'encodage par morceaux est refusé");
  check(LocalMCPServer.constantTimeEqual("abc", "abc") && !LocalMCPServer.constantTimeEqual("abc", "abd")
    && !LocalMCPServer.constantTimeEqual("abc", "ab"), "comparaison du jeton à temps constant");

  it("arrêté, plus rien n'écoute", async () => {
    // Le port où il écoutait : plus personne n'y répond.
    const port = server.port;
    server.stop();
    expect((await send(`/${token}`, "POST", { jsonrpc: "2.0", id: 1, method: "ping" }, {}, port)).status).toBe(-1);
  });
});

describe("Catalogue local des fichiers (LocalFileCatalog)", () => {
  check(eq(LocalFileCatalog.pageIndices("1-5,8", 10), [0, 1, 2, 3, 4, 7]), "pages : « 1-5,8 »");
  check(eq(LocalFileCatalog.pageIndices("3", 10), [2]) && eq(LocalFileCatalog.pageIndices("8-", 10), [7, 8, 9]), "pages : une page, une plage ouverte");
  check(eq(LocalFileCatalog.pageIndices("9-20", 10), [8, 9]), "pages : bornées au document");
  check(eq(LocalFileCatalog.pageIndices("2,2,1-3", 5), [1, 0, 2]), "pages : sans doublon, dans l'ordre demandé");
  check(LocalFileCatalog.pageIndices("0,x,5-2", 5) === null && LocalFileCatalog.pageIndices("1", 0) === null, "pages : rien d'utilisable → nil");

  // Le catalogue : tout ce qui se lit d'un cours, sans réseau.
  const exportCourses = courses.filter((course) => course.isTracked);
  const catalogCourse = exportCourses[0];
  const catalogSeries = catalogCourse?.sortedSeries[0];
  if (catalogCourse !== undefined && catalogSeries !== undefined) {
    const before = { url: catalogSeries.urlString, solution: catalogSeries.solutionURLString, notes: catalogCourse.notes };
    catalogSeries.urlString = "https://moodle.epfl.ch/pluginfile.php/1/mod_resource/content/0/serie03.pdf";
    catalogSeries.solutionURLString = "https://moodle.epfl.ch/mod/resource/view.php?id=77";
    catalogCourse.notes = "# Notes\nthéorème d'unicité";
    const exam = new PastExam({
      course: catalogCourse, title: "Examen final", year: 2024, kind: "exam",
      urlString: "https://exemple.ch/examen-2024.pdf", solutionURLString: "https://exemple.ch/page-web", notes: "piège à l'exo 2",
    });
    const upload = new SavedResource({
      course: catalogCourse, title: "Aide-mémoire", kind: "pdf", fileName: "aide.pdf",
      fileData: new TextEncoder().encode("%PDF-1.4"),
    });
    const webLink = new SavedResource({ course: catalogCourse, title: "Un site", address: "https://exemple.ch/site", kind: "web" });
    const document: NotesDocument = {
      path: "Analyse/serie-3.pdf", notebook: "Analyse", title: "Série 3", week: 3,
      seriesNumber: 3, isSolution: false, modified: new Date(),
    };
    const notebook = { courseID: catalogCourse.id, document, url: new URL("file:///tmp/serie-3.pdf") };
    const entries = LocalFileCatalog.entries([catalogCourse], [notebook]);
    const entry = (prefix: string) => entries.find((item) => item.id.startsWith(prefix));

    check(entry("serie:")?.type === "enonce"
      && entry("serie:")?.baseName === `serie-${String(catalogSeries.seriesNumber).padStart(2, "0")}-enonce`,
      "catalogue : l'énoncé PDF de la série");
    check(entry("corrige:")?.type === "corrige" && entry("corrige:")?.seriesNumber === catalogSeries.seriesNumber,
      "…son corrigé (une activité Moodle compte comme document)");
    check(entry("notes:")?.type === "notes", "…les notes de cours");
    check(entry("examen:")?.type === "examen" && entry("examen:")?.baseName.includes("2024") === true, "…l'ancien examen");
    check(entry("corrige-examen:") === undefined, "…mais pas un « corrigé » qui est une page web");
    check(entry("notes-examen:")?.type === "notes-examen", "…les notes d'un ancien examen");
    check(entry(`ressource:${upload.id}`)?.type === "ressource", "…le fichier ajouté à un cours");
    check(entry(`ressource:${webLink.id}`) === undefined, "…mais pas un simple lien web");
    check(entry("cahier:")?.type === "cahier" && entry("cahier:")?.seriesNumber === 3 && entry("cahier:")?.week === 3,
      "…le cahier du dossier de notes, avec sa série et sa semaine");
    const courseEntries = entries.filter((item) => item.courseID === catalogCourse.id);
    check(new Set(courseEntries.map((item) => item.id)).size === courseEntries.length, "catalogue : identifiants uniques");
    check(courseEntries.every((item) => !item.baseName.includes("/") && !item.baseName.includes("..") && !item.baseName.includes(" ")),
      "catalogue : des noms de fichiers sûrs");
    check(LocalFileCatalog.filter(entries, null, "examen", null, null).length === 1, "filtre par type");
    check(LocalFileCatalog.filter(entries, null, null, 3, null).every((item) => item.seriesNumber === 3), "filtre par série");
    check(LocalFileCatalog.filter(entries, null, null, null, "Aide MÉMOIRE").length === 1, "recherche sans accents ni majuscules");
    check(LocalFileCatalog.documentURL("https://exemple.ch/site") === null && LocalFileCatalog.documentURL("https://exemple.ch/a.pptx") !== null
      && LocalFileCatalog.documentURL("file:///tmp/a.pdf") !== null && LocalFileCatalog.documentURL("") === null,
    "une page web n'est pas un document ; un .pptx ou un fichier local, si");
    check(LocalFileCatalog.slug("Séries d'Analyse — n°3") === "series-d-analyse-n-3" && LocalFileCatalog.hash("a") === LocalFileCatalog.hash("a")
      && LocalFileCatalog.hash("a") !== LocalFileCatalog.hash("b"), "slug lisible, empreinte stable");

    catalogSeries.urlString = before.url;
    catalogSeries.solutionURLString = before.solution;
    catalogCourse.notes = before.notes;
    void exam;
  } else {
    check(false, "le cours d'exemple a une série pour le catalogue");
  }
});

describe("Assistant : commandes appliquées par l'app", () => {
  const aCourse = new Course({ code: "TEST-401", name: "Commandes" });
  const aSeries = new ExerciseSeries({ course: aCourse, seriesNumber: 1 });
  const aEx = new Exercise({ series: aSeries, exerciseNumber: "1.1", sortOrder: 0 });
  const qa = new SubQuestion({ exercise: aEx, label: "a", sortOrder: 0 });
  const qb = new SubQuestion({ exercise: aEx, label: "b", sortOrder: 1 });
  aEx.subQuestions = [qa, qb];
  const aItem = new TheoryItem({ course: aCourse, sectionNumber: 2, number: "2.1", title: "Suites" });

  const json = `[
   {"id":"c1","kind":"check_questions","payload":{"course":"test-401","exercise":"1.1","questions":["(a)"]}},
   {"id":"c2","kind":"update_exercise","payload":{"exerciseId":"${aEx.id}","correctness":"orange"}},
   {"id":"c3","kind":"update_exercise","payload":{"exerciseId":"${aEx.id}","correctness":"wrong","note":"signe"}},
   {"id":"c4","kind":"update_theory","payload":{"theoryId":"${aItem.id}","summary":"Définition de la limite"}},
   {"id":"c5","kind":"log_session","payload":{"course":"TEST-401","type":"exercise","minutes":45,"exercise":"1.1"}},
   {"id":"c6","kind":"add_series","payload":{"course":"TEST-401","number":2,"week":3,"exercises":[{"number":"2.1","questions":["a","b","c"]},{"number":"2.2","bonus":true}]}},
   {"id":"c7","kind":"add_exam","payload":{"course":"TEST-401","title":"Midterm","date":"2026-10-19","examKind":"midterm"}},
   {"id":"c8","kind":"update_exercise","payload":{"course":"TEST-401","exercise":"9.9","done":true}},
   {"id":"c9","kind":"teleport","payload":{}}]`;
  const commands = AssistantCommand.decodeList(json);
  check(commands.length === 9, `les commandes du serveur se décodent (${commands.length})`);
  const results = AssistantCommandApplier.apply(commands, [aCourse]);
  const status = new Map(results.map((result) => [result.id, result.status]));
  check(status.get("c1") === "applied" && results.find((result) => result.id === "c1")?.message.includes("(1/2)") === true,
    "cocher une question par son étiquette");
  check(results.find((result) => result.id === "c2")?.message.includes("moyen") === true, "« orange » est compris comme une correction moyenne");
  check(aEx.correctness === "wrong" && aEx.redoRequired && aEx.correctionNote === "signe", "corrigé faux : à refaire, remarque gardée");
  check(aItem.isSummarized && aItem.isWatched, "un résumé marque la théorie vue");
  check(status.get("c5") === "applied" && aEx.series?.course?.id === aCourse.id, "session enregistrée");
  const newSeries = aCourse.series.find((series) => series.seriesNumber === 2);
  check(newSeries?.exercises.length === 2 && newSeries?.plannedWeek === 3, "série ajoutée, à sa semaine");
  check(newSeries?.exercises.find((exercise) => exercise.exerciseNumber === "2.1")?.leafSubQuestions.length === 3, "…avec ses questions");
  check(newSeries?.exercises.find((exercise) => exercise.exerciseNumber === "2.2")?.isBonus === true, "…et son bonus");
  check(aCourse.exams[0]?.kind === "midterm", "évaluation ajoutée");
  check(status.get("c8") === "failed" && results.find((result) => result.id === "c8")?.message.includes("9.9") === true,
    "une cible introuvable échoue avec un message clair");
  check(status.get("c9") === "failed", "une commande inconnue échoue sans rien casser");
  check(AssistantCommandApplier.confidence("Vert") === "green" && AssistantCommandApplier.correctness("juste") === "correct",
    "les valeurs en français sont comprises");

  const exported = AssistantExport.make({
    courses: [aCourse], sessions: [], milestones: [], groups: [], hoursPerCredit: 30, displayName: "",
  });
  const firstCourse = (exported["courses"] as Record<string, unknown>[])[0];
  const firstExercise = ((firstCourse?.["series"] as Record<string, unknown>[])?.[0]?.["exercises"] as Record<string, unknown>[])?.[0];
  check(exported["version"] === AssistantExport.formatVersion && firstCourse?.["id"] === aCourse.id, "l'instantané porte les identifiants");
  check(firstExercise?.["stage"] === "à refaire" && (firstExercise?.["questions"] as unknown[]).length === 2,
    "…l'étape de chaque exercice et ses questions");
});

describe("Session Supabase conservée entre deux lancements", () => {
  const sessionNow = new Date();
  const freshSession = new StoredSession({
    accessToken: "jeton", refreshToken: "rafraîchir", userID: "u1", email: "a@b.ch",
    expiresAt: new Date(sessionNow.getTime() + 3_600_000),
  });
  check(!freshSession.isExpired(sessionNow), "un jeton d'une heure n'est pas expiré");
  check(freshSession.isUsable, "un jeton non vide est utilisable");
  check(freshSession.userID === "u1", "l'identifiant survit au stockage");

  const staleSession = new StoredSession({
    accessToken: "jeton", expiresAt: new Date(sessionNow.getTime() - 1000),
  });
  check(staleSession.isExpired(sessionNow), "un jeton dépassé est expiré");
  check(staleSession.refreshToken === null, "sans jeton de rafraîchissement, il faudra se reconnecter");

  // La marge : un jeton qui expire dans 30 s est traité comme expiré.
  const nearly = new StoredSession({ accessToken: "jeton", expiresAt: new Date(sessionNow.getTime() + 30_000) });
  check(nearly.isExpired(sessionNow), `un jeton expirant dans 30 s est renouvelé d'avance (marge ${StoredSession.leeway} s)`);
  const comfortable = new StoredSession({
    accessToken: "jeton", expiresAt: new Date(sessionNow.getTime() + (StoredSession.leeway + 30) * 1000),
  });
  check(!comfortable.isExpired(sessionNow), "au-delà de la marge, on garde le jeton");

  check(new StoredSession({ accessToken: "x", expiresAt: sessionNow })
    .equals(new StoredSession({ accessToken: "x", expiresAt: sessionNow })), "deux sessions identiques se comparent");
});

describe("Le cadre du tuteur (TutorFramework)", () => {
  const T = TutorFramework;
  // Les numéros de page : le seul texte libre qu'on lit.
  check(eq(T.pageRequest("regarde page 4"), [4]), "page : « regarde page 4 »");
  check(eq(T.pageRequest("regarde p. 4 et 5"), [4, 5]), "page : « p. 4 et 5 »");
  check(eq(T.pageRequest("pages 3-5"), [3, 4, 5]), "page : une plage");
  check(eq(T.pageRequest("p4"), [4]), "page : « p4 »");
  check(eq(T.pageRequest("je bloque sur le 6.3"), []), "page : pas de page sans le mot");
  check(eq(T.pageRequest("map 3"), []), "page : un mot qui finit par p n'est pas une page");
  check(T.pageRequest("pages 1-40").length === 1 || eq(T.pageRequest("pages 1-40"), [1]), "page : une plage trop longue n'est pas dépliée");
  check(eq(T.copyPageRequest("regarde page 4"), [4]), "copie : page 4 de la copie");
  check(eq(T.copyPageRequest("regarde la page 4 de la série"), []) && eq(T.copyPageRequest("page 4 du polycopié"), []),
    "copie : la page de la série ou du poly n'est pas dans le cahier");
  check(T.ranges([5, 3, 4, 9]) === "3–5, 9", "pages : plages");

  // L'état : le mot qui ne dit pas « pas essayé », l'indice suivant.
  const state = new TutorState({
    exercise: "Série 6 · Exercice 6.3", hintLevel: 1, questionsDone: 0, questionsTotal: 3,
    copy: { notebook: "Séance Et Série 6", pagesSeen: [1, 2, 3, 4], total: 11 },
  });
  const card = T.card(state, [{ kind: "copy", notebook: "Séance Et Série 6", pages: [4], total: 11, requested: true }]);
  check(card.startsWith("[Polymestre]") && card.includes("[/Polymestre]"), "carte : dans le bloc que l'app retire");
  check(card.includes("pas encore marqué fait") && !card.includes("à faire"), "carte : « pas encore marqué fait », pas « à faire »");
  check(card.includes("jusqu'au niveau 1/4") && card.includes("niveau 2 (outil)"), "carte : le niveau suivant est dit");
  check(card.includes("mon écriture") && card.includes("pas un corrigé"), "carte : la copie est de l'étudiant·e");
  check(card.includes("celles que je te demande de regarder") && card.includes("1re page est la page 4"), "carte : la page demandée et sa numérotation");
  check(card.includes("pages que tu as déjà reçues : 1–4 sur 11"), "carte : les pages déjà reçues");
  check(card.split("\n").filter((line) => line !== "").length <= 8, "carte : courte");
  check(ClaudeTutor.displayText(card + "et maintenant ?") === "et maintenant ?", "carte : retirée à l'affichage");
  check(T.exercise(card) === "Série 6 · Exercice 6.3" && T.shortExercise("Série 6 · Exercice 6.3") === "Exercice 6.3",
    "carte : l'exercice se relit (séparateurs d'une conversation reprise)");
  state.hintLevel = 0;
  check(T.card(state).includes("Un premier indice est de niveau 1"), "carte : aucun indice → niveau 1");
  state.tutor = false;
  check(!T.card(state).includes("niveau 1 (orientation)") && T.card(state).includes("explications"), "carte : mode explications");
  check(T.card(new TutorState()).includes("pas d'exercice choisi") && T.exercise(T.card(new TutorState())) === null, "carte : sans exercice");
  check(T.chip({ kind: "copy", notebook: "N", pages: [4], total: 11, requested: true }) === "Ma copie · p. 4", "bulle : « Ma copie · p. 4 »");

  // Les gestes.
  check(T.hintPrompt(0).includes("niveau 1") && T.hintPrompt(1).includes("niveau 2") && T.hintPrompt(2).includes("niveau 3")
    && T.hintPrompt(3).includes("niveau 3"), "indice : un cran de plus (le 4 est « La solution »)");
  const s1 = new TutorState({
    exercise: "E", hintLevel: 0, copy: { notebook: "N", pagesSeen: [], total: 3 },
  });
  check(eq(T.suggestions(s1, false)[0], TutorNext.hint(1)), "propositions : d'abord l'indice 1");
  s1.hintLevel = 1;
  check(eq(T.suggestions(s1, false)[0], TutorNext.hint(2)), "propositions : après l'indice 1, l'indice 2");
  check(eq(T.suggestions(s1, true)[0], TutorNext.tryIt), "propositions : une question posée → à toi d'essayer");
  s1.hintLevel = 3;
  check(T.suggestions(s1, false).some((next) => next.kind === "solution")
    && !T.suggestions(s1, false).some((next) => next.kind === "hint"), "propositions : après l'amorce, la solution");
  s1.copy = null; s1.hintLevel = 0;
  check(!T.suggestions(s1, false).some((next) => next.kind === "check"), "propositions : pas de vérification de copie sans copie");
  check(eq(T.suggestions(new TutorState(), false), [TutorNext.explain]), "propositions : sans exercice, la notion");
  check(T.suggestions(s1, false).length <= 3, "propositions : trois au plus");
  check(T.asksQuestion("Quel X isole une colonne ?\n\n```polymestre\n6.3 | 1 | x\n```") && !T.asksQuestion("Voilà."),
    "réponse : finit sur une question");

  // Les règles de la consigne.
  const prompt = ClaudeTutor.systemPrompt("tutor");
  check(prompt.includes("Ne refuse jamais de lire") && prompt.includes("niveau **suivant**") && prompt.includes("une centaine de mots"),
    "consigne : copie à lui, indice suivant, brièveté");
  check(!ClaudeTutor.systemPrompt("explain").includes("Échelle d'indices"), "consigne : pas d'échelle en mode explications");
  // Non porté : SeriesReview.parse (fichier d'un autre job) — couvert par ses propres tests.

  const preamble = ClaudeTutor.contextPreamble({
    courseCode: "MATH-101", exercise: "Série 3 · Ex 2", statement: "Montrer que…",
    questions: ["1. a", "1. b"], doneQuestions: 1,
  });
  check(preamble.includes("MATH-101") && preamble.includes("(1/2 faites)"), "contexte : cours, exercice, avancement");
  check(ClaudeTutor.contextPreamble({}) === "", "contexte vide : rien d'ajouté");
});

describe("Claude dans le mode étude (ClaudeTutor, RichMarkup)", () => {
  const series = "11111111-2222-3333-4444-555555555555";
  const sid = ClaudeTutor.sessionID(series, "isolated");
  check(sid === ClaudeTutor.sessionID(series, "isolated"), "session : la même pour une série");
  check(sid !== ClaudeTutor.sessionID(series, "project")
    && sid !== ClaudeTutor.sessionID(series, "isolated", 1)
    && sid !== ClaudeTutor.sessionID("22222222-2222-3333-4444-555555555555", "isolated"), "session : autre profil, autre génération, autre série");
  check(sid.split("")[14] === "5", "session : un UUID de forme v5");

  const args = ClaudeTutor.arguments({ sessionID: sid, systemPrompt: "P" });
  check(args.includes("--safe-mode") && args.includes("--strict-mcp-config") && args.includes("--disable-slash-commands"),
    "Claude isolé : sans configuration, sans MCP, sans commandes");
  check(!args.includes("--no-session-persistence"), "Claude : la conversation est gardée");
  const sessionIndex = args.indexOf("--session-id");
  check(sessionIndex >= 0 && args[sessionIndex + 1] === sid, "Claude : la session de la série");
  const toolsIndex = args.indexOf("--tools");
  check(toolsIndex >= 0 && args[toolsIndex + 1] === "", "Claude isolé : aucun outil");
  check(!args.includes("--model"), "Claude : le modèle de l'abonnement par défaut");
  check(!args.some((arg) => arg.includes("api-key")), "Claude : jamais de clé d'API");
  const resumed = ClaudeTutor.arguments({ sessionID: "S", resume: true, systemPrompt: "P" });
  check(resumed.includes("--resume") && !resumed.includes("--session-id"), "Claude : une session existante se reprend");

  const projectFile = new ClaudeProjectFile({ mcpServers: { notion: new ClaudeServer({ url: "https://mcp.notion.com/mcp" }) } });
  const project = ClaudeTutor.arguments({
    profile: "project", sessionID: "S", systemPrompt: "P", mcpConfigPath: "/tmp/mcp.json",
    allowedTools: ClaudeProject.allowedTools(projectFile, false),
    tools: ClaudeProject.tools(projectFile), deniedServers: ["rea"],
  });
  check(!project.includes("--safe-mode") && !project.includes("--disable-slash-commands"), "projet EPFL : compétences et commandes chargées");
  check(!project.includes("--setting-sources") && !project.includes("--strict-mcp-config"), "projet : les connecteurs du compte se chargent");
  const settingsIndex = project.indexOf("--settings");
  check(settingsIndex >= 0 && project[settingsIndex + 1] === '{"deniedMcpServers":[{"serverName":"rea"}]}', "projet : serveurs locaux écartés");
  check(project.includes("/tmp/mcp.json"), "projet : les serveurs du fichier en plus");
  const listed = ClaudeProject.servers("Checking MCP server health…\n\nclaude.ai Claude Docs: https://api.anthropic.com/v1/pages/mcp - ✔ Connected\nclaude.ai Notion: https://mcp.notion.com/mcp - ✔ Connected\nrea: npx -y rea-agents@6.4.0 mcp - ✔ Connected\n");
  check(eq(listed.connectors, ["claude.ai Claude Docs", "claude.ai Notion"]) && eq(listed.local, ["rea"]), "mcp list : connecteurs et serveurs locaux");
  check(ClaudeProject.toolPrefix("claude.ai Claude Docs") === "mcp__claude_ai_Claude_Docs", "préfixe d'outils d'un connecteur");
  check(eq(ClaudeProject.allowedTools(new ClaudeProjectFile(), false, ["claude.ai Notion"]), ["Read", "Glob", "Skill", "mcp__claude_ai_Notion"]),
    "les connecteurs du compte sont permis");
  // L'éditeur des boutons ne réécrit que les boutons et les modèles.
  const original = '{"skills":["epfl-serie"],"mcpServers":{"todoist":{"url":"https://ai.todoist.net/mcp"}},"maClé":42,"commands":[]}';
  const edited = ClaudeProject.updating(original, [
    new ClaudeCommand({ id: "brief", label: "Brief", icon: "sun.max", prompt: "brief" }),
    new ClaudeCommand({ id: "bloque", label: "Bloqué", prompt: "indice {exercice}", scope: "series", model: "tutor", capture: true }),
  ], new ClaudeModels({ tutor: "haiku", system: null }));
  const reread = edited !== null ? ClaudeProjectFile.decode(edited) : null;
  check(eq(reread?.commands.map((command) => command.id), ["brief", "bloque"]) && reread?.commands[1].scope === "series"
    && reread?.commands[1].capture === true && reread?.commands[0].capture === null, "éditeur : boutons écrits et relus");
  check(eq(reread?.skills, ["epfl-serie"]) && reread?.mcpServers["todoist"]?.url === "https://ai.todoist.net/mcp"
    && reread?.models.tutor === "haiku" && reread?.models.system === null, "éditeur : le reste du fichier gardé");
  check(edited !== null && edited.includes('"maClé" : 42'), "éditeur : une clé inconnue gardée");
  check(ClaudeProject.updating("[1]", [], new ClaudeModels()) === null, "éditeur : un fichier qui n'est pas un objet n'est pas écrasé");
  const freshFile = ClaudeProject.updating(null, [], new ClaudeModels());
  check(freshFile !== null && ClaudeProjectFile.decode(freshFile) !== null, "éditeur : fichier neuf");
  check(ClaudeProject.commandID("Où j'en suis", []) === "ou-j-en-suis"
    && ClaudeProject.commandID("Brief", ["brief"]) === "brief-2" && ClaudeProject.commandID("!!", []) === "bouton",
  "éditeur : identifiant tiré du libellé");
  check(project[project.indexOf("--allowedTools") + 1] === "Read,Glob,Skill,mcp__notion", "projet EPFL : outils permis");
  check(project[project.indexOf("--tools") + 1] === "Read,Glob,Skill", "projet EPFL : ni terminal ni écriture");
  check(project.includes("--append-system-prompt") && !project.includes("--system-prompt"), "projet EPFL : la consigne s'ajoute à celle de Claude Code");

  check(ClaudeTutor.sessionRecovery("Error: No conversation found with session ID: abc") === "startFresh", "session perdue : on repart");
  check(ClaudeTutor.sessionRecovery("Error: Session ID abc is already in use.") === "resume", "session déjà là : on la reprend");
  check(ClaudeTutor.sessionRecovery("autre chose") === null, "autre erreur : rien");
  check(ClaudeTutor.sessionFolderName("/Users/a/Library/Caches/Polymestre/claude") === "-Users-a-Library-Caches-Polymestre-claude"
    && ClaudeTutor.sessionFolderName("/Users/a/Application Support/x.y") === "-Users-a-Application-Support-x-y",
  "dossier des sessions de Claude Code");

  const opening = ClaudeTutor.openingMessage({
    courseCode: "MATH-101", title: "Série 3", week: 3, due: "jeudi",
    exercises: [{ number: "1", status: "fait" }, { number: "2", status: "à faire" }],
    pdfAttached: true,
  }, null, "epfl-serie");
  check(opening.startsWith("/epfl-serie ") && opening.includes("- 2 : à faire") && opening.includes("PDF joint"),
    "série : la compétence lancée avec la série et ses exercices");
  const plain = ClaudeTutor.openingMessage({ title: "Série 3" }, null, null);
  check(!plain.startsWith("/") && plain.includes("Série 3"), "série sans compétence : le contexte seul");
  check(ClaudeTutor.displayText(opening) === "/epfl-serie On attaque « Série 3 » (MATH-101).", "affichage : sans le contexte de l'app");
  const switched = ClaudeTutor.exerciseSwitch({ exercise: "Exercice 2" });
  check(switched.includes("autre exercice") && switched.includes("Exercice 2") && ClaudeTutor.displayText(switched + "Et là ?") === "Et là ?",
    "changer d'exercice dans la conversation");

  const report = "Bilan.\n\n```polymestre\n1 : juste\nEx 2 : moyen\nexercice 3: FAUX\n4 : ?\n```\nVoilà.";
  check(eq(ClaudeTutor.verdicts(report), [
    { exercise: "1", result: "correct" }, { exercise: "2", result: "partial" }, { exercise: "3", result: "wrong" },
  ]), "post-mortem : verdicts lus");
  check(!ClaudeTutor.withoutVerdicts(report).includes("polymestre"), "post-mortem : le bloc ne s'affiche pas en texte");
  check(ClaudeTutor.verdicts("rien").length === 0, "pas de bloc, pas de verdict");
  check(ClaudeTutor.postMortemPrompt(true).includes("```polymestre"), "post-mortem : le format demandé");
  check(ClaudeTutor.matchExercise("2", ["1", "2", "3"]) === 1, "verdict → exercice 2");
  check(ClaudeTutor.matchExercise("3", ["Ex-03-01", "Ex-03-03"]) === 1, "verdict → numéro à tirets");
  check(ClaudeTutor.matchExercise("1.2", ["1.1", "1.2"]) === 1 && ClaudeTutor.matchExercise("9", ["1"]) === null,
    "verdict : numéro composé, inconnu");

  const initLine = '{"type":"system","subtype":"init","session_id":"S","model":"claude-opus","permissionMode":"default","skills":["anthropic-skills:pdf","epfl-serie"],"tools":["Read","Skill"],"mcp_servers":[{"name":"notion","status":"needs-auth"}]}';
  const started = ClaudeTutor.parse(initLine);
  if (started?.kind === "started") {
    check(started.info.sessionID === "S" && started.info.hasSkill("epfl-serie") && started.info.hasSkill("pdf") && !started.info.hasSkill("epfl-anki"),
      "début : session et compétences");
    check(eq(started.info.mcpServers, [{ name: "notion", status: "needs-auth" }]) && started.info.permissionMode === "default",
      "début : MCP et permissions");
  } else {
    check(false, "début de session lu");
  }
  check(eq(ClaudeTutor.parse('{"type":"result","subtype":"success","is_error":false,"usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":900}}'),
    { kind: "finished", error: null, contextTokens: 1002 }), "fin : taille du contexte");
  check(eq(ClaudeTutor.parse('{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","name":"mcp__notion__notion-search"}}}'),
    { kind: "tool", name: "mcp__notion__notion-search" }), "flux : un outil");
  check(ClaudeTutor.toolLabel("mcp__notion__notion-search") === "Notion" && ClaudeTutor.toolLabel("mcp__polymestre__get_course") === "Polymestre",
    "outil : nom lisible");
  const jsonl = [
    '{"type":"user","message":{"role":"user","content":"<command-message>epfl-serie</command-message>\\n<command-name>/epfl-serie</command-name>\\n<command-args>On attaque.\\n\\n[Polymestre]\\nCours : X\\n[/Polymestre]\\n\\nPar où ?</command-args>"}}',
    '{"type":"user","isMeta":true,"message":{"role":"user","content":[{"type":"text","text":"Base directory for this skill"}]}}',
    '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Salut"},{"type":"tool_use","name":"Read"}]}}',
    '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"x"}]}}',
    '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"On commence."}]}}',
    '{"type":"user","message":{"role":"user","content":[{"type":"document"},{"type":"text","text":"[Polymestre]\\nCours : X\\n[/Polymestre]\\n\\nUn indice ?"}]}}',
  ].join("\n");
  const history = ClaudeTutor.history(jsonl);
  check(eq(history.map((message) => ({ fromStudent: message.fromStudent, text: message.text })), [
    { fromStudent: true, text: "/epfl-serie On attaque.\n\nPar où ?" },
    { fromStudent: false, text: "Salut\n\nOn commence." },
    { fromStudent: true, text: "Un indice ?" },
  ]), "conversation reprise : messages réaffichés, sans contexte ni outils");

  // Le projet EPFL
  const md = ClaudeProject.claudeMD(null, "A");
  check(md.includes(ClaudeProject.beginMarker) && md.includes("A"), "CLAUDE.md : créé");
  const mine = "# Mes notes\n\nGarder ça.";
  const merged = ClaudeProject.claudeMD(mine, "A");
  check(merged.startsWith(mine) && merged.includes("A"), "CLAUDE.md : la partie de l'app s'ajoute");
  const updated = ClaudeProject.claudeMD(merged, "B");
  check(updated.startsWith(mine) && updated.includes("B") && !updated.includes("\nA\n")
    && updated.split(ClaudeProject.beginMarker).length === 2, "CLAUDE.md : la partie de l'app est remplacée, le reste gardé");
  const ctx = ClaudeProject.context([{ code: "MATH-101", name: "Analyse I", week: 4, progress: "Série 4 : 1/5" }], 4, "12 oct.");
  check(ctx.includes("MATH-101 — Analyse I (semaine 4) · Série 4 : 1/5") && ctx.includes("Semaine du semestre : 4"), "CLAUDE.md : cours et semaine");
  const json = `{"skills":["epfl-serie","epfl-planning"],"seriesSkill":"epfl-serie","models":{"tutor":"haiku","system":"sonnet"},
 "mcpServers":{"notion":{"type":"http","url":"https://mcp.notion.com/mcp"},"todoist":{"type":"http","url":"https://ai.todoist.net/mcp"}},
 "allowedTools":["Write(./memoire/**)","Edit(./memoire/**)"],
 "commands":[{"id":"brief","label":"Brief","icon":"sun.max","prompt":"brief"},
             {"id":"pm","label":"Post-mortem","prompt":"post-mortem série {serie} {cours}","scope":"series","model":"system","verdicts":true},
             {"id":"bloque","label":"Bloqué","prompt":"bloqué sur l'exercice {exercice}","scope":"series","capture":true}]}`;
  const file = ClaudeProjectFile.decode(json);
  if (file !== null) {
    check(eq(file.commandsFor("system").map((command) => command.id), ["brief"])
      && eq(file.commandsFor("series").map((command) => command.id), ["pm", "bloque"]), "fichier : boutons par conversation");
    check(file.modelFor(file.commands[0], "system") === "sonnet" && file.modelFor(file.commands[2], "series") === "haiku"
      && file.modelFor(file.commands[1], "series") === "sonnet", "fichier : le modèle de chaque bouton");
    check(eq(ClaudeProject.tools(file), ["Read", "Glob", "Skill", "Write", "Edit"]), "fichier : écriture limitée chargée");
    check(eq(ClaudeProject.allowedTools(file, false), ["Read", "Glob", "Skill", "mcp__notion", "mcp__todoist", "Write(./memoire/**)", "Edit(./memoire/**)"]),
      "fichier : règles permises");
    const mcp = JSON.parse(ClaudeProject.mcpConfig(file, "https://x.supabase.co/functions/v1/mcp/T")) as Record<string, unknown>;
    const serverNames = Object.keys(mcp["mcpServers"] as Record<string, unknown>);
    check(serverNames.length === 3 && ["notion", "todoist", "polymestre"].every((name) => serverNames.includes(name)),
      "MCP : les serveurs du fichier et Polymestre");
    check(!ClaudeProject.mcpConfig(file, "http://pas-sur").includes("polymestre"), "MCP : une adresse non chiffrée est refusée");
    const withLocal = JSON.parse(ClaudeProject.mcpConfig(file, null, "http://127.0.0.1:47821/TOKEN")) as Record<string, unknown>;
    const localEntry = (withLocal["mcpServers"] as Record<string, Record<string, unknown>>)["polymestre-files"];
    check(localEntry?.["url"] === "http://127.0.0.1:47821/TOKEN" && localEntry?.["type"] === "http", "MCP : le serveur local des fichiers est déclaré");
    check(!ClaudeProject.mcpConfig(file, null, "http://evil.example:47821/T").includes("polymestre-files"),
      "MCP : seule la boucle locale est acceptée comme serveur de fichiers");
    check(!ClaudeProject.mcpConfig(file, null, null).includes("polymestre-files"), "MCP : éteint, il n'est pas déclaré");
    check(ClaudeProject.allowedTools(file, false, [], true).includes("mcp__polymestre-files")
      && !ClaudeProject.allowedTools(file, false).includes("mcp__polymestre-files"), "MCP : ses outils ne sont permis que s'il tourne");
    check(ClaudeProject.permissionSummary(file, false, [], true).includes("fichiers du Mac"), "MCP : les permis le disent");
    check(ClaudeProject.permissionSummary(file, true) === "lecture, compétences, écriture limitée, Notion, Todoist, Polymestre",
      "permissions en clair");
    check(ClaudeProject.expand(file.commands[1].prompt, { code: "MATH-101", course: "analyse", seriesNumber: "4" }) === "post-mortem série 4 analyse",
      "commande : série et cours remplis");
  } else {
    check(false, "fichier du projet lisible");
  }
  check(ClaudeProjectFile.decode(ClaudeProject.emptyFileTemplate)?.equals(new ClaudeProjectFile()) === true, "fichier vide : lisible, sans rien");
  check(ClaudeProjectFile.decode("{}")?.commands.length === 0, "fichier minimal : aucun bouton");
  check(ClaudeProject.shortCourseName("Analyse I classe inversée") === "analyse" && ClaudeProject.shortCourseName("Algèbre linéaire") === "algebre",
    "nom court d'un cours");

  const attachment: ClaudeAttachment = { kind: { type: "pdf" }, data: Uint8Array.from([1, 2, 3]), name: "Série 3" };
  const line = ClaudeTutor.userLine("Aide", [attachment]);
  const object = JSON.parse(line) as Record<string, unknown>;
  const message = object["message"] as Record<string, unknown>;
  const content = message["content"] as Record<string, unknown>[];
  check(object["type"] === "user" && content.length === 2, "message : pièce jointe puis texte");
  check(content[0]?.["type"] === "document" && content.at(-1)?.["text"] === "Aide", "message : le PDF est un document");
  check(eq(ClaudeTutor.parse('{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Bon"}}}'),
    { kind: "text", text: "Bon" }), "flux : un morceau de texte");
  check(eq(ClaudeTutor.parse('{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}}'),
    { kind: "thinking" }), "flux : Claude réfléchit");
  check(eq(ClaudeTutor.parse('{"type":"result","subtype":"success","is_error":false}'), { kind: "finished", error: null }),
    "flux : réponse finie");
  check(eq(ClaudeTutor.parse('{"type":"result","subtype":"error_during_execution","is_error":true,"result":"limite"}'),
    { kind: "finished", error: "limite" }), "flux : une erreur se dit");
  check(eq(ClaudeTutor.parse('{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"five_hour":{"utilization":0.33}}}}'),
    { kind: "usage", value: 0.33 }), "flux : l'usage de l'abonnement");
  check(ClaudeTutor.parse('{"type":"system","subtype":"init"}') === null && ClaudeTutor.parse("pas du json") === null, "flux : le bruit est ignoré");
  check(ClaudeTutor.systemPrompt("tutor").includes("Échelle d'indices"), "tuteur : indices avant la solution");

  const blocks = RichMarkup.blocks(`## Idée
On pose $u_n$ et
on conclut.

- premier
  - sous-point
1. étape
$$\\sum_{k=1}^n k = \\frac{n(n+1)}{2}$$
\`\`\`
let x = 1
\`\`\``);
  check(eq(blocks, [
    { kind: "heading", text: "Idée", level: 2 },
    { kind: "paragraph", text: "On pose $u_n$ et on conclut." },
    { kind: "bullet", text: "premier", depth: 0 },
    { kind: "bullet", text: "sous-point", depth: 1 },
    { kind: "numbered", text: "étape", number: 1 },
    { kind: "math", text: "\\sum_{k=1}^n k = \\frac{n(n+1)}{2}" },
    { kind: "code", text: "let x = 1" },
  ]), "réponse : titres, paragraphes, listes, formule isolée, code");
  check(eq(RichMarkup.blocks("$$\na^2\n$$"), [{ kind: "math", text: "a^2" }]), "formule isolée sur plusieurs lignes");
  check(eq(RichMarkup.inlines("Le **point** clé : $x_n$, `f` et *vite*."), [
    { kind: "text", text: "Le " }, { kind: "bold", text: "point" }, { kind: "text", text: " clé : " },
    { kind: "math", text: "x_n" }, { kind: "text", text: ", " }, { kind: "code", text: "f" },
    { kind: "text", text: " et " }, { kind: "italic", text: "vite" }, { kind: "text", text: "." },
  ]), "en ligne : gras, formule, code, italique");
  check(eq(RichMarkup.inlines("nom_de_variable et 5\\$"), [{ kind: "text", text: "nom_de_variable et 5$" }]),
    "pas d'italique dans un mot, dollar échappé");

  // Courseware : la formule isolée arrive au milieu du paragraphe.
  const quiz = RichMarkup.blocks("les matrices \\[ A_1=\\begin{pmatrix} 0 & 1 \\\\ 0 & 0 \\end{pmatrix} \\] Parmi les possibilités suivantes");
  check(eq(quiz, [
    { kind: "paragraph", text: "les matrices" },
    { kind: "math", text: "A_1=\\begin{pmatrix} 0 & 1 \\\\ 0 & 0 \\end{pmatrix}" },
    { kind: "paragraph", text: "Parmi les possibilités suivantes" },
  ]), "formule \\[…\\] au milieu d'une ligne : sur sa propre ligne");
  check(eq(RichMarkup.blocks("Soit $$x^2$$ donc"), [
    { kind: "paragraph", text: "Soit" }, { kind: "math", text: "x^2" }, { kind: "paragraph", text: "donc" },
  ]), "formule $$…$$ au milieu d'une ligne");
  check(RichMarkup.blocks("On a \\begin{align} a &= b \\end{align} fin").some((block) =>
    block.kind === "math" && block.text === "\\begin{align} a &= b \\end{align}"), "environnement align hors délimiteur : formule isolée");
  check(eq(RichMarkup.blocks("```\n\\[ x \\]\n```"), [{ kind: "code", text: "\\[ x \\]" }]), "pas de formule dans un bloc de code");
  check(eq(RichMarkup.inlines("Voir [le corrigé](https://moodle.epfl.ch/x.pdf) ici"), [
    { kind: "text", text: "Voir " }, { kind: "link", text: "le corrigé", url: "https://moodle.epfl.ch/x.pdf" },
    { kind: "text", text: " ici" },
  ]), "lien Markdown");
  check(eq(RichMarkup.inlines("l'intervalle [0, 1](x) reste"), [{ kind: "text", text: "l'intervalle [0, 1](x) reste" }]),
    "crochets qui ne sont pas un lien");
  // Non porté ici : TeXNormalizer, BotafogoPage.liftingDisplayMath, SeriesReview.parse
  // et RedoLadder (fichiers d'autres jobs, testés par leurs sections).
});

describe("Extension Claude Desktop", () => {
  const manifest = JSON.parse(ClaudeDesktopExtension.manifest()) as Record<string, unknown>;
  const server = manifest["server"] as Record<string, unknown>;
  check(manifest["name"] === "polymestre-files" && manifest["manifest_version"] === "0.4"
    && server?.["type"] === "node" && server?.["entry_point"] === "server/index.js",
  "extension : manifeste (nom, version, point d'entrée Node)");
  const files = ClaudeDesktopExtension.files("com.exemple.app");
  const fileNames = Object.keys(files);
  check(fileNames.length === 2 && fileNames.includes("manifest.json") && fileNames.includes("server/index.js"),
    "extension : deux fichiers, manifeste et pont");
  const script = files["server/index.js"];
  check(script.includes("com.exemple.app") && !script.includes("__APP_ID__"), "extension : l'identifiant de l'app est inscrit dans le pont");
  check(ClaudeDesktopExtension.infoFile("/h") === "/h/Library/Application Support/Polymestre/local-mcp.json",
    "extension : le pont lit l'adresse dans local-mcp.json");
  // Non porté : l'exécution réelle du pont par Node (processus, HTTP, stdio —
  // essai d'intégration de LocalMCPTests.swift qui sort du périmètre du domaine).
});
