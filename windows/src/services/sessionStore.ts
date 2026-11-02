// La session Supabase dans `localStorage` — le pendant de
// `StudyTrack/Services/SupabaseSessionStore.swift`, qui la met au trousseau
// parce qu'un jeton d'accès est un secret et que `UserDefaults` est un fichier
// lisible dans une sauvegarde.
//
// La forme gardée est celle de `StoredSession` (`SupabaseSession.swift`),
// exactement ce que les apps Apple reliraient : même JSON, mêmes champs, la
// date au format `Codable` par défaut. Le trousseau n'existe pas dans une
// webview Tauri ; `localStorage` est ce qui s'en rapproche — et ce qu'il garde
// ne sort pas du profil de l'app.

import { appStorage } from "../native/secrets.ts";
import { inNative } from "../native/tauri.ts";
import { StoredSession } from "../domain/supabaseSession.ts";
import type { Session, SessionStore } from "./supabase.ts";

/** La clé de `localStorage` ; les tests comme l'app la relisent telle quelle. */
export const SESSION_KEY = "studytrack.supabase.session";

/**
 * Dans l'app Tauri, le coffre du système (secrets.ts : la session porte le jeton
 * de rafraîchissement) ; sinon `localStorage` s'il existe, `null` sous Node (tests).
 */
export function defaultStorage(): Storage | null {
  if (inNative()) return appStorage as unknown as Storage;
  try {
    return typeof globalThis.localStorage === "undefined" ? null : globalThis.localStorage;
  } catch {
    return null;
  }
}

/** `Session` du client (champs Supabase) → `StoredSession` du domaine (champs Swift). */
function toStored(session: Session): StoredSession {
  return new StoredSession({
    accessToken: session.access_token,
    refreshToken: session.refresh_token === "" ? null : session.refresh_token,
    userID: session.user.id,
    email: session.user.email ?? null,
    // `expires_at` est en secondes depuis l'époque Unix ; le domaine veut une date.
    expiresAt: new Date(session.expires_at * 1000),
  });
}

/** Le chemin inverse : rendre au client ce que l'app a gardé entre deux lancements. */
function fromStored(stored: StoredSession): Session {
  return {
    access_token: stored.accessToken,
    refresh_token: stored.refreshToken ?? "",
    expires_at: Math.floor(stored.expiresAt.getTime() / 1000),
    user: {
      id: stored.userID ?? StoredSession.subjectOfJWT(stored.accessToken) ?? "",
      email: stored.email ?? undefined,
    },
  };
}

/**
 * La session entre deux lancements. Sans stockage (Node dans les tests), tout
 * est un no-op : la connexion tient pour la session en cours et ne survit pas —
 * exactement ce que ferait un navigateur qui refuse l'écriture.
 */
export class LocalSessionStore implements SessionStore {
  constructor(private readonly storage: Storage | null = defaultStorage()) {}

  async load(): Promise<Session | null> {
    let raw: string | null = null;
    try {
      raw = this.storage?.getItem(SESSION_KEY) ?? null;
    } catch {
      raw = null;
    }
    if (raw === null) return null;
    // Comme `load` de SupabaseSessionStore.swift : une session non utilisable
    // (jeton vide) vaut une absence — pas une erreur à afficher.
    const stored = StoredSession.decode(raw);
    if (!stored || !stored.isUsable) return null;
    return fromStored(stored);
  }

  async save(session: Session | null): Promise<void> {
    try {
      if (session === null) this.storage?.removeItem(SESSION_KEY);
      else this.storage?.setItem(SESSION_KEY, toStored(session).encoded());
    } catch {
      // Un stockage refusé (quota, navigation privée) ne doit pas casser la
      // connexion en cours — elle ne survivra simplement pas au redémarrage.
    }
  }
}
