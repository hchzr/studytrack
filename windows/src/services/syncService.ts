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
import { EncryptedTransport, ForeignKeyError, SkipStats } from "../sync/encryptedTransport.ts";
import {
  RecoveryKeyError, decodeRecoveryKey, deriveKeys, encodeRecoveryKey, fromHex, newAccountKey, openRow, toHex,
} from "../domain/syncCrypto.ts";
import { PairingHost, joinPairing, type HostState, type SocketFactory } from "./syncPairing.ts";
import { SupabaseClient, SupabaseError, type Session } from "./supabase.ts";
import { supabaseConfig, relayHost, type SupabaseConfig } from "./syncConfig.ts";
import { timerLink, storedTimerIdentity } from "./timerLinkClient.ts";
import { LocalSessionStore, defaultStorage } from "./sessionStore.ts";
import { runOAuth, oauthMessage } from "./oauth.ts";
import { startLoopback, openInBrowser } from "../native/oauth.ts";
import type { Loopback, OAuthProvider } from "./oauth.ts";

/** Le rapport de la dernière passe, pour l'écran Réglages. */
export type { SyncReport } from "../sync/engine.ts";

/** Clés `localStorage` : le drapeau et l'état survivent aux lancements. */
export const ENABLED_KEY = "studytrack.sync.enabled";
export const STATUS_KEY = "studytrack.sync.status";
/** La clé du compte (« <id utilisateur>:<hex> »), au coffre du système : jamais envoyée au serveur. */
export const ACCOUNT_KEY = "studytrack.sync.accountKey";

/** Attente après une écriture locale : grouper les saisies en une passe. */
export const WRITE_DEBOUNCE_MS = 3_000;
/** Période du rattrapage : cinq minutes, comme le plan Apple. */
export const AUTO_SYNC_MS = 5 * 60_000;

/** Ce qui reste d'une passe : assez pour l'afficher, pas assez pour gêner. */
interface PersistedStatus {
  lastSyncAt: string | null;
  lastError: string | null;
  lastReport: SyncReport | null;
  /** Lignes laissées de côté à la dernière passe : autre clé, illisibles. */
  skipped?: { foreignKey: number; unreadable: number };
}

/**
 * Où en est le chiffrement pour le compte connecté :
 *   - `signedOut` : pas de compte ; `unknown` : le coffre n'a pas encore été lu ;
 *   - `noVault` : personne n'a activé le chiffrement sur ce compte ;
 *   - `needsKey` : le compte est chiffré, cet appareil n'a pas la clé ;
 *   - `keyMismatch` : la clé d'ici n'est pas celle du coffre (coffre réinitialisé ailleurs) ;
 *   - `ready` : tout est en place.
 */
export type EncryptionState = "signedOut" | "unknown" | "noVault" | "needsKey" | "keyMismatch" | "ready";

/** La photographie pour l'écran Réglages. */
export interface SyncStatus {
  configured: boolean;
  signedIn: boolean;
  email: string | null;
  enabled: boolean;
  lastSyncAt: string | null;
  lastError: string | null;
  lastReport: SyncReport | null;
  encryption: EncryptionState;
  skippedForeignKey: number;
  skippedUnreadable: number;
  /** Le build connaît l'hôte du relais : l'appairage est possible. */
  pairingAvailable: boolean;
  /** Une passe est en cours, et ce qu'elle a déjà fait (`null` hors passe). */
  syncing: SyncReport | null;
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
  /** Hôte du relais pour l'appairage ; `undefined` → celui du build. */
  relayHost?: string | null;
  /** Les WebSocket de l'appairage ; les tests passent un relais en mémoire. */
  makeSocket?: SocketFactory;
}

/** Le refus du serveur d'authentification, dit en français. */
function authMessage(e: unknown): string {
  if (e instanceof SupabaseError) {
    const raw = e.message.toLowerCase();
    if (e.status >= 500) return `Le serveur a un problème (${e.status}) : réessaie dans un instant.`;
    if (/already|exist/.test(raw)) return "Cette adresse a déjà un compte : connecte-toi.";
    if (/not confirmed/.test(raw)) return "Adresse pas encore confirmée : tape le code reçu par e-mail.";
    if (/expired|invalid.*(otp|token)|(otp|token).*invalid/.test(raw)) return "Code faux ou expiré : vérifie-le, ou demande-en un nouveau.";
    if (e.status === 429 || /rate limit|security purposes/.test(raw)) {
      return "Trop d'essais d'affilée : attends une minute, puis réessaie.";
    }
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

const foreignKeyMessage = "Clé différente : des données de ce compte sont chiffrées avec une autre clé et restent ignorées. Ajoute cet appareil depuis un appareil connecté, ou utilise la clé de secours.";

/** Une erreur de passe, en français : l'état l'affiche, jamais une alerte. */
function syncMessage(e: unknown): string {
  if (e instanceof SupabaseError) return `Erreur serveur (${e.status}) : ${e.message}`;
  if (e instanceof Error && (e.name === "TimeoutError" || e.name === "AbortError")) {
    return "Le serveur ne répond pas : la passe a été interrompue, la suivante reprendra où elle en était.";
  }
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
  private readonly relay: string | null;
  private readonly makeSocket: SocketFactory | undefined;
  /** `key_id` du coffre : `undefined` = pas lu, `null` = le compte n'a pas de coffre. */
  private vaultKeyId: string | null | undefined = undefined;
  private pairing: PairingHost | null = null;

  private local: LocalStore | null = null;
  private reload: (() => Promise<void>) | null = null;
  private readonly listeners = new Set<() => void>();
  private enabled: boolean;
  private persisted: PersistedStatus;
  private writeTimer: ReturnType<typeof setTimeout> | null = null;
  private autoTimer: ReturnType<typeof setInterval> | null = null;
  /** La passe en cours : un appel pendant l'autre l'attend, le moteur de plus en serialise. */
  private pending: Promise<SyncReport | null> | null = null;
  /** La passe en cours : lignes envoyées et reçues jusqu'ici. */
  private progress: SyncReport | null = null;

  constructor(inputs: SyncServiceInputs) {
    this.storage = inputs.storage === undefined ? defaultStorage() : inputs.storage;
    this.fetchImpl = inputs.fetchImpl ?? ((...a) => fetch(...a));
    this.oauthLoopback = inputs.oauthLoopback ?? startLoopback;
    this.openBrowser = inputs.openBrowser ?? openInBrowser;
    this.relay = inputs.relayHost === undefined ? relayHost() : inputs.relayHost;
    this.makeSocket = inputs.makeSocket;
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
    this.vaultKeyId = undefined;
    this.notify();
    void this.refreshVault().catch(() => {});
  }

  /**
   * Créer un compte. `"confirm"` : le projet exige la confirmation de l'adresse — un code
   * (et un lien) part par e-mail, et `verifySignUp` termine. `"signedIn"` : c'est fait.
   */
  async signUp(email: string, password: string): Promise<"confirm" | "signedIn"> {
    if (!this.client) throw new Error("La synchronisation n'est pas configurée sur ce poste.");
    // Le client n'a pas de `signUp` (le Swift passe par la même requête) :
    // `/auth/v1/signup` s'appelle sans session, la clé anon en Bearer.
    let raw: unknown;
    try {
      raw = await this.client.request("/auth/v1/signup", { method: "POST", body: { email, password }, auth: false });
    } catch (e) {
      throw new Error(authMessage(e));
    }
    // Une adresse qui a déjà un compte : Supabase répond un utilisateur sans identité
    // (pour ne pas dire quelles adresses existent) et n'envoie rien.
    const identities = (raw as { identities?: unknown[] } | null)?.identities;
    if (Array.isArray(identities) && identities.length === 0) {
      throw new Error("Cette adresse a déjà un compte : connecte-toi (ou « Continuer avec Google » si tu l'as créé ainsi).");
    }
    const session = sessionFromSignUp(raw);
    // Le projet demande la confirmation de l'adresse : pas de session avant le code.
    if (!session) return "confirm";
    await this.adopt(session);
    return "signedIn";
  }

  /** Le code à 6 chiffres reçu par e-mail : confirme l'adresse et connecte. */
  async verifySignUp(email: string, code: string): Promise<void> {
    if (!this.client) throw new Error("La synchronisation n'est pas configurée sur ce poste.");
    let raw: unknown;
    try {
      raw = await this.client.request("/auth/v1/verify", {
        method: "POST", body: { type: "email", email, token: code.replace(/\s+/g, "") }, auth: false,
      });
    } catch (e) {
      throw new Error(authMessage(e));
    }
    const session = sessionFromSignUp(raw);
    if (!session) throw new Error("Code accepté, mais pas de session : connecte-toi avec ton mot de passe.");
    await this.adopt(session);
  }

  /** Renvoie le message de confirmation (code et lien). */
  async resendSignUp(email: string): Promise<void> {
    if (!this.client) throw new Error("La synchronisation n'est pas configurée sur ce poste.");
    try {
      await this.client.request("/auth/v1/resend", { method: "POST", body: { type: "signup", email }, auth: false });
    } catch (e) {
      throw new Error(authMessage(e));
    }
  }

  private async adopt(session: Session): Promise<void> {
    await this.client!.setSession(session);
    this.vaultKeyId = undefined;
    this.notify();
    void this.refreshVault().catch(() => {});
  }

  /** « Continuer avec Google » : le flux PKCE, puis la session comme après `signIn`. */
  async signInWithGoogle(): Promise<void> {
    await this.signInWith("google");
  }

  /**
   * « Continuer avec Apple » : le même flux, dans le navigateur du système. Pour les comptes
   * créés sur iPhone avec « Se connecter avec Apple » — le même compte, sans mot de passe.
   */
  async signInWithApple(): Promise<void> {
    await this.signInWith("apple");
  }

  private async signInWith(provider: OAuthProvider): Promise<void> {
    if (!this.client) throw new Error("La synchronisation n'est pas configurée sur ce poste.");
    await runOAuth({ client: this.client, fetchImpl: this.fetchImpl, startLoopback: this.oauthLoopback, openBrowser: this.openBrowser, provider, onWaiting: (c) => { this.oauthCancel = c; this.notify(); } });
    this.vaultKeyId = undefined;
    this.notify();
    void this.refreshVault().catch(() => {});
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
    this.pairing?.cancel();
    this.vaultKeyId = undefined;
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
    // Le chrono relié reprend tout de suite avec l'identité déjà reçue (sans attendre une passe).
    const identity = storedTimerIdentity();
    if (identity && this.relay && this.enabled) void timerLink.start(this.relay, identity);
    void this.syncNow();
    this.autoTimer = setInterval(() => { void this.syncNow(); }, AUTO_SYNC_MS);
  }

  /**
   * Une passe complète : envoi puis lecture, puis rechargement du graphe.
   * `null` = rien fait (non configuré, non activé, non connecté, pas de base
   * branchée) ou échec — l'état dit lequel. Ne lève jamais.
   */
  syncNow(): Promise<SyncReport | null> {
    if (this.enabled && this.client !== null && this.local === null) {
      // Ne devrait pas arriver : le dire plutôt que de ne rien faire en silence.
      this.persisted = { ...this.persisted, lastError: "La base locale n'est pas encore branchée à la synchronisation : relance StudyTrack." };
      this.notify();
    }
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
      const keys = await this.keysForPass();
      if (typeof keys === "string") {
        // Pas de passe tant que le chiffrement n'est pas en place : un état à lire, pas une alerte.
        this.persisted = { ...this.persisted, lastError: keys };
        this.writeStatus();
        this.notify();
        return null;
      }
      const stats = new SkipStats();
      this.progress = { pushed: 0, pulled: 0, keptLocal: 0, orphans: 0 };
      this.notify();
      const engine = new SyncEngine(local, new EncryptedTransport(new SupabaseTransport(client), keys, stats), 200, (r) => {
        this.progress = r;
        this.notify();
      });
      const report = await engine.sync();
      this.progress = null;
      const skipped = { foreignKey: stats.foreignKey, unreadable: stats.unreadable };
      this.persisted = {
        lastSyncAt: new Date().toISOString(), lastReport: report, skipped,
        lastError: stats.foreignKey > 0 ? foreignKeyMessage : null,
      };
      this.writeStatus();
      void this.linkTimer(client, keys);
      // Une lecture a pu changer le graphe sous l'écran : on le reconstruit.
      await this.reload?.();
      this.notify();
      return report;
    } catch (e) {
      this.progress = null;
      // L'échec d'une passe n'est jamais une erreur d'écran : il s'affiche,
      // et la prochaine (timer, écriture, bouton) retente.
      this.persisted = { ...this.persisted, lastError: e instanceof ForeignKeyError ? foreignKeyMessage : syncMessage(e) };
      this.writeStatus();
      this.notify();
      return null;
    }
  }

  /**
   * Le chrono relié : l'identité du compte publiée par l'iPhone ou le Mac (`sync_device_link`,
   * chiffrée avec la clé de données), puis la WebSocket du relais. Sans ligne : rien.
   */
  private async linkTimer(client: SupabaseClient, keys: { dataKey: Uint8Array; keyId: string }): Promise<void> {
    if (!this.relay) return;
    try {
      const session = await this.session();
      if (!session) return;
      const rows = await client.request<{ key_id: string; payload: string }[]>("/rest/v1/sync_device_link?select=key_id,payload");
      const row = rows?.[0];
      if (!row || row.key_id !== keys.keyId) return;
      const box = fromHex(row.payload.replace(/^\\x/, ""));
      if (!box) return;
      const fields = await openRow(keys.dataKey, "sync_device_link", session.user.id, box);
      if (typeof fields.timerIdentity === "string" && fields.timerIdentity !== "") {
        await timerLink.start(this.relay, fields.timerIdentity);
      }
    } catch {
      // Table absente ou ligne illisible : le chrono reste local.
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
      lastSyncAt: this.persisted.lastSyncAt,
      lastError: this.persisted.lastError,
      lastReport: this.persisted.lastReport,
      encryption: await this.encryptionState(session),
      skippedForeignKey: this.persisted.skipped?.foreignKey ?? 0,
      skippedUnreadable: this.persisted.skipped?.unreadable ?? 0,
      pairingAvailable: this.relay !== null,
      syncing: this.progress,
    };
  }

  // MARK: - Chiffrement de bout en bout

  /** La clé du compte gardée sur cet appareil pour cet utilisateur ; `null` s'il n'y en a pas. */
  private loadAccountKey(userId: string): Uint8Array | null {
    try {
      const raw = this.storage?.getItem(ACCOUNT_KEY) ?? "";
      const at = raw.indexOf(":");
      if (at < 0 || raw.slice(0, at).toLowerCase() !== userId.toLowerCase()) return null;
      const key = fromHex(raw.slice(at + 1));
      return key && key.length === 32 ? key : null;
    } catch {
      return null;
    }
  }

  private storeAccountKey(userId: string, key: Uint8Array): void {
    try {
      this.storage?.setItem(ACCOUNT_KEY, `${userId.toLowerCase()}:${toHex(key)}`);
    } catch {
      throw new Error("Impossible de ranger la clé dans le coffre de cet appareil.");
    }
  }

  private async encryptionState(session: Session | null): Promise<EncryptionState> {
    if (!session) return "signedOut";
    if (this.vaultKeyId === undefined) return "unknown";
    if (this.vaultKeyId === null) return "noVault";
    const key = this.loadAccountKey(session.user.id);
    if (!key) return "needsKey";
    return (await deriveKeys(key)).keyId === this.vaultKeyId ? "ready" : "keyMismatch";
  }

  /** Lit le coffre du compte (`sync_vault`) : il dit si un coffre existe et quelle clé il attend. */
  async refreshVault(): Promise<void> {
    if (!this.client || !(await this.session())) { this.vaultKeyId = undefined; return; }
    const rows = await this.client.request<{ key_id: string }[]>("/rest/v1/sync_vault?select=key_id");
    this.vaultKeyId = rows[0]?.key_id ?? null;
    this.notify();
  }

  /** Les clés d'une passe, ou la raison (en français) pour laquelle il n'y en a pas. */
  private async keysForPass(): Promise<{ dataKey: Uint8Array; keyId: string } | string> {
    const session = await this.session();
    if (!session) return "Connecte-toi pour synchroniser.";
    await this.refreshVault(); // une petite requête : un coffre réinitialisé ailleurs se voit ici
    if (this.vaultKeyId === null) return "Active d'abord la synchronisation chiffrée.";
    const ak = this.loadAccountKey(session.user.id);
    if (!ak) return "Ce compte est chiffré : ajoute cet appareil depuis un appareil déjà connecté.";
    const keys = await deriveKeys(ak);
    if (keys.keyId !== this.vaultKeyId) return foreignKeyMessage;
    return keys;
  }

  private async requireUser(): Promise<{ client: SupabaseClient; userId: string }> {
    const session = await this.session();
    if (!this.client || !session) throw new Error("Connecte-toi d'abord.");
    return { client: this.client, userId: session.user.id };
  }

  /**
   * Crée le coffre du compte : une clé neuve, rangée ici seulement, et son identifiant public.
   * Rend la clé de secours, à montrer une fois. Allume la synchronisation.
   */
  async enableEncryption(): Promise<string> {
    const { client, userId } = await this.requireUser();
    await this.refreshVault();
    if (this.vaultKeyId !== null) throw new Error("Ce compte est déjà chiffré : ajoute cet appareil par un code ou la clé de secours.");
    const recovery = await this.createVault(client, userId);
    this.setEnabled(true);
    return recovery;
  }

  private async createVault(client: SupabaseClient, userId: string): Promise<string> {
    const ak = newAccountKey();
    const { keyId } = await deriveKeys(ak);
    try {
      await client.request("/rest/v1/sync_vault", { method: "POST", body: { key_id: keyId }, prefer: "return=minimal" });
    } catch (e) {
      if (e instanceof SupabaseError && e.status === 409) {
        await this.refreshVault();
        throw new Error("Un autre appareil vient d'activer le chiffrement sur ce compte : ajoute cet appareil par un code.");
      }
      throw e;
    }
    this.storeAccountKey(userId, ak);
    this.vaultKeyId = keyId;
    await this.local?.resetSyncState();
    this.notify();
    return encodeRecoveryKey(ak);
  }

  /** La clé de secours de ce compte, pour l'afficher (l'écran demande confirmation avant). */
  async recoveryKey(): Promise<string | null> {
    const session = await this.session();
    const ak = session ? this.loadAccountKey(session.user.id) : null;
    return ak ? encodeRecoveryKey(ak) : null;
  }

  /** « Restaurer avec la clé de secours » : vérifiée contre le coffre avant d'être rangée. */
  async restoreFromRecoveryKey(text: string): Promise<void> {
    const { userId } = await this.requireUser();
    let ak: Uint8Array;
    try {
      ak = await decodeRecoveryKey(text);
    } catch (e) {
      if (e instanceof RecoveryKeyError) {
        throw new Error(e.kind === "checksum"
          ? "Une faute s'est glissée dans la clé : relis-la caractère par caractère."
          : "Cette clé de secours n'est pas valide : 54 caractères, par groupes de 4.");
      }
      throw e;
    }
    await this.refreshVault();
    if (this.vaultKeyId === null) throw new Error("Ce compte n'a pas encore de coffre : active d'abord le chiffrement.");
    if ((await deriveKeys(ak)).keyId !== this.vaultKeyId) throw new Error("Cette clé de secours n'est pas celle de ce compte.");
    this.storeAccountKey(userId, ak);
    await this.local?.resetSyncState(false);
    this.setEnabled(true);
  }

  /** « Ajouter un appareil » : ouvre le salon d'appairage (la WebSocket ne vit que tant que l'écran l'attend). */
  async startPairing(onState: (state: HostState, message: string | null) => void): Promise<PairingHost> {
    const { userId } = await this.requireUser();
    const ak = this.loadAccountKey(userId);
    if (!ak) throw new Error("Cet appareil n'a pas la clé du compte.");
    if (!this.relay) throw new Error("Ce build ne connaît pas le relais : utilise la clé de secours.");
    this.pairing?.cancel();
    const host = await PairingHost.start({ accountKey: ak, host: this.relay, makeSocket: this.makeSocket, onState });
    this.pairing = host;
    return host;
  }

  /** « Entrer un code d'appairage » sur le nouvel appareil. */
  async joinPairing(code: string): Promise<void> {
    const { userId } = await this.requireUser();
    await this.refreshVault();
    if (this.vaultKeyId === null || this.vaultKeyId === undefined) throw new Error("Ce compte n'a pas encore de coffre.");
    if (!this.relay) throw new Error("Ce build ne connaît pas le relais : utilise la clé de secours.");
    const ak = await joinPairing({ code, expectedKeyId: this.vaultKeyId, host: this.relay, makeSocket: this.makeSocket });
    this.storeAccountKey(userId, ak);
    await this.local?.resetSyncState(false);
    this.setEnabled(true);
  }

  /**
   * « Réinitialiser le coffre » : le dernier recours quand ni les appareils ni la clé de
   * secours ne sont plus là. Efface les lignes chiffrées du compte et son coffre sur le
   * serveur (une transaction), puis cet appareil crée un coffre neuf et renvoie ses données.
   */
  async resetVault(): Promise<string> {
    const { client, userId } = await this.requireUser();
    await client.request("/rest/v1/rpc/sync_reset_vault", { method: "POST", body: {} });
    this.vaultKeyId = null;
    const recovery = await this.createVault(client, userId);
    this.setEnabled(true);
    return recovery;
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
