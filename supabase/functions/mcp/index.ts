// Supabase Edge Function : le serveur MCP de StudyTrack.
//
// Un assistant (Claude, ChatGPT, tout client MCP) y lit l'état d'étude et y
// **demande** des modifications. Transport : MCP « Streamable HTTP », réponses
// JSON (pas de flux SSE : chaque outil répond en une fois).
//
//   https://<projet>.supabase.co/functions/v1/mcp/<jeton>        ← l'assistant
//   https://<projet>.supabase.co/functions/v1/mcp/<jeton>/sync   ← l'app
//
// Le **jeton** est un secret de 256 bits tiré par l'app (Profil › Assistant IA).
// Il est dans l'adresse parce que les connecteurs de Claude.ai et de ChatGPT
// n'acceptent qu'une adresse — pas d'en-tête. La base n'en garde que le
// SHA-256 : une fuite de la table ne donne accès à rien.
//
// Pourquoi l'app applique elle-même les modifications : les données vivent
// dans SwiftData, sur le téléphone. L'assistant dépose une commande ; l'app la
// récupère à sa prochaine synchronisation (ouverture, retour au premier plan,
// chaque enregistrement), l'applique avec les règles de l'interface, et renvoie
// le compte rendu. En attendant, l'instantané est mis à jour **tout de suite**
// pour que l'assistant lise ce qu'il vient d'écrire.
//
// Déploiement :
//   supabase db push                       # tables assistant_links / assistant_commands
//   supabase functions deploy mcp --no-verify-jwt
// (`--no-verify-jwt` : l'accès se fait par le jeton de l'adresse, pas par un
// JWT Supabase. SUPABASE_URL et SUPABASE_SERVICE_ROLE_KEY sont fournis par
// la plateforme.)

declare const Deno: {
  env: { get(key: string): string | undefined };
  serve(handler: (request: Request) => Response | Promise<Response>): void;
};

const SERVER_INFO = { name: "studytrack", title: "StudyTrack", version: "2.0.0" };
const PROTOCOLS = ["2025-06-18", "2025-03-26", "2024-11-05"];
const MAX_BODY = 4 * 1024 * 1024;

const INSTRUCTIONS = `StudyTrack suit les études d'un·e étudiant·e de l'EPFL : cours, séries d'exercices (avec sous-questions, sureté, correction), théorie (vidéos, sections de polycopié), évaluations et temps de travail.

- Commence par get_overview. Pour agir sur un exercice précis, lis d'abord get_course : il donne les identifiants (id) à passer aux outils d'écriture.
- Les outils d'écriture sont appliqués par l'app à sa prochaine ouverture ; la lecture reflète le changement immédiatement. list_pending_changes dit ce qui attend et ce qui a échoué.
- Étapes d'un exercice : à faire → en cours (questions) → fait (sureté à donner) → à corriger → corrigé (juste / moyen / faux) ; « à refaire » prime.
- Sois honnête dans ce que tu enregistres : une sureté ou une correction se demande à l'étudiant·e, elle ne s'invente pas.`;

// ─────────────────────────────────────────────────────────────── Base ────

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

async function db(path: string, init: RequestInit = {}): Promise<any> {
  const response = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    ...init,
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      "Content-Type": "application/json",
      Prefer: "return=representation",
      ...(init.headers ?? {}),
    },
  });
  const text = await response.text();
  if (!response.ok) throw new Error(`base : ${response.status} ${text.slice(0, 200)}`);
  return text ? JSON.parse(text) : null;
}

interface Link {
  token_hash: string;
  snapshot: any;
  snapshot_at: string | null;
}

interface Command {
  id: string;
  kind: string;
  payload: Record<string, unknown>;
  status: string;
  result: string | null;
  summary: string | null;
  created_at: string;
  applied_at: string | null;
}

async function getLink(hash: string): Promise<Link | null> {
  const rows = await db(`assistant_links?token_hash=eq.${hash}&select=token_hash,snapshot,snapshot_at`);
  return rows?.[0] ?? null;
}

async function saveSnapshot(hash: string, snapshot: unknown, touchTime = true): Promise<void> {
  const row: Record<string, unknown> = { token_hash: hash, snapshot, last_used_at: new Date().toISOString() };
  if (touchTime) row.snapshot_at = new Date().toISOString();
  await db("assistant_links?on_conflict=token_hash", {
    method: "POST",
    headers: { Prefer: "resolution=merge-duplicates,return=minimal" },
    body: JSON.stringify(row),
  });
}

async function sha256(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

// ─────────────────────────────────────────────────────────── Outils ────

const course = { type: "string", description: "Code du cours (ex. MATH-101) ou son nom" };
const exerciseTarget = {
  exercise_id: { type: "string", description: "Identifiant de l'exercice (get_course)" },
  course,
  exercise: { type: "string", description: "Numéro de l'exercice (ex. 3.4), avec course" },
};

const TOOLS = [
  {
    name: "get_overview",
    title: "Vue d'ensemble",
    description: "Où en est l'étudiant·e : semaine du semestre, avancement par cours, ce qu'il reste à faire en priorité, prochaines évaluations, temps de travail des 7 derniers jours. À appeler en premier.",
    inputSchema: { type: "object", properties: {} },
    annotations: { readOnlyHint: true },
  },
  {
    name: "list_courses",
    title: "Cours suivis",
    description: "Les cours suivis : crédits, semaine actuelle, avancement en exercices, corrections et théorie.",
    inputSchema: { type: "object", properties: { course } },
    annotations: { readOnlyHint: true },
  },
  {
    name: "get_course",
    title: "Détail d'un cours",
    description: "Tout un cours : séries et exercices (id, étape, sureté, correction, remarque, questions), théorie (id, semaine, vu, résumé), évaluations, temps passé par exercice. Donne les identifiants nécessaires aux outils d'écriture.",
    inputSchema: {
      type: "object",
      properties: { course, series: { type: "number", description: "Limiter à une série" } },
      required: ["course"],
    },
    annotations: { readOnlyHint: true },
  },
  {
    name: "what_to_do",
    title: "À faire",
    description: "Ce qui reste, par urgence : séries en retard, exercices à refaire, à juger, à corriger, théorie à voir ou à résumer.",
    inputSchema: {
      type: "object",
      properties: { course, limit: { type: "number", description: "Nombre maximal (20 par défaut)" } },
    },
    annotations: { readOnlyHint: true },
  },
  {
    name: "search",
    title: "Chercher",
    description: "Cherche dans les cours, exercices (titre, énoncé, remarque de correction) et la théorie (titre, résumé).",
    inputSchema: { type: "object", properties: { query: { type: "string" } }, required: ["query"] },
    annotations: { readOnlyHint: true },
  },
  {
    name: "upcoming_dates",
    title: "Échéances",
    description: "Évaluations des cours et dates du calendrier académique EPFL à venir.",
    inputSchema: { type: "object", properties: { days: { type: "number", description: "Horizon en jours (120 par défaut)" } } },
    annotations: { readOnlyHint: true },
  },
  {
    name: "study_time",
    title: "Temps de travail",
    description: "Temps de travail par cours, par type et par jour sur les N derniers jours.",
    inputSchema: { type: "object", properties: { days: { type: "number" }, course } },
    annotations: { readOnlyHint: true },
  },
  {
    name: "list_pending_changes",
    title: "Modifications en attente",
    description: "Les modifications demandées par un assistant : en attente d'application par l'app, appliquées, ou échouées (avec la raison).",
    inputSchema: { type: "object", properties: {} },
    annotations: { readOnlyHint: true },
  },
  {
    name: "update_exercise",
    title: "Mettre à jour un exercice",
    description: "Marque un exercice fait / à faire, enregistre la sureté de l'étudiant·e, le résultat de la correction, « à refaire », ou une remarque. Donner une sureté ou une correction marque l'exercice fait. « wrong » le marque à refaire.",
    inputSchema: {
      type: "object",
      properties: {
        ...exerciseTarget,
        done: { type: "boolean" },
        confidence: { type: "string", enum: ["sure", "medium", "unsure"] },
        correctness: { type: "string", enum: ["correct", "partial", "wrong"] },
        redo: { type: "boolean" },
        note: { type: "string", description: "Remarque de correction (ce qu'il faut retenir)" },
      },
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true },
  },
  {
    name: "check_questions",
    title: "Cocher des questions",
    description: "Coche (ou décoche) des sous-questions d'un exercice, par étiquette (« a », « 1.b ») ; sans liste, toutes. L'exercice est fait quand toutes le sont.",
    inputSchema: {
      type: "object",
      properties: {
        ...exerciseTarget,
        questions: { type: "array", items: { type: "string" } },
        done: { type: "boolean", description: "false pour décocher (true par défaut)" },
      },
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true },
  },
  {
    name: "update_theory",
    title: "Mettre à jour la théorie",
    description: "Marque un élément de théorie vu / pas vu, ou enregistre son résumé (ce qui le marque vu).",
    inputSchema: {
      type: "object",
      properties: {
        theory_id: { type: "string" },
        course,
        theory: { type: "string", description: "Numéro (ex. 3.2), avec course" },
        watched: { type: "boolean" },
        summary: { type: "string" },
      },
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true },
  },
  {
    name: "log_study_session",
    title: "Enregistrer une session",
    description: "Ajoute une session de travail passée au journal (ex. « 45 min d'exercices sur MATH-101 hier soir »).",
    inputSchema: {
      type: "object",
      properties: {
        course,
        type: { type: "string", enum: ["theory", "exercise", "correction", "other"] },
        minutes: { type: "number" },
        started_at: { type: "string", description: "Début, ISO 8601 (par défaut : se termine maintenant)" },
        exercise: { type: "string", description: "Numéro d'exercice visé, facultatif" },
        theory: { type: "string", description: "Numéro de théorie visé, facultatif" },
        note: { type: "string" },
      },
      required: ["type", "minutes"],
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false },
  },
  {
    name: "add_series",
    title: "Ajouter une série",
    description: "Ajoute (ou complète) une série d'exercices, avec ses exercices et leurs sous-questions. N'efface jamais un exercice existant.",
    inputSchema: {
      type: "object",
      properties: {
        course,
        number: { type: "number" },
        week: { type: "number", description: "Semaine du semestre" },
        title: { type: "string" },
        exercises: {
          type: "array",
          items: {
            type: "object",
            properties: {
              number: { type: "string", description: "ex. 4.2" },
              title: { type: "string" },
              statement: { type: "string", description: "Ce que l'exercice demande, en une phrase" },
              bonus: { type: "boolean" },
              questions: { type: "array", items: { type: "string" }, description: "Étiquettes : a, b, c…" },
            },
            required: ["number"],
          },
        },
      },
      required: ["course", "number"],
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true },
  },
  {
    name: "add_exam",
    title: "Ajouter une évaluation",
    description: "Ajoute un midterm, un examen, un quiz ou un rendu à un cours.",
    inputSchema: {
      type: "object",
      properties: {
        course,
        title: { type: "string" },
        date: { type: "string", description: "ISO 8601 (date ou date et heure)" },
        kind: { type: "string", enum: ["midterm", "exam", "quiz", "project", "assignment", "other"] },
        location: { type: "string" },
      },
      required: ["course", "date"],
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false },
  },
];

// ─────────────────────────────────────────────────────── Lectures ────

const fold = (value: unknown) =>
  String(value ?? "").normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().trim();

const hours = (seconds: number) => `${Math.round((seconds / 3600) * 10) / 10} h`;
const daysAgo = (iso: string, days: number) => Date.now() - new Date(iso).getTime() <= days * 86400000;

function findCourse(data: any, query: unknown): any {
  const needle = fold(query);
  if (!needle) return null;
  const courses = data.courses ?? [];
  return courses.find((c: any) => c.id === query)
    ?? courses.find((c: any) => fold(c.code) === needle || fold(c.officialCode) === needle)
    ?? courses.find((c: any) => fold(c.name) === needle)
    ?? courses.find((c: any) => fold(c.officialCode).startsWith(needle) || fold(c.name).includes(needle))
    ?? null;
}

function allExercises(course: any): any[] {
  return (course.series ?? []).flatMap((s: any) => (s.exercises ?? []).map((e: any) => ({ ...e, seriesNumber: s.number })));
}

function exerciseSeconds(data: any): Record<string, number> {
  const totals: Record<string, number> = {};
  for (const s of data.sessions ?? []) {
    if (s.exerciseId) totals[s.exerciseId] = (totals[s.exerciseId] ?? 0) + s.durationSeconds;
  }
  return totals;
}

function courseProgress(c: any) {
  const exercises = allExercises(c).filter((e) => !e.bonus);
  const theory = c.theory ?? [];
  return {
    code: c.code,
    nom: c.name,
    credits: c.credits,
    semaine: c.currentWeek,
    exercices: `${exercises.filter((e) => e.done).length}/${exercises.length} faits, ${exercises.filter((e) => e.corrected).length} corrigés`,
    theorie: `${theory.filter((t: any) => t.watched).length}/${theory.length} vus`,
    aRefaire: exercises.filter((e) => e.redo).length,
  };
}

function whatToDo(data: any, args: any) {
  const filter = args.course ? findCourse(data, args.course) : null;
  const limit = Number.isFinite(args.limit) ? args.limit : 20;
  const items: any[] = [];
  const rank: Record<string, number> = { "série en retard": 0, "à refaire": 1, "sureté à donner": 2, "à corriger": 3, "série de la semaine": 4, "théorie à voir": 5, "à résumer": 6 };
  for (const c of data.courses ?? []) {
    if (filter && c.id !== filter.id) continue;
    const week = c.currentWeek || 1;
    for (const series of c.series ?? []) {
      const pending = (series.exercises ?? []).filter((e: any) => !e.done && !e.bonus);
      if (pending.length && series.plannedWeek <= week) {
        items.push({
          urgence: series.plannedWeek < week ? "série en retard" : "série de la semaine",
          cours: c.code, quoi: `Série ${series.number}`, reste: pending.map((e: any) => e.number).join(", "),
        });
      }
      for (const e of series.exercises ?? []) {
        if (e.redo) items.push({ urgence: "à refaire", cours: c.code, quoi: `Exercice ${e.number}`, id: e.id, note: e.correctionNote });
        else if (e.done && !e.confidence) items.push({ urgence: "sureté à donner", cours: c.code, quoi: `Exercice ${e.number}`, id: e.id });
        else if (e.done && !e.corrected) items.push({ urgence: "à corriger", cours: c.code, quoi: `Exercice ${e.number}`, id: e.id });
      }
    }
    for (const t of c.theory ?? []) {
      if (t.plannedWeek > week) continue;
      if (!t.watched) items.push({ urgence: "théorie à voir", cours: c.code, quoi: `${t.number} ${t.title}`, id: t.id, semaine: t.plannedWeek });
    }
  }
  items.sort((a, b) => (rank[a.urgence] ?? 9) - (rank[b.urgence] ?? 9));
  return { total: items.length, elements: items.slice(0, limit) };
}

function upcomingDates(data: any, args: any) {
  const horizon = Number.isFinite(args.days) ? args.days : 120;
  const now = Date.now();
  const limit = now + horizon * 86400000;
  const inWindow = (iso: string) => { const t = new Date(iso).getTime(); return t >= now - 86400000 && t <= limit; };
  return {
    evaluations: (data.courses ?? []).flatMap((c: any) => (c.exams ?? [])
      .filter((e: any) => inWindow(e.date))
      .map((e: any) => ({ date: e.date.slice(0, 16), cours: c.code, titre: e.title, nature: e.kind, lieu: e.location, poids: e.weightPercent })))
      .sort((a: any, b: any) => a.date.localeCompare(b.date)),
    calendrierEPFL: (data.calendar ?? []).filter((m: any) => inWindow(m.date))
      .map((m: any) => ({ date: m.date.slice(0, 10), titre: m.title, approximatif: m.approximate || undefined })),
  };
}

function studyTime(data: any, args: any) {
  const days = Number.isFinite(args.days) ? args.days : 7;
  const filter = args.course ? findCourse(data, args.course) : null;
  const byCourse: Record<string, number> = {};
  const byType: Record<string, number> = {};
  const byDay: Record<string, number> = {};
  for (const s of (data.sessions ?? []).filter((s: any) => daysAgo(s.startedAt, days))) {
    if (filter && s.course !== filter.code) continue;
    byCourse[s.course ?? "sans cours"] = (byCourse[s.course ?? "sans cours"] ?? 0) + s.durationSeconds;
    const type = s.source === "anki" ? "anki" : s.taskType;
    byType[type] = (byType[type] ?? 0) + s.durationSeconds;
    const day = s.startedAt.slice(0, 10);
    byDay[day] = (byDay[day] ?? 0) + s.durationSeconds;
  }
  const sorted = (o: Record<string, number>) => Object.entries(o).sort((a, b) => b[1] - a[1]);
  return {
    jours: days,
    total: hours(Object.values(byCourse).reduce((a, b) => a + b, 0)),
    parCours: sorted(byCourse).map(([k, v]) => ({ cours: k, temps: hours(v) })),
    parType: sorted(byType).map(([k, v]) => ({ type: k, temps: hours(v) })),
    parJour: Object.entries(byDay).sort().map(([k, v]) => ({ jour: k, temps: hours(v) })),
  };
}

function getCourse(data: any, args: any) {
  const c = findCourse(data, args.course);
  if (!c) throw new UserError(`Cours « ${args.course} » introuvable. Cours suivis : ${(data.courses ?? []).map((x: any) => x.code).join(", ")}.`);
  const seconds = exerciseSeconds(data);
  const series = (c.series ?? []).filter((s: any) => !Number.isFinite(args.series) || s.number === args.series);
  return {
    id: c.id, code: c.code, nom: c.name, credits: c.credits, semaine: c.currentWeek, enseignant: c.lecturer,
    series: series.map((s: any) => ({
      id: s.id, numero: s.number, titre: s.title, semaine: s.plannedWeek, terminee: s.complete,
      exercices: (s.exercises ?? []).map((e: any) => ({
        id: e.id, numero: e.number, titre: e.title || undefined, enonce: e.statement, etape: e.stage,
        bonus: e.bonus || undefined, surete: e.confidence, correction: e.correctness, remarque: e.correctionNote,
        questions: e.questions?.map((q: any) => `${q.done ? "☑" : "☐"} ${q.path}${q.text ? " " + q.text : ""}`),
        tempsPasse: seconds[e.id] ? hours(seconds[e.id]) : undefined,
      })),
    })),
    theorie: Number.isFinite(args.series) ? undefined : (c.theory ?? []).map((t: any) => ({
      id: t.id, numero: t.number, titre: t.title, semaine: t.plannedWeek, vu: t.watched, resume: t.summary,
    })),
    evaluations: (c.exams ?? []).map((e: any) => ({ id: e.id, titre: e.title, date: e.date, nature: e.kind, passee: e.past })),
  };
}

function search(data: any, args: any) {
  const needle = fold(args.query);
  if (!needle) throw new UserError("Requête vide.");
  const hits: any[] = [];
  for (const c of data.courses ?? []) {
    if (fold(`${c.code} ${c.name} ${c.lecturer ?? ""}`).includes(needle)) hits.push({ type: "cours", cours: c.code, texte: c.name });
    for (const e of allExercises(c)) {
      if (fold(`${e.number} ${e.title} ${e.statement ?? ""} ${e.correctionNote ?? ""}`).includes(needle)) {
        hits.push({ type: "exercice", cours: c.code, id: e.id, texte: `Exercice ${e.number}${e.title ? " — " + e.title : ""}`, etape: e.stage, remarque: e.correctionNote });
      }
    }
    for (const t of c.theory ?? []) {
      if (fold(`${t.number} ${t.title} ${t.summary ?? ""}`).includes(needle)) {
        hits.push({ type: "théorie", cours: c.code, id: t.id, texte: `${t.number} ${t.title}`, resume: t.summary });
      }
    }
  }
  return { requete: args.query, total: hits.length, resultats: hits.slice(0, 40) };
}

function overview(data: any, snapshotAt: string | null) {
  const week = (data.sessions ?? []).filter((s: any) => daysAgo(s.startedAt, 7));
  return {
    instantane: snapshotAt ? `synchronisé le ${snapshotAt.slice(0, 16).replace("T", " ")} (UTC)` : "jamais synchronisé",
    semaine: data.courses?.[0]?.currentWeek,
    tempsSur7Jours: hours(week.reduce((a: number, s: any) => a + s.durationSeconds, 0)),
    cours: (data.courses ?? []).map(courseProgress),
    priorites: whatToDo(data, { limit: 8 }).elements,
    prochainesEvaluations: upcomingDates(data, { days: 60 }).evaluations.slice(0, 5),
  };
}

// ─────────────────────────────────────────────────────── Écritures ────

class UserError extends Error {}

function resolveExercise(data: any, args: any): { course: any; exercise: any } {
  if (args.exercise_id) {
    for (const c of data.courses ?? []) {
      for (const s of c.series ?? []) {
        const e = (s.exercises ?? []).find((x: any) => x.id === args.exercise_id);
        if (e) return { course: c, exercise: e };
      }
    }
    throw new UserError("Exercice introuvable : appelle get_course pour les identifiants.");
  }
  const c = findCourse(data, args.course);
  if (!c) throw new UserError(`Cours « ${args.course ?? ""} » introuvable.`);
  const number = String(args.exercise ?? "").replace(/^exercice\s*/i, "").trim();
  for (const s of c.series ?? []) {
    const e = (s.exercises ?? []).find((x: any) => x.number === number);
    if (e) return { course: c, exercise: e };
  }
  throw new UserError(`Exercice « ${number} » introuvable dans ${c.code}.`);
}

function resolveTheory(data: any, args: any): { course: any; item: any } {
  if (args.theory_id) {
    for (const c of data.courses ?? []) {
      const t = (c.theory ?? []).find((x: any) => x.id === args.theory_id);
      if (t) return { course: c, item: t };
    }
    throw new UserError("Élément de théorie introuvable.");
  }
  const c = findCourse(data, args.course);
  if (!c) throw new UserError(`Cours « ${args.course ?? ""} » introuvable.`);
  const t = (c.theory ?? []).find((x: any) => x.number === String(args.theory ?? "").trim());
  if (!t) throw new UserError(`Théorie « ${args.theory ?? ""} » introuvable dans ${c.code}.`);
  return { course: c, item: t };
}

/// Recalcule l'étape affichée d'un exercice modifié dans l'instantané.
function restage(e: any) {
  if (e.redo) e.stage = "à refaire";
  else if (e.corrected && e.correctness) e.stage = ({ correct: "juste", partial: "moyen", wrong: "faux" } as any)[e.correctness];
  else if (e.done) e.stage = e.confidence ? "à corriger" : "sureté ?";
  else {
    const done = (e.questions ?? []).filter((q: any) => q.done).length;
    e.stage = done ? `${done}/${e.questions.length}` : "à faire";
  }
}

const CONFIDENCE: Record<string, string> = { sure: "green", medium: "orange", unsure: "red" };

/// Valide, traduit en commande pour l'app, et met l'instantané à jour.
function prepareWrite(name: string, args: any, data: any): { kind: string; payload: Record<string, unknown>; summary: string } {
  switch (name) {
    case "update_exercise": {
      const { course: c, exercise: e } = resolveExercise(data, args);
      if (args.confidence && !CONFIDENCE[args.confidence]) throw new UserError("confidence : sure, medium ou unsure.");
      if (args.correctness && !["correct", "partial", "wrong"].includes(args.correctness)) throw new UserError("correctness : correct, partial ou wrong.");
      const payload: Record<string, unknown> = { exerciseId: e.id, courseId: c.id };
      for (const key of ["done", "confidence", "correctness", "redo", "note"]) if (args[key] !== undefined) payload[key] = args[key];
      if (Object.keys(payload).length === 2) throw new UserError("Rien à modifier : done, confidence, correctness, redo ou note.");
      if (args.done !== undefined) {
        e.done = !!args.done;
        (e.questions ?? []).forEach((q: any) => (q.done = e.done));
        if (!e.done) delete e.confidence;
      }
      if (args.confidence) { e.done = true; e.confidence = CONFIDENCE[args.confidence]; }
      if (args.correctness) { e.done = true; e.corrected = true; e.correctness = args.correctness; if (args.correctness === "wrong") e.redo = true; if (args.correctness === "correct") e.redo = false; }
      if (args.redo !== undefined) e.redo = !!args.redo;
      if (args.note !== undefined) e.correctionNote = args.note;
      restage(e);
      return { kind: "update_exercise", payload, summary: `${c.code} ${e.number} → ${e.stage}` };
    }
    case "check_questions": {
      const { course: c, exercise: e } = resolveExercise(data, args);
      const done = args.done !== false;
      const wanted = new Set((args.questions ?? []).map((q: string) => fold(q).replace(/[().: ]/g, "")));
      const questions = e.questions ?? [];
      const targets = wanted.size ? questions.filter((q: any) => wanted.has(fold(q.path).replace(/[().: ]/g, "")) || wanted.has(fold(q.path.split(".").pop()))) : questions;
      if (questions.length && !targets.length) throw new UserError(`Questions de ${e.number} : ${questions.map((q: any) => q.path).join(", ")}.`);
      targets.forEach((q: any) => (q.done = done));
      if (questions.length) e.done = questions.every((q: any) => q.done); else e.done = done;
      restage(e);
      return { kind: "check_questions", payload: { exerciseId: e.id, courseId: c.id, questions: args.questions ?? [], done }, summary: `${c.code} ${e.number} → ${e.stage}` };
    }
    case "update_theory": {
      const { course: c, item: t } = resolveTheory(data, args);
      const payload: Record<string, unknown> = { theoryId: t.id, courseId: c.id };
      if (args.watched !== undefined) { payload.watched = !!args.watched; t.watched = !!args.watched; }
      if (args.summary !== undefined) { payload.summary = String(args.summary); t.summary = args.summary; t.summarized = !!args.summary; if (args.summary) t.watched = true; }
      if (Object.keys(payload).length === 2) throw new UserError("Rien à modifier : watched ou summary.");
      return { kind: "update_theory", payload, summary: `${c.code} ${t.number} → ${t.watched ? "vu" : "pas vu"}` };
    }
    case "log_study_session": {
      const minutes = Number(args.minutes);
      if (!(minutes > 0 && minutes <= 960)) throw new UserError("minutes : entre 1 et 960.");
      const c = args.course ? findCourse(data, args.course) : null;
      if (args.course && !c) throw new UserError(`Cours « ${args.course} » introuvable.`);
      const payload: Record<string, unknown> = { type: args.type ?? "other", minutes };
      if (c) { payload.courseId = c.id; payload.course = c.code; }
      if (args.started_at) { if (isNaN(Date.parse(args.started_at))) throw new UserError("started_at : ISO 8601."); payload.startedAt = new Date(args.started_at).toISOString(); }
      if (args.exercise) payload.exercise = String(args.exercise);
      if (args.theory) payload.theory = String(args.theory);
      if (args.note) payload.note = String(args.note);
      data.sessions = [{ taskType: payload.type, startedAt: payload.startedAt ?? new Date(Date.now() - minutes * 60000).toISOString(), durationSeconds: Math.round(minutes * 60), course: c?.code, manual: true }, ...(data.sessions ?? [])];
      return { kind: "log_session", payload, summary: `${Math.round(minutes)} min${c ? " sur " + c.code : ""}` };
    }
    case "add_series": {
      const c = findCourse(data, args.course);
      if (!c) throw new UserError(`Cours « ${args.course ?? ""} » introuvable.`);
      const number = Number(args.number);
      if (!(number > 0)) throw new UserError("number : numéro de série.");
      const exercises = (args.exercises ?? []).map((x: any) => ({
        number: String(x.number), title: x.title, statement: x.statement, bonus: !!x.bonus,
        questions: (x.questions ?? []).map(String),
      }));
      const existing = (c.series ?? []).find((s: any) => s.number === number);
      if (!existing) {
        c.series = [...(c.series ?? []), {
          id: `en-attente-${crypto.randomUUID()}`, number, title: args.title ?? `Série ${number}`, plannedWeek: args.week ?? c.currentWeek, complete: false,
          exercises: exercises.map((x: any) => ({ id: `en-attente-${crypto.randomUUID()}`, number: x.number, title: x.title ?? "", statement: x.statement, bonus: x.bonus, done: false, corrected: false, redo: false, stage: "à faire", questions: x.questions.map((q: string) => ({ path: q, label: q, text: "", done: false })) })),
        }];
      }
      return {
        kind: "add_series",
        payload: { courseId: c.id, number, week: args.week, title: args.title, exercises },
        summary: `${c.code} série ${number} (${exercises.length} exercices)`,
      };
    }
    case "add_exam": {
      const c = findCourse(data, args.course);
      if (!c) throw new UserError(`Cours « ${args.course ?? ""} » introuvable.`);
      if (isNaN(Date.parse(args.date))) throw new UserError("date : ISO 8601.");
      const date = String(args.date);
      c.exams = [...(c.exams ?? []), { id: "en-attente", title: args.title ?? args.kind ?? "Examen", date, kind: args.kind ?? "exam", location: args.location, past: false }];
      return {
        kind: "add_exam",
        payload: { courseId: c.id, title: args.title, date, examKind: args.kind, location: args.location },
        summary: `${c.code} ${args.title ?? args.kind ?? "examen"} le ${date.slice(0, 10)}`,
      };
    }
  }
  throw new UserError(`Outil inconnu : ${name}`);
}

// ───────────────────────────────────────────────────────── MCP ────

function textResult(value: unknown, isError = false) {
  const text = typeof value === "string" ? value : JSON.stringify(value, (_, v) => (v === null ? undefined : v), 2);
  return { content: [{ type: "text", text }], ...(isError ? { isError: true } : {}) };
}

async function callTool(hash: string, name: string, args: any): Promise<unknown> {
  const link = await getLink(hash);
  if (name === "list_pending_changes") {
    const rows: Command[] = await db(`assistant_commands?token_hash=eq.${hash}&select=id,kind,status,result,summary,created_at,applied_at&order=created_at.desc&limit=30`);
    return textResult({
      enAttente: rows.filter((r) => r.status === "pending").map((r) => ({ quoi: r.summary ?? r.kind, depuis: r.created_at })),
      recentes: rows.filter((r) => r.status !== "pending").slice(0, 15).map((r) => ({ quoi: r.summary ?? r.kind, statut: r.status === "applied" ? "appliqué" : "échoué", detail: r.result, le: r.applied_at })),
    });
  }
  if (!link?.snapshot) {
    return textResult("Aucune donnée pour l'instant : ouvre StudyTrack sur le téléphone (Profil › Assistant IA) pour synchroniser, puis réessaie.", true);
  }
  const data = link.snapshot;
  try {
    switch (name) {
      case "get_overview": return textResult(overview(data, link.snapshot_at));
      case "list_courses": {
        const filter = args.course ? findCourse(data, args.course) : null;
        return textResult((data.courses ?? []).filter((c: any) => !filter || c.id === filter.id).map(courseProgress));
      }
      case "get_course": return textResult(getCourse(data, args));
      case "what_to_do": return textResult(whatToDo(data, args));
      case "search": return textResult(search(data, args));
      case "upcoming_dates": return textResult(upcomingDates(data, args));
      case "study_time": return textResult(studyTime(data, args));
    }
    const write = prepareWrite(name, args, data);
    await db("assistant_commands", {
      method: "POST",
      headers: { Prefer: "return=minimal" },
      body: JSON.stringify({ token_hash: hash, kind: write.kind, payload: write.payload, summary: write.summary }),
    });
    await saveSnapshot(hash, data, false);
    return textResult(`Enregistré : ${write.summary}. StudyTrack l'appliquera à sa prochaine ouverture (généralement dans la minute si l'app est ouverte) ; la lecture en tient déjà compte.`);
  } catch (error) {
    if (error instanceof UserError) return textResult(error.message, true);
    throw error;
  }
}

async function handleRPC(hash: string, message: any): Promise<unknown | null> {
  const { id, method, params } = message ?? {};
  const reply = (result: unknown) => ({ jsonrpc: "2.0", id, result });
  const fail = (code: number, text: string) => ({ jsonrpc: "2.0", id: id ?? null, error: { code, message: text } });
  if (id === undefined || id === null) return null; // notification
  switch (method) {
    case "initialize": {
      const asked = params?.protocolVersion;
      return reply({
        protocolVersion: PROTOCOLS.includes(asked) ? asked : PROTOCOLS[0],
        capabilities: { tools: { listChanged: false } },
        serverInfo: SERVER_INFO,
        instructions: INSTRUCTIONS,
      });
    }
    case "ping": return reply({});
    case "tools/list": return reply({ tools: TOOLS });
    case "resources/list": return reply({ resources: [] });
    case "prompts/list": return reply({ prompts: [] });
    case "tools/call": {
      const name = params?.name;
      if (!TOOLS.some((t) => t.name === name)) return fail(-32602, `Outil inconnu : ${name}`);
      try {
        return reply(await callTool(hash, name, params?.arguments ?? {}));
      } catch (error) {
        return reply(textResult(`Erreur du serveur : ${(error as Error).message}`, true));
      }
    }
    default: return fail(-32601, `Méthode inconnue : ${method}`);
  }
}

// ──────────────────────────────────────────────────── Synchronisation ────

/// L'app envoie son instantané et ses comptes rendus, reçoit les commandes.
async function sync(hash: string, body: any): Promise<Response> {
  if (body?.snapshot) {
    if (body.snapshot.format !== "studytrack.assistant") return json({ error: "instantané invalide" }, 400);
    await saveSnapshot(hash, body.snapshot);
  }
  for (const result of body?.results ?? []) {
    if (typeof result?.id !== "string" || !/^[0-9a-f-]{36}$/.test(result.id)) continue;
    await db(`assistant_commands?id=eq.${result.id}&token_hash=eq.${hash}`, {
      method: "PATCH",
      headers: { Prefer: "return=minimal" },
      body: JSON.stringify({
        status: result.status === "applied" ? "applied" : "failed",
        result: String(result.message ?? "").slice(0, 500),
        applied_at: new Date().toISOString(),
      }),
    });
  }
  const pending: Command[] = await db(`assistant_commands?token_hash=eq.${hash}&status=eq.pending&select=id,kind,payload&order=created_at.asc&limit=100`);
  return json({ commands: pending.map((c) => ({ id: c.id, kind: c.kind, payload: c.payload })) });
}

// ───────────────────────────────────────────────────────── HTTP ────

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, content-type, mcp-protocol-version, mcp-session-id, apikey, x-client-info",
};

function json(value: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(value), { status, headers: { ...CORS, "Content-Type": "application/json", ...extra } });
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  const url = new URL(request.url);
  const parts = url.pathname.split("/").filter(Boolean);
  const at = parts.lastIndexOf("mcp");
  const rest = at >= 0 ? parts.slice(at + 1) : parts;
  const bearer = request.headers.get("authorization")?.replace(/^Bearer\s+/i, "") ?? "";
  const token = rest[0] ?? bearer;
  const action = rest[1] ?? "";

  if (!/^[A-Za-z0-9_-]{32,128}$/.test(token)) {
    return json({ error: "Adresse incomplète : copie l'adresse complète depuis StudyTrack (Profil › Assistant IA)." }, 401);
  }
  const hash = await sha256(token);

  try {
    if (action === "sync" && request.method === "POST") {
      const text = await request.text();
      if (text.length > MAX_BODY) return json({ error: "instantané trop volumineux" }, 413);
      return await sync(hash, JSON.parse(text || "{}"));
    }
    if (!action && request.method === "DELETE") {
      // Déconnecter l'assistant efface tout ce que le serveur gardait.
      await db(`assistant_links?token_hash=eq.${hash}`, { method: "DELETE", headers: { Prefer: "return=minimal" } });
      return new Response(null, { status: 204, headers: CORS });
    }
    if (!action && request.method === "GET") {
      // Pas de flux SSE : chaque réponse arrive dans la réponse HTTP.
      return json({ error: "Ce serveur MCP répond en POST (Streamable HTTP)." }, 405, { Allow: "POST, DELETE" });
    }
    if (!action && request.method === "POST") {
      const text = await request.text();
      if (text.length > MAX_BODY) return json({ error: "requête trop volumineuse" }, 413);
      let message: any;
      try { message = JSON.parse(text); } catch { return json({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "JSON illisible" } }, 400); }
      if (Array.isArray(message)) {
        const replies = (await Promise.all(message.map((m) => handleRPC(hash, m)))).filter(Boolean);
        return replies.length ? json(replies) : new Response(null, { status: 202, headers: CORS });
      }
      const reply = await handleRPC(hash, message);
      return reply ? json(reply) : new Response(null, { status: 202, headers: CORS });
    }
    return json({ error: "introuvable" }, 404);
  } catch (error) {
    return json({ error: (error as Error).message }, 500);
  }
});
