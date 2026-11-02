// AnkiWeb, sans ordinateur : se connecter, garder une copie de la collection et en lire
// l'historique de révision (StudyTrack/Services/AnkiWeb/AnkiWebSync.swift).
//
// **Lecture seule sur Windows.** L'app ne synchronise pas « normalement » (pas d'envoi de
// notes, `pushPending` absent) : quand le serveur a changé, elle **retélécharge** la
// collection. Le serveur ne reçoit jamais rien d'elle ; la collection d'AnkiWeb n'est jamais
// écrasée. Le mot de passe ne sert qu'à obtenir la clé d'hôte ; seule la clé est gardée.

import { appStorage } from "../native/secrets.ts";
import type { AnkiReview } from "../domain/ankiReviewImport.ts";
import { AnkiWebClient, type Fetcher } from "./ankiWebClient.ts";
import { diskMirror, type MirrorStore } from "./ankiCollection.ts";
import { nativeFetch } from "../native/http.ts";

/** Où tiennent les préférences : `localStorage`, ou une table en mémoire (tests). */
export interface KeyValue {
  get(key: string): string | null;
  set(key: string, value: string | null): void;
}

export function localKeyValue(): KeyValue {
  return {
    // La clé d'hôte va au coffre (secrets.ts), comme AnkiKeychain sur le Mac.
    get: (key) => appStorage.getItem(key),
    set: (key, value) => {
      try {
        if (value === null) appStorage.removeItem(key);
        else appStorage.setItem(key, value);
      } catch { /* stockage refusé */ }
    },
  };
}

const Key = {
  username: "ankiweb.username",
  hostKey: "ankiweb.hostKey",
  endpoint: "ankiweb.endpoint",
  serverMod: "ankiweb.mirror.mod",
  serverUsn: "ankiweb.mirror.usn",
  serverSchema: "ankiweb.mirror.schema",
  lastRefresh: "ankiweb.mirror.refreshedAt",
  lastReviewID: "ankiweb.lastReviewID",
} as const;

export class AnkiWebSync {
  status = "";
  lastError: string | null = null;
  private working = false;

  constructor(
    private readonly store: KeyValue = localKeyValue(),
    private readonly mirror: MirrorStore = diskMirror(),
    private readonly fetcher: Fetcher = nativeFetch,
  ) {}

  get username(): string { return this.store.get(Key.username) ?? ""; }
  get isSignedIn(): boolean { return (this.store.get(Key.hostKey) ?? "") !== ""; }
  get isWorking(): boolean { return this.working; }
  get lastRefresh(): Date | null {
    const raw = this.store.get(Key.lastRefresh);
    return raw ? new Date(Number(raw)) : null;
  }

  private client(): AnkiWebClient {
    return new AnkiWebClient(this.store.get(Key.hostKey) ?? "", this.store.get(Key.endpoint), this.fetcher);
  }

  private remember(client: AnkiWebClient): void {
    this.store.set(Key.endpoint, client.endpoint);
  }

  // MARK: Compte

  /** Le mot de passe ne sert qu'à obtenir la clé d'hôte ; seule la clé est gardée. */
  async signIn(username: string, password: string): Promise<boolean> {
    this.working = true;
    this.lastError = null;
    try {
      const client = new AnkiWebClient("", this.store.get(Key.endpoint), this.fetcher);
      this.status = "Connexion à AnkiWeb…";
      const key = await client.login(username, password);
      this.store.set(Key.hostKey, key);
      this.store.set(Key.username, username);
      this.remember(client);
      await this.refreshMirror(true);
      return true;
    } catch (error) {
      this.lastError = error instanceof Error ? error.message : String(error);
      return false;
    } finally {
      this.working = false;
    }
  }

  async signOut(): Promise<void> {
    for (const key of Object.values(Key)) this.store.set(key, null);
    await this.mirror.remove();
    this.status = "";
  }

  // MARK: Copie de la collection

  /**
   * Retélécharge la collection si le serveur a changé depuis la copie. Toute erreur est
   * **montrée** : la synchronisation ne doit pas rester sur « Lecture d'AnkiWeb… » sans dire
   * ce qui a échoué.
   */
  async refreshMirror(force = false): Promise<void> {
    this.lastError = null;
    const client = this.client();
    this.status = "Lecture d'AnkiWeb…";
    try {
      const meta = await client.meta();
      this.remember(client);
      const local = await this.mirror.open();
      const unchanged = local !== null
        && String(meta.modified) === this.store.get(Key.serverMod)
        && String(meta.schema) === this.store.get(Key.serverSchema);
      if (!force && unchanged) {
        this.status = "À jour";
        this.store.set(Key.lastRefresh, String(Date.now()));
        return;
      }
      this.status = "Téléchargement de la collection…";
      await this.mirror.install(await client.download());
      // Le téléchargement incrémente le numéro de synchronisation du serveur : on relit
      // l'état pour que la copie corresponde exactement.
      const after = await client.meta();
      this.store.set(Key.serverMod, String(after.modified));
      this.store.set(Key.serverUsn, String(after.usn));
      this.store.set(Key.serverSchema, String(after.schema));
      this.store.set(Key.lastRefresh, String(Date.now()));
      this.status = "Collection à jour";
    } catch (error) {
      this.status = "";
      this.lastError = error instanceof Error ? error.message : String(error);
      throw error;
    }
  }

  // MARK: Révisions

  /**
   * Les révisions faites depuis le dernier relevé (tous appareils confondus, puisqu'elles
   * arrivent par AnkiWeb). Jamais plus de 30 jours en arrière.
   */
  async newReviews(now = new Date()): Promise<AnkiReview[]> {
    const collection = await this.mirror.open();
    if (collection === null) return [];
    const floor = now.getTime() - 30 * 86_400_000;
    const after = Math.max(Number(this.store.get(Key.lastReviewID) ?? 0), floor);
    const reviews = await collection.reviews(after);
    const last = reviews.reduce((m, r) => Math.max(m, r.id), 0);
    if (last > 0) this.store.set(Key.lastReviewID, String(last));
    return reviews;
  }
}

/** Le service partagé de l'app (`AnkiWebSync.shared`). */
export const ankiWebSync = new AnkiWebSync();
