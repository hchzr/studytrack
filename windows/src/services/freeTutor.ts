// Le tuteur de repli, quand Claude Code n'est pas sur le PC : la fonction serveur `tutor`
// (supabase/functions/tutor) répond avec un modèle gratuit d'abord (Groq), payant en repli.
// La même forme que `ClaudeConversation` : l'écran ne voit pas la différence. L'historique de
// chaque série est gardé sur l'appareil (le serveur ne garde rien).

import { supabaseConfig } from "./syncConfig.ts";
import { nativeFetch } from "../native/http.ts";
import { installID } from "../native/settings.ts";
import type { ChatMessage } from "./claudeConversation.ts";

export type TutorMode = "tutor" | "sheet" | "sheetMethods";

export interface TutorAnswer { text: string; model: string; provider: string }

/** Une question au serveur ; `messages` alternent étudiant·e / tuteur, le dernier est la question. */
export async function askTutor(mode: TutorMode, messages: { role: "user" | "assistant"; content: string }[]): Promise<TutorAnswer> {
  const config = supabaseConfig();
  if (!config) throw new Error("Ce build n'a pas de serveur : le tuteur gratuit n'est pas disponible.");
  const response = await nativeFetch(`${config.url}/functions/v1/tutor`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json", apikey: config.anonKey, Authorization: `Bearer ${config.anonKey}`,
      "x-studytrack-install": installID(),
    },
    body: JSON.stringify({ mode, messages }),
    signal: AbortSignal.timeout(mode === "tutor" ? 75_000 : 160_000),
  });
  const data = await response.json().catch(() => ({})) as { text?: string; model?: string; provider?: string; error?: string };
  if (!response.ok || !data.text) throw new Error(data.error ?? `Le tuteur ne répond pas (${response.status}).`);
  return { text: data.text, model: data.model ?? "", provider: data.provider ?? "" };
}

type Listener = () => void;

/** Une conversation par série avec le tuteur gratuit. */
export class FreeTutorConversation {
  messages: ChatMessage[] = [];
  /** Ce que le serveur a vraiment reçu (avec le contexte ajouté par l'app). */
  private sent: { role: "user" | "assistant"; content: string }[] = [];
  busy = false;
  activity: string | null = null;
  error: string | null = null;
  /** Le modèle de la dernière réponse (« openai/gpt-oss-120b »). */
  model: string | null = null;
  private listeners = new Set<Listener>();

  constructor(readonly key: string) {}

  subscribe(listener: Listener): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private changed(): void {
    for (const listener of this.listeners) listener();
  }

  private storageKey(): string { return `tutor.history.${this.key}`; }

  async loadHistory(): Promise<boolean> {
    try {
      const raw = localStorage.getItem(this.storageKey());
      if (!raw) return false;
      const saved = JSON.parse(raw) as { messages: ChatMessage[]; sent: FreeTutorConversation["sent"] };
      this.messages = saved.messages;
      this.sent = saved.sent;
      this.changed();
      return true;
    } catch {
      return false;
    }
  }

  private persist(): void {
    try {
      // Les 40 derniers échanges suffisent au contexte.
      localStorage.setItem(this.storageKey(), JSON.stringify({ messages: this.messages.slice(-80), sent: this.sent.slice(-80) }));
    } catch { /* trop gros : la conversation vaut pour la session */ }
  }

  async send(shown: string, sent: string = shown): Promise<void> {
    if (this.busy) return;
    this.error = null;
    if (shown.trim() !== "") this.messages.push({ fromStudent: true, text: shown });
    this.messages.push({ fromStudent: false, text: "", streaming: true });
    this.sent.push({ role: "user", content: sent });
    this.busy = true;
    this.activity = "Réfléchit…";
    this.changed();
    try {
      const answer = await askTutor("tutor", this.sent);
      this.model = answer.model;
      this.sent.push({ role: "assistant", content: answer.text });
      const last = this.messages[this.messages.length - 1];
      last.text = answer.text;
      last.streaming = false;
      this.persist();
    } catch (error) {
      this.sent.pop();
      this.messages.pop();
      this.error = error instanceof Error ? error.message : String(error);
    } finally {
      this.busy = false;
      this.activity = null;
      this.changed();
    }
  }

  close(): void { /* rien à fermer */ }
}
