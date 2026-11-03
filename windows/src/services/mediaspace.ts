// MediaSpace (Kaltura chez SWITCH) : une vidéo du cours lue dans l'app, sans passer par le
// site (CourseSiteClients.swift › MediaSpaceClient.playbackURL). Le manifeste public d'abord ;
// sinon celui qu'ouvre la clé de session de la page MediaSpace (connexion SWITCH, une fois).

import { Institution } from "../domain/institution.ts";
import { Kaltura } from "../domain/siteContent.ts";
import { nativeFetch } from "../native/http.ts";
import { openSiteLogin, siteRequest } from "./siteSession.ts";

/** L'identifiant Kaltura d'une vidéo (« 0_6y8w1d2s ») : le dernier d'une adresse. */
export function entryID(link: string): string | null {
  let decoded = link;
  try { decoded = decodeURIComponent(link); } catch { /* telle quelle */ }
  const all = [...decoded.matchAll(/[/=]([01]_[a-z0-9]{8})(?=[/?#&]|$)/g)];
  return all.length > 0 ? all[all.length - 1][1] : null;
}

/** Une page qui regroupe des vidéos (chaîne, catégorie, liste), et non une vidéo seule. */
export function isCollection(link: string): boolean {
  let url: URL;
  try { url = new URL(link); } catch { return false; }
  if (!url.hostname.endsWith(Institution.current.videoHostName)) return false;
  const path = url.pathname;
  if (/\/(channel|category|channels)\//.test(path)) return true;
  if (path.includes("/playlist/")) return path.split("/").filter((part) => /^[01]_[a-z0-9]{8}$/.test(part)).length === 1;
  return false;
}

/** Une vidéo MediaSpace seule, lisible dans l'app ? */
export function isMediaSpaceVideo(link: string): boolean {
  try {
    const host = new URL(link).hostname;
    const video = host.endsWith(Institution.current.videoHostName) || host.includes("kaltura");
    return video && !isCollection(link) && entryID(link) !== null;
  } catch {
    return false;
  }
}

async function playable(url: URL): Promise<boolean> {
  try {
    const response = await nativeFetch(url.toString(), { signal: AbortSignal.timeout(15_000) });
    return response.ok && Kaltura.isPlayableManifest((await response.text()).slice(0, 4096));
  } catch {
    return false;
  }
}

/** L'adresse lisible (HLS) ; `null` : il faut se connecter à MediaSpace, ou la vidéo n'existe plus. */
export async function playbackURL(id: string): Promise<string | null> {
  const open = Kaltura.manifestURL(id);
  if (open && await playable(open)) return open.toString();
  try {
    const page = await siteRequest(`https://${Institution.current.videoHostName}/media/t/${id}`, { timeout: 25 });
    if (/wayf|eduid|login|saml/i.test(page.url)) return null;
    const config = Kaltura.config(page.body);
    if (!config.ks) return null;
    const url = Kaltura.manifestURL(id, config.partnerID ?? Kaltura.defaultPartner, config.ks);
    return url && await playable(url) ? url.toString() : null;
  } catch {
    return null;
  }
}

export async function mediaspaceSignIn(): Promise<void> {
  await openSiteLogin("mediaspace", `https://${Institution.current.videoHostName}/user/login`, "Connexion à MediaSpace");
}
