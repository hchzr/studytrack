// `fetch` sans CORS : dans l'app, la requête part côté Rust (plugin HTTP de Tauri) ;
// dans le navigateur (aperçu Vite) c'est le `fetch` ordinaire.
//
// Les fonctions Supabase (`extract-series`, `analyze-course`) n'autorisent pas
// l'en-tête `x-studytrack-install` en CORS, et les sites de cours n'en envoient
// aucun : la webview ne peut pas les appeler directement. Les URL joignables sont
// bornées par la permission `http:default` de `capabilities/default.json`.

import { inNative } from "./tauri.ts";

export async function nativeFetch(input: string, init?: RequestInit): Promise<Response> {
  if (inNative()) {
    const { fetch: tauriFetch } = await import("@tauri-apps/plugin-http");
    return tauriFetch(input, init);
  }
  return fetch(input, init);
}
