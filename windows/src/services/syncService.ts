// Le service de synchronisation : ce qui relie la base locale (`LocalStore`),
// le moteur (`SyncEngine`) et Supabase (`SupabaseClient`) au reste de l'app.
//
// Trois états décident de tout, et aucun ne sous-entend les autres :
//   - **configuré** : le build embarque VITE_SUPABASE_URL/VITE_SUPABASE_ANON_KEY
//     (syncConfig.ts). Sinon tout est un no-op qui se dit « non configuré » ;
//   - **connecté** : une session survit au redémarrage (sessionStore.ts) ;
//   - **activé** : l'étudiant·e a demandé l'envoi — **off par défaut**, comme le
//     plan Apple : personne n'envoie ses données sans l'avoir dit. Se connecter
//     ne suffit pas.
//
// Branchement par l'app, une fois au démarrage (App.tsx) :
//
//     syncService.attach({ local, reload });   // la LocalStore derrière SqliteSource,
//                                               // et le rechargement du graphe après une lecture
//     syncService.startAutoSync();              // une passe tout de suite, puis toutes les 5 min
//
// Après chaque save/remove, l'app appelle `noteLocalWrite()` : la passe part
// seule trois secondes plus tard, les saisies groupées.
//
// `syncNow()` ne lève jamais : un échec se lit dans l'état (`lastError`), jamais
// en plein écran.

import { SyncEngine, type SyncReport } from "../sync/engine.ts";
import type { LocalStore } from "../sync/store.ts";
import { SupabaseTransport } from "../sync/supabaseTransport.ts";
import { SupabaseClient, SupabaseError, type Session } from "./supabase.ts";
import { supabaseConfig, type SupabaseConfig } from "./syncConfig.ts";
import { LocalSessionStore, defaultStorage } from "./sessionStore.ts";
import { runOAuth, oauthMessage } from "./oauth.ts";
import { startLoopback, openInBrowser } from "../native/oauth.ts";
import type { Loopback } from "./oauth.ts";

/** Le rapport de la dernière passe, pour l'écran Réglages. */
export type { SyncReport } from "../sync/engine.ts";

/** Clés `localStorage` : le drapeau et l'état survivent aux lancements. */
export const ENABLED_KEY = "studytrack.sync.enabled";
export const STATUS_KEY = "studytrack.sync.status";

/** Attente après une écriture locale : grouper les saisies en une passe. */
export const WRITE_DEBOUNCE_MS = 3_000;
/** Période du rattrapage : cinq minutes, comme le plan Apple. */
export const AUTO_SYNC_MS = 5 * 60_000;

/** Ce qui reste d'une passe : assez pour l'afficher, pas assez pour gêner. */
interface PersistedStatus {
  lastSyncAt: string | null;
  lastError: string | null;
  lastReport: SyncReport | null;
}

/** La photographie pour l'écran Réglages. */
export interface SyncStatus {
  configured: boolean;
  signedIn: boolean;
  email: string | null;
  enabled: boolean;
  lastSyncAt: string | null;
  lastError: string | null;
  lastReport: SyncReport | null;
}

/** Ce qu'on branche au démarrage : la base locale, et la relue de l'écran. */
export interface AttachInputs {
  local: LocalStore;
  /** Reconstruit le graphe après une lecture (le `reload` du DataProvider). */
  reload: () => Promise<void>;
}

export interface SyncServiceInputs {
  /** `null` : build sans configuration — le service se dit « non configuré ». */
  config: SupabaseConfig | null;
  /** Où gardent le drapeau et l'état ; `null` → tout reste en mémoire. */
  storage?: Storage | null;
  /** Les requêtes réseau ; les tests passent un fetch simulé. */
  fetchImpl?: typeof fetch;
  /** Écoute du rappel OAuth et ouverture du navigateur ; les tests passent des faux. */
  oauthLoopback?: () => Promise<Loopback>;
  openBrowser?: (url: string) => Promise<void>;
}

/** Le refus du serveur d'authentification, dit en français. */
function authMessage(e: unknown): string {
  if (e instanceof SupabaseError) {
    const raw = e.message.toLowerCase();
    if (e.status >= 500) return `Le serveur a un problème (${e.status}) : réessaie dans un instant.`;
    if (/already|exist/.test(raw)) return "Cette adresse a déjà un compte : connecte-toi.";
    if (/password/.test(raw) && /at least|weak|too short/.test(raw)) {
      return "Le mot de passe est trop court (6 caractères au moins).";
    }
    if (/invalid|validation/.test(raw) && /email|address|courriel/.test(raw)) {
      return "Cette adresse e-mail n'est pas valide.";
    }
    if (e.status === 400 || e.status === 401 || e.status === 403) return "E-mail ou mot de passe refusé.";
    return `Le serveur a refusé la demande (${e.status}).`;
  }
  if (e instanceof TypeError) return "Réseau indisponible : vérifie ta connexion et réessaie.";
  return e instanceof Error ? e.message : "La connexion a échoué.";
}

/** Une erreur de passe, en français : l'état l'affiche, jamais une alerte. */
function syncMessage(e: unknown): string {
  if (e instanceof SupabaseError) return `Erreur serveur (${e.status}) : ${e.message}`;
  if (e instanceof TypeError) return "Réseau indisponible : vérifie ta connexion.";
  return e instanceof Error ? e.message : "La synchronisation a échoué.";
}

/**
 * La session d'une réponse d'inscription. `null` quand le projet exige la
 * confirmation de l'adresse : Supabase répond alors l'utilisateur, sans jeton.
 */
function sessionFromSignUp(raw: unknown): Session | null {
  if (raw === null || typeof raw !== "object") return null;
  const value = raw as Record<string, unknown>;
  if (typeof value.access_token !== "string" || value.access_token === "") return null;
  const user = value.user as { id?: string; email?: string } | null | undefined;
  // Sans `expires_in`, on suppose une heure — la valeur par défaut de Supabase,
  // et se tromper vers le bas ne coûte qu'un rafraîchissement.
  const expiresIn = typeof value.expires_in === "number" ? value.expires_in : 3600;
  return {
    access_token: value.access_token,
    refresh_token: typeof value.refresh_token === "string" ? value.refresh_token : "",
    expires_at: typeof value.expires_at === "number"
      ? value.expires_at
      : Math.floor(Date.now() / 1000) + expiresIn,
    user: { id: user?.id ?? "", email: user?.email },
  };
}

function readEnabled(storage: Storage | null): boolean {
  try {
    return (storage?.getItem(ENABLED_KEY) ?? "") === "1";
  } catch {
    return false;
  }
}

function readStatus(storage: Storage | null): PersistedStatus {
  try {
    const raw = storage?.getItem(STATUS_KEY);
    if (!raw) return { lastSyncAt: null, lastError: null, lastReport: null };
    const value = JSON.parse(raw) as Partial<PersistedStatus>;
    return {
      lastSyncAt: typeof value.lastSyncAt === "string" ? value.lastSyncAt : null,
      lastError: typeof value.lastError === "string" ? value.lastError : null,
      lastReport: value.lastReport ?? null,
    };
  } catch {
    return { lastSyncAt: null, lastError: null, lastReport: null };
  }
}

export class SyncService {
  private readonly storage: Storage | null;
  private readonly client: SupabaseClient | null;
  private readonly sessions: LocalSessionStore | null;
  private readonly fetchImpl: typeof fetch;
  private readonly oauthLoopback: () => Promise<Loopback>;
  private readonly openBrowser: (url: string) => Promise<void>;
  private oauthCancel: (() => void) | null = null;

  private local: LocalStore | null = null;
  private reload: (() => Promise<void>) | null = null;
  private readonly listeners = new Set<() => void>();
  private enabled: boolean;
  private persisted: PersistedStatus;
  private writeTimer: ReturnType<typeof setTimeout> | null = null;
  private autoTimer: ReturnType<typeof setInterval> | null = null;
  /** La passe en cours : un appel pendant l'autre l'attend, le moteur de plus en serialise. */
  private pending: Promise<SyncReport | null> | null = null;

  constructor(inputs: SyncServiceInputs) {
    this.storage = inputs.storage === undefined ? defaultStorage() : inputs.storage;
    this.fetchImpl = inputs.fetchImpl ?? ((...a) => fetch(...a));
    this.oauthLoopback = inputs.oauthLoopback ?? startLoopback;
    this.openBrowser = inputs.openBrowser ?? openInBrowser;
    this.enabled = readEnabled(this.storage);
    this.persisted = readStatus(this.storage);
    if (inputs.config !== null) {
      this.sessions = new LocalSessionStore(this.storage);
      this.client = new SupabaseClient(inputs.config.url, inputs.config.anonKey, this.sessions, inputs.fetchImpl);
    } else {
      this.sessions = null;
      this.client = null;
    }
  }

  /** Ce que l'app branche au démarrage : sa base, et sa façon de redessiner. */
  attach(inputs: AttachInputs): void {
    this.local = inputs.local;
    this.reload = inputs.reload;
  }

  /** Abonne l'écran aux changements ; renvoie le désabonnement. */
  subscribe(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => { this.listeners.delete(listener); };
  }

  // MARK: - Compte

  async signIn(email: string, password: string): Promise<void> {
    if (!this.client) throw new Error("La synchronisation n'est pas configurée sur ce poste.");
    try {
      await this.client.signInWithPassword(email, password);
    } catch (e) {
      throw new Error(authMessage(e));
    }
    this.notify();
  }

  async signUp(email: string, password: string): Promise<void> {
    if (!this.client) throw new Error("La synchronisation n'est pas configurée sur ce poste.");
    // Le client n'a pas de `signUp` (le Swift passe par la même requête) :
    // `/auth/v1/signup` s'appelle sans session, la clé anon en Bearer.
    let raw: unknown;
    try {
      raw = await this.client.request("/auth/v1/signup", { method: "POST", body: { email, password }, auth: false });
    } catch (e) {
      throw new Error(authMessage(e));
    }
    const session = sessionFromSignUp(raw);
    if (!session) {
      // Le projet demande la confirmation de l'adresse : pas de session avant
      // le clic dans le message reçu.
      throw new Error("Compte créé : confirme l'adresse e-mail reçue, puis connecte-toi.");
    }
    // Inscription = connexion quand le projet signe tout de suite.
    await this.client.setSession(session);
    this.notify();
  }

  /** « Continuer avec Google » : le flux PKCE, puis la session comme après `signIn`. */
  async signInWithGoogle(): Promise<void> {
    if (!this.client) throw new Error("La synchronisation n'est pas configurée sur ce poste.");
    await runOAuth({ client: this.client, fetchImpl: this.fetchImpl, startLoopback: this.oauthLoopback, openBrowser: this.openBrowser, onWaiting: (c) => { this.oauthCancel = c; this.notify(); } });
    this.notify();
  }

  /** Lier une identité Google au compte connecté (« manual linking » à activer sur le projet). */
  async linkGoogle(): Promise<void> {
    if (!this.client) throw new Error("La synchronisation n'est pas configurée sur ce poste.");
    await runOAuth({ client: this.client, fetchImpl: this.fetchImpl, startLoopback: this.oauthLoopback, openBrowser: this.openBrowser, link: true, onWaiting: (c) => { this.oauthCancel = c; this.notify(); } });
    this.notify();
  }

  /** Une connexion Google attend le navigateur ? */
  get oauthWaiting(): boolean { return this.oauthCancel !== null; }

  /** « Annuler » pendant l'attente du navigateur. */
  cancelOAuth(): void { this.oauthCancel?.(); }

  /** Fournisseurs du compte connecté ; vide si inconnus ou hors ligne. */
  async providers(): Promise<string[]> {
    if (!this.client || !(await this.session())) return [];
    try {
      return await this.client.providers();
    } catch (e) {
      void oauthMessage(e);
      return [];
    }
  }

  async signOut(): Promise<void> {
    if (!this.client || !this.sessions) return;
    if (await this.sessions.load()) {
      // Révoque le jeton côté serveur — meilleur effort, comme le `try?` Swift :
      // un serveur injoignable ne doit pas garder l'utilisateur connecté ici.
      try {
        await this.client.request("/auth/v1/logout", { method: "POST" });
      } catch {
        // on efface quand même, ci-dessous
      }
    }
    await this.client.signOut();
    this.notify();
  }

  /** L'opt-in, le seul geste qui décide d'envoyer. Off par défaut.
   *  L'allumer part une passe : l'appareil qui décide de synchroniser y envoie
   *  ce qu'il a déjà (l'« envoi initial » du plan), pas seulement ce qui vient. */
  setEnabled(value: boolean): void {
    this.enabled = value;
    try {
      this.storage?.setItem(ENABLED_KEY, value ? "1" : "0");
    } catch {
      // Le réglage vaut pour cette session.
    }
    if (value) void this.syncNow();
    this.notify();
  }

  // MARK: - Passes

  /**
   * À appeler après chaque écriture locale : la passe partira seule trois
   * secondes plus tard — deux saisies rapprochées n'en font qu'une.
   */
  noteLocalWrite(): void {
    if (this.writeTimer !== null) clearTimeout(this.writeTimer);
    this.writeTimer = setTimeout(() => {
      this.writeTimer = null;
      void this.syncNow();
    }, WRITE_DEBOUNCE_MS);
  }

  /**
   * Le rattrapage : une passe tout de suite — un appareil resté fermé deux
   * jours rattrape avant qu'on ne cherche ses données — puis toutes les cinq
   * minutes. Chaque passe se garde elle-même (no-op hors opt-in).
   */
  startAutoSync(): void {
    if (this.autoTimer !== null) return;
    void this.syncNow();
    this.autoTimer = setInterval(() => { void this.syncNow(); }, AUTO_SYNC_MS);
  }

  /**
   * Une passe complète : envoi puis lecture, puis rechargement du graphe.
   * `null` = rien fait (non configuré, non activé, non connecté, pas de base
   * branchée) ou échec — l'état dit lequel. Ne lève jamais.
   */
  syncNow(): Promise<SyncReport | null> {
    if (!this.ready()) return Promise.resolve(null);
    this.pending ??= this.run().finally(() => { this.pending = null; });
    return this.pending;
  }

  private ready(): boolean {
    return this.client !== null && this.local !== null && this.enabled;
  }

  private async run(): Promise<SyncReport | null> {
    const client = this.client;
    const local = this.local;
    if (!client || !local || !(await this.session())) return null;
    try {
      const report = await new SyncEngine(local, new SupabaseTransport(client)).sync();
      this.persisted = { lastSyncAt: new Date().toISOString(), lastError: null, lastReport: report };
      this.writeStatus();
      // Une lecture a pu changer le graphe sous l'écran : on le reconstruit.
      await this.reload?.();
      this.notify();
      return report;
    } catch (e) {
      // L'échec d'une passe n'est jamais une erreur d'écran : il s'affiche,
      // et la prochaine (timer, écriture, bouton) retente.
      this.persisted = { ...this.persisted, lastError: syncMessage(e) };
      this.writeStatus();
      this.notify();
      return null;
    }
  }

  /** La photographie pour l'écran Réglages. */
  async status(): Promise<SyncStatus> {
    const session = await this.session();
    return {
      configured: this.client !== null,
      signedIn: session !== null,
      email: session?.user.email ?? null,
      enabled: this.enabled,
      ...this.persisted,
    };
  }

  private async session(): Promise<Session | null> {
    return this.sessions?.load() ?? null;
  }

  private writeStatus(): void {
    try {
      this.storage?.setItem(STATUS_KEY, JSON.stringify(this.persisted));
    } catch {
      // L'état vaut pour cette session.
    }
  }

  private notify(): void {
    for (const listener of this.listeners) listener();
  }
}

/** L'instance de l'app : configurée par l'environnement de build, tout le reste en découle. */
export const syncService = new SyncService({ config: supabaseConfig() });
