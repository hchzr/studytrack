// Ed Discussion (CourseSiteClients.swift › EdClient) : les fils, poser une question, répondre,
// les leçons. La clé d'Ed vient de la fenêtre de connexion (native/ed.rs), rangée dans le
// coffre du système ; les appels partent côté Rust (`nativeFetch`, sans CORS) avec `X-Token`.

import { EdDiscussion, type EdCourse, type EdLesson, type EdPoll, type EdPost, type EdQuestion, type EdSlide, type EdThread } from "../domain/siteContent.ts";
import { Institution } from "../domain/institution.ts";
import { callNative, callNativeOrThrow } from "../native/tauri.ts";
import { nativeFetch } from "../native/http.ts";
import { SiteError } from "./siteSession.ts";

const SECRET = "ed.token";

let credentials: { region: string; token: string } | null | undefined;

async function token(): Promise<{ region: string; token: string } | null> {
  if (credentials !== undefined) return credentials;
  const found = await callNative<Record<string, string>>("secrets_load", { keys: [SECRET] });
  const raw = found?.[SECRET] ?? "";
  const at = raw.indexOf("|");
  credentials = at > 0 ? { region: raw.slice(0, at), token: raw.slice(at + 1) } : null;
  return credentials;
}

/** Après une connexion (l'événement `ed:signed-in`) : relire la clé. */
export function edForget(): void {
  credentials = undefined;
}

export async function edSignIn(): Promise<void> {
  await callNativeOrThrow("ed_sign_in", { region: Institution.current.edRegion });
}

export async function edSignOut(): Promise<void> {
  await callNative("ed_sign_out");
  credentials = null;
}

async function api(path: string, method = "GET", body?: unknown): Promise<string> {
  const creds = await token();
  if (!creds) throw new SiteError("notSignedIn");
  const response = await nativeFetch(`https://${creds.region}.edstem.org/api/${path}`, {
    method,
    headers: { "X-Token": creds.token, ...(body !== undefined ? { "Content-Type": "application/json" } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(20_000),
  });
  if (response.status === 401) {
    // Clé expirée : on l'oublie, la prochaine lecture demandera la connexion.
    await edSignOut();
    throw new SiteError("notSignedIn");
  }
  const text = await response.text();
  if (!response.ok) throw new SiteError("failed", `Ed a refusé (${response.status}).`);
  return text;
}

export const Ed = {
  courses: async (): Promise<EdCourse[]> => EdDiscussion.courses(await api("user")),
  threads: async (course: number): Promise<EdThread[]> => EdDiscussion.threads(await api(`courses/${course}/threads?limit=50&sort=new`)),
  thread: async (id: number): Promise<EdPost | null> => EdDiscussion.thread(await api(`threads/${id}?view=1`)),
  poll: async (id: number): Promise<EdPoll | null> => EdDiscussion.poll(await api(`polls/${id}`)),
  vote: async (poll: number, options: number[]): Promise<void> => {
    await api(`polls/${poll}/responses`, "POST", { option_indices: [...options].sort((a, b) => a - b) });
  },
  categories: async (course: number): Promise<string[]> => EdDiscussion.categories(await api(`courses/${course}`)),

  /** Une nouvelle question ou un message. */
  async postThread(course: number, o: { title: string; category: string; markdown: string; isQuestion: boolean; isPrivate: boolean; isAnonymous: boolean }): Promise<number | null> {
    const thread = {
      type: o.isQuestion ? "question" : "post", title: o.title, category: o.category,
      subcategory: "", subsubcategory: "", content: EdDiscussion.document(o.markdown),
      is_pinned: false, is_private: o.isPrivate, is_anonymous: o.isAnonymous, is_megathread: false, anonymous_comments: false,
    };
    const reply = JSON.parse(await api(`courses/${course}/threads`, "POST", { thread })) as { thread?: { id?: number } };
    return reply.thread?.id ?? null;
  },

  /** Répondre à un fil (réponse ou commentaire) ou à un commentaire. */
  async reply(target: { thread: number } | { comment: number }, markdown: string, isAnswer: boolean, isAnonymous = false): Promise<void> {
    const path = "thread" in target ? `threads/${target.thread}` : `comments/${target.comment}`;
    await api(`${path}/comments`, "POST", {
      comment: { type: isAnswer ? "answer" : "comment", content: EdDiscussion.document(markdown), is_private: false, is_anonymous: isAnonymous },
    });
  },

  lessons: async (course: number): Promise<EdLesson[]> => EdDiscussion.lessons(await api(`courses/${course}/lessons`)),
  async slides(lesson: number): Promise<EdSlide[]> {
    try { await api(`lessons/${lesson}/attempts`, "POST"); } catch { /* déjà commencée */ }
    return EdDiscussion.slides(await api(`lessons/${lesson}?view=1`));
  },
  questions: async (slide: number): Promise<EdQuestion[]> => EdDiscussion.questions(await api(`lessons/slides/${slide}/questions`)),
  async answer(question: number, response: unknown): Promise<{ correct: boolean | null; explanation: string | null }> {
    const reply = JSON.parse(await api(`lessons/slides/questions/${question}/responses`, "POST", response)) as { correct?: boolean; explanation?: string };
    return { correct: typeof reply.correct === "boolean" ? reply.correct : null, explanation: reply.explanation ?? null };
  },
  async complete(slide: number): Promise<void> {
    try { await api(`lessons/slides/${slide}/complete`, "PUT"); } catch { /* sans effet */ }
  },
};
