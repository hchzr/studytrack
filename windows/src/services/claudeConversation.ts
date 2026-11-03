// Une conversation avec Claude, par l'abonnement (ClaudeChat.swift du Mac) : un processus
// `claude` (Claude Code) par série, sa session gardée par Claude Code et reprise (`--resume`)
// d'un lancement à l'autre. Les arguments, les messages et la lecture du flux viennent de
// `ClaudeTutor` (pur, testé) ; le processus vit côté Rust (native/claude.rs).

import { ClaudeTutor, type ClaudeAttachment, type ClaudeEvent } from "../domain/claudeTutor.ts";
import { callNative, callNativeOrThrow, listenNative } from "../native/tauri.ts";

export interface ChatMessage {
  fromStudent: boolean;
  text: string;
  /** Une réponse encore en train de s'écrire. */
  streaming?: boolean;
}

export interface ClaudeSetup { found: boolean; workdir: string }

let setup: Promise<ClaudeSetup | null> | null = null;
export function claudeSetup(): Promise<ClaudeSetup | null> {
  setup ??= callNative<ClaudeSetup>("claude_setup");
  return setup;
}

type Listener = () => void;

export class ClaudeConversation {
  messages: ChatMessage[] = [];
  busy = false;
  /** L'outil que Claude utilise en ce moment (« Lecture du PDF »…). */
  activity: string | null = null;
  error: string | null = null;
  private running = false;
  private resumed = false;
  private triedRecovery = false;
  private pending: string[] = [];
  private listeners = new Set<Listener>();
  private offs: (() => void)[] = [];

  constructor(readonly key: string, readonly sessionID: string, readonly systemPrompt: string) {}

  subscribe(listener: Listener): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private changed(): void {
    for (const listener of this.listeners) listener();
  }

  /** L'historique de la session, si elle existe déjà (une série reprise). */
  async loadHistory(): Promise<boolean> {
    const info = await claudeSetup();
    if (!info) return false;
    const jsonl = await callNative<string | null>("claude_history", {
      folder: ClaudeTutor.sessionFolderName(info.workdir), session: this.sessionID,
    });
    if (!jsonl) return false;
    this.messages = ClaudeTutor.history(jsonl).map((message) => ({
      fromStudent: message.fromStudent,
      text: message.fromStudent ? ClaudeTutor.displayText(message.text) : message.text,
    })).filter((message) => message.text !== "");
    this.resumed = true;
    this.changed();
    return true;
  }

  private async start(): Promise<void> {
    if (this.running) return;
    this.offs.push(listenNative<{ key: string; line: string }>("claude:line", ({ key, line }) => {
      if (key === this.key) this.onEvent(ClaudeTutor.parse(line));
    }));
    this.offs.push(listenNative<{ key: string; code: number | null; stderr: string }>("claude:exit", ({ key, stderr }) => {
      if (key === this.key) void this.onExit(stderr);
    }));
    const args = ClaudeTutor.arguments({ sessionID: this.sessionID, resume: this.resumed, systemPrompt: this.systemPrompt });
    await callNativeOrThrow("claude_start", { key: this.key, args });
    this.running = true;
  }

  /** Envoie un message (le texte montré peut différer de ce que Claude reçoit : le contexte ajouté). */
  async send(shown: string, sent: string = shown, attachments: ClaudeAttachment[] = []): Promise<void> {
    this.error = null;
    if (shown.trim() !== "") this.messages.push({ fromStudent: true, text: shown });
    this.messages.push({ fromStudent: false, text: "", streaming: true });
    this.busy = true;
    this.changed();
    const line = ClaudeTutor.userLine(sent, attachments);
    try {
      await this.start();
      await callNativeOrThrow("claude_send", { key: this.key, line });
      this.pending = [line];
    } catch (error) {
      this.fail(error instanceof Error ? error.message : String(error));
    }
  }

  private onEvent(event: ClaudeEvent | null): void {
    if (!event) return;
    const last = this.messages[this.messages.length - 1];
    switch (event.kind) {
      case "text":
        if (last && !last.fromStudent && last.streaming) last.text += event.text;
        this.activity = null;
        break;
      case "tool":
        this.activity = ClaudeTutor.toolLabel(event.name);
        break;
      case "thinking":
        this.activity = "Réfléchit…";
        break;
      case "finished":
        if (last && last.streaming) last.streaming = false;
        if (last && !last.fromStudent && last.text === "" && event.error) last.text = event.error;
        this.busy = false;
        this.activity = null;
        this.resumed = true;
        if (event.error) this.error = event.error;
        break;
      default:
        break;
    }
    this.changed();
  }

  private async onExit(stderr: string): Promise<void> {
    this.running = false;
    this.offs.forEach((off) => off());
    this.offs = [];
    if (!this.busy) return;
    // Session déjà là (ou introuvable) : on relance une fois dans le bon mode, et on renvoie.
    const recovery = ClaudeTutor.sessionRecovery(stderr);
    if (recovery !== null && !this.triedRecovery && this.pending.length > 0) {
      this.triedRecovery = true;
      this.resumed = recovery === "resume";
      try {
        await this.start();
        for (const line of this.pending) await callNativeOrThrow("claude_send", { key: this.key, line });
        return;
      } catch (error) {
        this.fail(error instanceof Error ? error.message : String(error));
        return;
      }
    }
    this.fail(stderr.trim().split("\n").slice(-3).join(" ") || "Claude s'est arrêté.");
  }

  private fail(message: string): void {
    const last = this.messages[this.messages.length - 1];
    if (last && last.streaming && last.text === "") this.messages.pop();
    else if (last?.streaming) last.streaming = false;
    this.busy = false;
    this.activity = null;
    this.error = /login|log in|authenticat|connect/i.test(message)
      ? "Claude Code n'est pas connecté : ouvre un terminal, tape « claude » une fois et connecte ton compte Claude."
      : message;
    this.changed();
  }

  close(): void {
    void callNative("claude_stop", { key: this.key });
    this.offs.forEach((off) => off());
    this.offs = [];
    this.running = false;
  }
}
