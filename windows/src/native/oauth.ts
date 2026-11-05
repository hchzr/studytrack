// Le retour d'OAuth par une boucle locale (RFC 8252) : Google refuse les webviews intégrées,
// on ouvre donc le navigateur du système. La commande Rust `oauth_start` écoute un port de
// 127.0.0.1 le temps d'une connexion et émet `oauth:callback` avec l'adresse reçue.

import { callNativeOrThrow, inNative } from "./tauri.ts";
import type { Loopback } from "../services/oauth.ts";

export async function startLoopback(fixedPort?: number): Promise<Loopback> {
  if (!inNative()) throw new Error("La connexion Google s'ouvre dans l'app Polymestre pour Windows.");
  const { listen } = await import("@tauri-apps/api/event");
  const unlisten: (() => void)[] = [];
  let fail: (e: Error) => void = () => {};
  let settled = false;
  const callback = new Promise<string>((resolve, reject) => {
    fail = (e) => { if (!settled) { settled = true; reject(e); } };
    void (async () => {
      unlisten.push(await listen<string>("oauth:callback", (e) => { if (!settled) { settled = true; resolve(String(e.payload)); } }));
      unlisten.push(await listen("oauth:timeout", () => fail(new Error("La connexion Google a expiré : réessaie."))));
    })();
  });
  const cleanup = () => { unlisten.forEach((f) => f()); unlisten.length = 0; };
  let port: number;
  try {
    port = await callNativeOrThrow<number>("oauth_start", fixedPort ? { port: fixedPort } : {});
  } catch (e) {
    cleanup();
    throw new Error(typeof e === "string" ? e : "Impossible d'ouvrir la connexion locale.");
  }
  // Le flux se termine par `cancel` (toujours appelé) : l'écoute Rust et les abonnements se ferment.
  const result = callback.finally(cleanup);
  result.catch(() => {});
  return {
    redirect: `http://127.0.0.1:${port}/auth-callback`,
    callback: result,
    cancel: () => {
      fail(new Error("Connexion Google annulée."));
      void callNativeOrThrow("oauth_cancel").catch(() => {});
      cleanup();
    },
  };
}

/** Ouvre une adresse https dans le navigateur du système. */
export async function openInBrowser(url: string): Promise<void> {
  const { openUrl } = await import("@tauri-apps/plugin-opener");
  await openUrl(url);
}
