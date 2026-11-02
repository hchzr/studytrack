// La session d'un site de cours (StudyTrack/Services/CourseSiteClients.swift ›
// HiddenSiteSession).
//
// Sur le Mac, un navigateur invisible charge une page du site et y exécute ses
// propres appels. Ici le transport est la couche Rust (`native/site.rs`) : les
// requêtes partent avec les cookies de la **fenêtre de connexion** (WebView2),
// et l'analyse HTML se fait dans la webview (`DOMParser`). Hors de l'app il n'y a
// pas de session : tout échoue proprement (« disponible dans l'app Windows »).

import { callNativeOrThrow, inNative } from "../native/tauri.ts";

/** Les trois façons dont un site échoue (`HiddenSiteSession.SiteError`). */
export class SiteError extends Error {
  constructor(readonly kind: "timeout" | "notSignedIn" | "failed", message?: string) {
    super(message ?? SiteError.describe(kind));
    this.name = "SiteError";
  }

  static describe(kind: "timeout" | "notSignedIn" | "failed"): string {
    switch (kind) {
      case "timeout": return "Le site ne répond pas. Vérifie ta connexion.";
      case "notSignedIn": return "Connecte-toi d'abord (une seule fois).";
      case "failed": return "Le site a répondu autrement que prévu.";
    }
  }
}

export interface SiteResponse {
  status: number;
  /** L'adresse finale, après redirections. */
  url: string;
  contentType: string;
  /** Le corps en texte ; vide pour un PDF ou une image. */
  body: string;
}

export interface SiteRequestInit {
  method?: string;
  headers?: Record<string, string>;
  body?: string;
  /** Secondes avant d'abandonner (20 par défaut). */
  timeout?: number;
}

/** Les requêtes de session ne fonctionnent que dans l'app (la session vit dans WebView2). */
export function siteAvailable(): boolean { return inNative(); }

function payload(url: string, init: SiteRequestInit) {
  return {
    req: {
      url,
      method: init.method ?? "GET",
      headers: init.headers ? Object.entries(init.headers) : [],
      body: init.body ?? null,
      timeout: init.timeout ?? 20,
    },
  };
}

function failure(error: unknown): SiteError {
  const message = typeof error === "string" ? error : error instanceof Error ? error.message : String(error);
  if (/timed out|timeout|délai/i.test(message)) return new SiteError("timeout");
  if (/non autorisé/i.test(message)) return new SiteError("notSignedIn");
  return new SiteError("failed", message);
}

/** Une requête avec la session du site. */
export async function siteRequest(url: string, init: SiteRequestInit = {}): Promise<SiteResponse> {
  if (!inNative()) throw new SiteError("failed", "Les sites de cours se lisent dans l'app Windows.");
  try {
    const raw = await callNativeOrThrow<{ status: number; url: string; content_type: string; body: string }>("site_request", payload(url, init));
    return { status: raw.status, url: raw.url, contentType: raw.content_type, body: raw.body };
  } catch (error) {
    throw failure(error);
  }
}

/** Un fichier (PDF…) téléchargé avec la session. */
export async function siteDownload(url: string, init: SiteRequestInit = {}): Promise<Uint8Array> {
  if (!inNative()) throw new SiteError("failed", "Les sites de cours se lisent dans l'app Windows.");
  try {
    const raw = await callNativeOrThrow<ArrayBuffer | number[]>("site_download", payload(url, init));
    return raw instanceof ArrayBuffer ? new Uint8Array(raw) : new Uint8Array(raw);
  } catch (error) {
    throw failure(error);
  }
}

/** Ouvre la fenêtre de connexion d'un site — la connexion faite une fois sert à tous les imports suivants. */
export async function openSiteLogin(label: string, url: string, title: string): Promise<void> {
  if (!inNative()) throw new SiteError("failed", "La connexion se fait dans l'app Windows.");
  try {
    await callNativeOrThrow("site_login_open", { label, url, title });
  } catch (error) {
    throw failure(error);
  }
}

export async function closeSiteLogin(label: string): Promise<void> {
  if (!inNative()) return;
  try { await callNativeOrThrow("site_login_close", { label }); } catch { /* déjà fermée */ }
}

/** Le HTML d'une réponse, en document (comme le `DOMParser` des scripts du Mac). */
export function parseHTML(html: string): Document {
  return new DOMParser().parseFromString(html, "text/html");
}
