// `fetch` sans CORS : dans l'app, la requête part côté Rust (plugin HTTP de Tauri) ;
// dans le navigateur (aperçu Vite) c'est le `fetch` ordinaire.
//
// Les fonctions Supabase (`extract-series`, `analyze-course`) n'autorisent pas
// l'en-tête `x-polymestre-install` en CORS, et les sites de cours n'en envoient
// aucun : la webview ne peut pas les appeler directement. Les URL joignables sont
// bornées par la permission `http:default` de `capabilities/default.json`.

import { inNative } from "./tauri.ts";

/** `maxRedirections: 0` rend la redirection telle quelle (AnkiWeb : l'adresse de redirection est la racine du serveur du compte). */
export async function nativeFetch(input: string, init?: RequestInit & { maxRedirections?: number }): Promise<Response> {
  if (inNative()) {
    const { fetch: tauriFetch } = await import("@tauri-apps/plugin-http");
    return tauriFetch(input, init);
  }
  const { maxRedirections, ...rest } = init ?? {};
  return fetch(input, maxRedirections === 0 ? { ...rest, redirect: "manual" } : rest);
}
