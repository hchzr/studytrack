#!/usr/bin/env node
//
// Serveur MCP local pour StudyTrack.
//
// Expose l'instantané exporté par l'app (Profil › Données › « Exporter pour un
// assistant ») à un assistant — Claude Desktop, Claude Code, ou tout client MCP.
//
// Aucune dépendance : le protocole MCP sur `stdio` est du JSON-RPC 2.0 délimité
// par des retours à la ligne, et tout ce dont ce serveur a besoin tient dans la
// bibliothèque standard de Node. Un `npm install` pour lire un fichier JSON serait
// disproportionné.
//
//   node mcp/server.js
//   STUDYTRACK_EXPORT=/chemin/vers/studytrack-assistant.json node mcp/server.js
//
// Les outils sont en **lecture seule** : un assistant peut consulter, pas agir.
// Écrire dans les données d'étude d'un utilisateur depuis un modèle de langage
// demanderait une relecture humaine que ce serveur n'a pas les moyens d'offrir.

const fs = require("fs");
const os = require("os");
const path = require("path");
const readline = require("readline");

const PROTOCOL_VERSION = "2024-11-05";
const SERVER_INFO = { name: "studytrack", version: "1.0.0" };

const EXPORT_PATH =
  process.env.STUDYTRACK_EXPORT ||
  path.join(os.homedir(), ".studytrack", "studytrack-assistant.json");

// ─────────────────────────────────────────────────────────────── Données ────

function loadSnapshot() {
  if (!fs.existsSync(EXPORT_PATH)) {
    throw new Error(
      `Aucun instantané à ${EXPORT_PATH}. Dans l'app : Profil › Données › « Exporter pour un assistant », ` +
        `puis enregistre le fichier à cet emplacement (ou règle STUDYTRACK_EXPORT).`
    );
  }
  const raw = fs.readFileSync(EXPORT_PATH, "utf8");
  const data = JSON.parse(raw);
  if (data.format !== "studytrack.assistant") {
    throw new Error(
      `Ce fichier n'est pas un instantané StudyTrack (format « ${data.format} »).`
    );
  }
  return data;
}

function daysAgo(iso, days) {
  const limit = new Date();
  limit.setDate(limit.getDate() - days);
  return new Date(iso) >= limit;
}

function startOfWeek() {
  // Lundi, comme le semestre EPFL.
  const now = new Date();
  const day = (now.getDay() + 6) % 7;
  const monday = new Date(now.getFullYear(), now.getMonth(), now.getDate() - day);
  return monday;
}

function hours(seconds) {
  const value = Math.round((seconds / 3600) * 10) / 10;
  return `${value} h`;
}

// ──────────────────────────────────────────────────────────────── Outils ────

const TOOLS = [
  {
    name: "study_overview",
    description:
      "Vue d'ensemble : temps travaillé sur 7 jours et 30 jours, répartition par cours et par type de travail, série de jours actifs.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "list_courses",
    description:
      "Les cours suivis, avec leurs crédits, leur avancement en théorie et en exercices, et le nombre d'évaluations.",
    inputSchema: {
      type: "object",
      properties: {
        course: { type: "string", description: "Filtre sur un code de cours (ex : CS-250)" },
      },
    },
  },
  {
    name: "what_to_do",
    description:
      "Ce qu'il reste à faire maintenant : séries de la semaine non terminées, exercices faits non corrigés, exercices à refaire, théorie non vue ou non résumée.",
    inputSchema: {
      type: "object",
      properties: {
        course: { type: "string", description: "Limiter à un cours" },
        limit: { type: "number", description: "Nombre maximal d'éléments (20 par défaut)" },
      },
    },
  },
  {
    name: "coverage",
    description:
      "Ce qui échappe au suivi : cours sans contenu, séries sans exercice, séries en retard, théorie sans durée, cours sans évaluation, horaire ou semestre manquant.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "search",
    description:
      "Cherche un mot dans les cours, les séries, les exercices (titre et note de correction) et la théorie (titre et résumé).",
    inputSchema: {
      type: "object",
      properties: { query: { type: "string", description: "Le ou les mots à chercher" } },
      required: ["query"],
    },
  },
  {
    name: "upcoming_dates",
    description:
      "Les prochaines échéances du calendrier académique de l'EPFL et les évaluations des cours.",
    inputSchema: {
      type: "object",
      properties: { days: { type: "number", description: "Horizon en jours (120 par défaut)" } },
    },
  },
  {
    name: "study_time",
    description:
      "Temps de travail par cours et par type sur les N derniers jours (7 par défaut).",
    inputSchema: {
      type: "object",
      properties: { days: { type: "number", description: "Fenêtre en jours" } },
    },
  },
];

function unwrap(args) {
  // Un client MCP peut envoyer les arguments directement ou sous une clé.
  if (args && typeof args === "object" && !Array.isArray(args)) return args;
  return {};
}

function text(value) {
  return { content: [{ type: "text", text: typeof value === "string" ? value : JSON.stringify(value, null, 2) }] };
}

function studyOverview(data) {
  const sessions = data.sessions || [];
  const week = sessions.filter((s) => daysAgo(s.startedAt, 7));
  const month = sessions.filter((s) => daysAgo(s.startedAt, 30));

  const byCourse = {};
  const byType = {};
  for (const session of week) {
    const course = session.course || "sans cours";
    byCourse[course] = (byCourse[course] || 0) + session.durationSeconds;
    byType[session.taskType] = (byType[session.taskType] || 0) + session.durationSeconds;
  }

  const days = new Set(sessions.map((s) => s.startedAt.slice(0, 10)));
  let streak = 0;
  const cursor = new Date();
  for (;;) {
    const key = cursor.toISOString().slice(0, 10);
    if (!days.has(key)) break;
    streak += 1;
    cursor.setDate(cursor.getDate() - 1);
  }

  return {
    tempsCetteSemaine: hours(week.reduce((sum, s) => sum + s.durationSeconds, 0)),
    temps30Jours: hours(month.reduce((sum, s) => sum + s.durationSeconds, 0)),
    joursActifsDaffilee: streak,
    parCours: Object.entries(byCourse)
      .sort((a, b) => b[1] - a[1])
      .map(([course, seconds]) => ({ course, temps: hours(seconds) })),
    parTypeDeTravail: Object.entries(byType)
      .sort((a, b) => b[1] - a[1])
      .map(([type, seconds]) => ({ type, temps: hours(seconds) })),
  };
}

function listCourses(data, args) {
  const filter = (args.course || "").toLowerCase();
  return (data.courses || [])
    .filter((c) => !filter || c.code.toLowerCase().includes(filter))
    .map((c) => {
      const exercises = (c.series || []).flatMap((s) => s.exercises || []);
      const done = exercises.filter((e) => e.done).length;
      const corrected = exercises.filter((e) => e.corrected).length;
      const theory = c.theory || [];
      const watched = theory.filter((t) => t.watched).length;
      const summarized = theory.filter((t) => t.summarized).length;
      return {
        code: c.code,
        nom: c.name,
        credits: c.credits,
        semaineActuelle: c.currentWeek,
        exercices: `${done}/${exercises.length} faits, ${corrected} corrigés`,
        theorie: `${watched}/${theory.length} vus, ${summarized} résumés`,
        series: (c.series || []).length,
        evaluations: (c.exams || []).length,
      };
    });
}

function whatToDo(data, args) {
  const filter = (args.course || "").toLowerCase();
  const limit = Number.isFinite(args.limit) ? args.limit : 20;
  const items = [];

  for (const course of data.courses || []) {
    if (filter && !course.code.toLowerCase().includes(filter)) continue;
    const week = course.currentWeek || 1;

    for (const series of course.series || []) {
      const pending = (series.exercises || []).filter((e) => !e.done);
      if (series.plannedWeek < week && pending.length > 0) {
        items.push({
          urgence: "en retard",
          cours: course.code,
          quoi: `Série ${series.number} (semaine ${series.plannedWeek})`,
          reste: pending.map((e) => e.number).join(", "),
        });
      }
    }
    for (const exercise of (course.series || []).flatMap((s) => s.exercises || [])) {
      if (exercise.done && !exercise.corrected) {
        items.push({ urgence: "à corriger", cours: course.code, quoi: `Exercice ${exercise.number}` });
      }
      if (exercise.redo) {
        items.push({ urgence: "à refaire", cours: course.code, quoi: `Exercice ${exercise.number}` });
      }
    }
    for (const item of course.theory || []) {
      if (!item.watched) {
        items.push({ urgence: "à voir", cours: course.code, quoi: `Vidéo ${item.number} ${item.title}` });
      } else if (!item.summarized) {
        items.push({ urgence: "à résumer", cours: course.code, quoi: `${item.number} ${item.title}` });
      }
    }
  }
  return { total: items.length, elements: items.slice(0, limit) };
}

function coverage(data) {
  const findings = [];
  if (!data.courses || data.courses.length === 0) {
    findings.push({ gravite: "bloquant", quoi: "Aucun cours suivi" });
  }
  for (const course of data.courses || []) {
    const exercises = (course.series || []).flatMap((s) => s.exercises || []);
    if ((course.series || []).length === 0 && (course.theory || []).length === 0) {
      findings.push({ gravite: "bloquant", cours: course.code, quoi: "Cours vide : ni série ni théorie" });
    }
    for (const series of course.series || []) {
      if ((series.exercises || []).length === 0) {
        findings.push({ gravite: "incomplet", cours: course.code, quoi: `Série ${series.number} sans exercice` });
      }
    }
    const week = course.currentWeek || 1;
    for (const series of course.series || []) {
      if (series.plannedWeek < week && !series.complete && (series.exercises || []).length > 0) {
        findings.push({ gravite: "incomplet", cours: course.code, quoi: `Série ${series.number} en retard` });
      }
    }
    const uncorrected = exercises.filter((e) => e.done && !e.corrected).length;
    if (uncorrected > 0) {
      findings.push({ gravite: "incomplet", cours: course.code, quoi: `${uncorrected} exercice(s) fait(s) non corrigé(s)` });
    }
    if ((course.exams || []).length === 0) {
      findings.push({ gravite: "incomplet", cours: course.code, quoi: "Aucune évaluation enregistrée" });
    }
    const noDuration = (course.theory || []).filter((t) => t.kind === "video" && !t.durationSeconds).length;
    if (noDuration > 0) {
      findings.push({ gravite: "suggestion", cours: course.code, quoi: `${noDuration} vidéo(s) sans durée` });
    }
  }
  return { total: findings.length, constats: findings };
}

function search(data, args) {
  const query = (args.query || "").trim();
  if (!query) return { erreur: "Requête vide." };

  const normalize = (value) =>
    (value || "")
      .normalize("NFD")
      .replace(/[\u0300-\u036f]/g, "")
      .toLowerCase();

  const needle = normalize(query);
  const hits = [];

  for (const course of data.courses || []) {
    if (normalize(`${course.code} ${course.name} ${course.lecturer || ""}`).includes(needle)) {
      hits.push({ type: "cours", code: course.code, texte: course.name });
    }
    for (const series of course.series || []) {
      for (const exercise of series.exercises || []) {
        const haystack = normalize(`${exercise.number} ${exercise.title} ${exercise.correctionNote || ""}`);
        if (haystack.includes(needle)) {
          hits.push({
            type: "exercice",
            cours: course.code,
            texte: `Exercice ${exercise.number}${exercise.title ? " — " + exercise.title : ""}`,
            note: exercise.correctionNote || undefined,
          });
        }
      }
    }
    for (const item of course.theory || []) {
      const haystack = normalize(`${item.number} ${item.title} ${item.summary || ""}`);
      if (haystack.includes(needle)) {
        hits.push({
          type: "théorie",
          cours: course.code,
          texte: `${item.number} ${item.title}`,
          resume: item.summary || undefined,
        });
      }
    }
  }
  return { requete: query, total: hits.length, resultats: hits.slice(0, 40) };
}

function upcomingDates(data, args) {
  const horizon = Number.isFinite(args.days) ? args.days : 120;
  const limit = new Date();
  limit.setDate(limit.getDate() + horizon);
  const now = new Date();

  const calendar = (data.calendar || [])
    .filter((m) => {
      const date = new Date(m.date);
      return date >= now && date <= limit;
    })
    .map((m) => ({ date: m.date.slice(0, 10), titre: m.title, nature: m.kind, approximatif: m.approximate }));

  const exams = [];
  for (const course of data.courses || []) {
    for (const exam of course.exams || []) {
      const date = new Date(exam.date);
      if (date >= now && date <= limit) {
        exams.push({ date: exam.date.slice(0, 10), cours: course.code, titre: exam.title, lieu: exam.location });
      }
    }
  }
  return { echeancesAcademiques: calendar, evaluations: exams };
}

function studyTime(data, args) {
  const days = Number.isFinite(args.days) ? args.days : 7;
  const byCourse = {};
  const byType = {};
  for (const session of (data.sessions || []).filter((s) => daysAgo(s.startedAt, days))) {
    const course = session.course || "sans cours";
    byCourse[course] = (byCourse[course] || 0) + session.durationSeconds;
    byType[session.taskType] = (byType[session.taskType] || 0) + session.durationSeconds;
  }
  return {
    jours: days,
    total: hours(Object.values(byCourse).reduce((a, b) => a + b, 0)),
    parCours: Object.entries(byCourse).sort((a, b) => b[1] - a[1]).map(([c, s]) => ({ cours: c, temps: hours(s) })),
    parType: Object.entries(byType).sort((a, b) => b[1] - a[1]).map(([t, s]) => ({ type: t, temps: hours(s) })),
  };
}

const HANDLERS = {
  study_overview: (data, args) => studyOverview(data),
  list_courses: (data, args) => listCourses(data, unwrap(args)),
  what_to_do: (data, args) => whatToDo(data, unwrap(args)),
  coverage: (data, args) => coverage(data),
  search: (data, args) => search(data, unwrap(args)),
  upcoming_dates: (data, args) => upcomingDates(data, unwrap(args)),
  study_time: (data, args) => studyTime(data, unwrap(args)),
};

// ─────────────────────────────────────────────────────────── JSON-RPC 2.0 ────

function respond(id, result) {
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n");
}

function respondError(id, code, message) {
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, error: { code, message } }) + "\n");
}

function handle(message) {
  const { id, method, params } = message;
  // Une notification n'a pas d'identifiant : on n'y répond pas.
  const isNotification = id === undefined || id === null;

  switch (method) {
    case "initialize":
      respond(id, {
        protocolVersion: PROTOCOL_VERSION,
        capabilities: { tools: {} },
        serverInfo: SERVER_INFO,
      });
      return;

    case "notifications/initialized":
    case "initialized":
      return;

    case "ping":
      respond(id, {});
      return;

    case "tools/list":
      respond(id, { tools: TOOLS });
      return;

    case "tools/call": {
      const name = params && params.name;
      const handler = HANDLERS[name];
      if (!handler) {
        respondError(id, -32602, `Outil inconnu : ${name}`);
        return;
      }
      try {
        const data = loadSnapshot();
        respond(id, text(handler(data, params.arguments)));
      } catch (error) {
        // L'erreur est **dans** le résultat, pas dans le protocole : le client
        // MCP l'affiche à l'utilisateur, qui peut alors corriger le chemin.
        respond(id, { content: [{ type: "text", text: String(error.message || error) }], isError: true });
      }
      return;
    }

    default:
      if (!isNotification) respondError(id, -32601, `Méthode inconnue : ${method}`);
  }
}

const rl = readline.createInterface({ input: process.stdin, terminal: false });
rl.on("line", (line) => {
  const trimmed = line.trim();
  if (!trimmed) return;
  let message;
  try {
    message = JSON.parse(trimmed);
  } catch {
    // Ligne illisible : on le dit, plutôt que de rester muet et de faire croire
    // à un serveur figé.
    respondError(null, -32700, "Message JSON illisible");
    return;
  }
  try {
    handle(message);
  } catch (error) {
    respondError(message.id ?? null, -32603, String(error.message || error));
  }
});
