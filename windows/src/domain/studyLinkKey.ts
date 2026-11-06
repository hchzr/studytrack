// Ce qui identifie un document du cours, quelle que soit la forme de son lien
// (Polymestre/Domain/StudyLinkKey.swift) : la même section du polycopié s'écrit
// `…?polycopie=matiere/m_x`, `…?cours=&polycopie=/handout/matiere/m_x` ou
// `/handout/matiere/m_x` ; la même vidéo Courseware, `…/xblock/block-v1:…` ou
// `block-v1:…`. Pur, testé.

import { trimWhitespacesAndNewlines } from "./textRepair.ts";

/** `/handout/matiere/m_x` → `matiere/m_x` (`BotafogoLinks.handoutID`). */
function handoutID(path: string): string {
  let id = path;
  while (id.startsWith("/")) id = id.slice(1);
  if (id.toLowerCase().startsWith("handout/")) id = id.slice("handout/".length);
  return id;
}

/** `…?polycopie=…` ou `/handout/…` → `/handout/matiere/m_x`. */
export function handoutPath(address: string): string | null {
  if (address.startsWith("/handout/")) return address.toLowerCase();
  let url: URL;
  try {
    url = new URL(address);
  } catch {
    return null;
  }
  if (!url.hostname.includes("botafogo")) return null;
  const raw = url.searchParams.get("polycopie");
  if (raw === null || raw === "") return null;
  return "/handout/" + handoutID(raw).toLowerCase();
}

/** `…/jump_to/block-v1:EPFL+X+2025+type@vertical+block@abc` → le bloc. */
export function coursewareBlock(address: string): string | null {
  const start = address.indexOf("block-v1:");
  if (start < 0) return null;
  let block = address.slice(start);
  const end = block.search(/[?#/]/);
  if (end >= 0) block = block.slice(0, end);
  try {
    return decodeURIComponent(block);
  } catch {
    return block;
  }
}

/** Une adresse ramenée à ce qui l'identifie. */
export function key(address: string): string {
  const path = handoutPath(address);
  if (path !== null) return "poly:" + path;
  const block = coursewareBlock(address);
  if (block !== null) return "edx:" + block;
  let value = trimWhitespacesAndNewlines(address);
  const hash = value.indexOf("#");
  if (hash >= 0) value = value.slice(0, hash);
  while (value.endsWith("/")) value = value.slice(0, -1);
  return value.toLowerCase();
}

export const StudyLinkKey = { key, handoutPath, coursewareBlock };
