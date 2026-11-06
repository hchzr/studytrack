// Distribuer l'app hors du simulateur (Polymestre/Domain/AppDistribution.swift) :
// le courriel « Signaler un problème » et le flux de mises à jour du Mac.
//
// Les adresses viennent de la configuration, jamais du code. Vides, les boutons
// n'apparaissent pas.

import { characters } from "./textRepair.ts";
import { LogBuffer, type LogEntry } from "./appLog.ts";

// MARK: - Configuration lue au lancement

interface DistributionConfig {
  feedbackEmail: string | null;
  siteHost: string | null;
  version: string | null;
  build: string | null;
}

const config: DistributionConfig = { feedbackEmail: null, siteHost: null, version: null, build: null };

/** Branche la configuration de la build (l'équivalent de `Info.plist`). */
export function configure(values: Partial<DistributionConfig>): void {
  Object.assign(config, values);
}

function configured(value: string | null): string | null {
  if (value === null || value === "" || value.startsWith("$(")) return null;
  return value;
}

/** Le courriel de retour (`null` : pas de bouton). */
export function feedbackAddress(): string | null { return configured(config.feedbackEmail); }

/** Le site public de l'app. */
export function siteHost(): string | null { return configured(config.siteHost); }

/** « 2.1 (14) » — lue dans la configuration de la build. */
export function versionLabel(): string {
  const short = configured(config.version) ?? "—";
  const build = configured(config.build) ?? "";
  return build === "" ? short : `${short} (${build})`;
}

/** Le numéro de build, s'il est connu. */
export function build(): string | null { return configured(config.build); }

export const AppDistribution = {
  configure,
  feedbackAddress,
  siteHost,
  versionLabel,
  build,
};

// MARK: - Signaler un problème

/**
 * Un courriel prêt à envoyer, avec la version, l'appareil et la fin du journal.
 * Un lien `mailto:` plutôt qu'une pièce jointe : il marche partout.
 */
export const FeedbackMail = {
  /** Au-delà, certaines apps de messagerie refusent le lien. */
  maxBody: 6000,

  url(to: string, version: string, device: string, entries: LogEntry[]): URL | null {
    const subject = `Polymestre ${version} — retour`;
    let body = `Ce qui s'est passé (et ce que tu attendais) :\n\n\n\n— Polymestre ${version} · ${device}\n`;
    if (entries.length > 0) {
      const room = FeedbackMail.maxBody - characters(body).length - 20;
      // La fin du journal : les dernières lignes sont celles qui expliquent.
      const journal = characters(LogBuffer.text(entries.slice(-40)));
      const start = Math.max(0, journal.length - Math.max(0, room));
      body += "\nFin du journal :\n" + journal.slice(start).join("");
    }
    const query = [["subject", subject], ["body", body]]
      .map(([name, value]) => `${name}=${FeedbackMail.percent(value.replace(/\n/g, "\r\n"))}`)
      .join("&");
    try {
      return new URL(`mailto:${to}?${query}`);
    } catch {
      return null;
    }
  },

  /** RFC 6068 : seuls les caractères non réservés restent tels quels. */
  percent(text: string): string {
    return encodeURIComponent(text).replace(/[!'()*]/g, (character) =>
      "%" + character.charCodeAt(0).toString(16).toUpperCase());
  },
};

// MARK: - Mises à jour du Mac

/** `https://<site>/mac/latest.json` : la dernière build du Mac. */
export class MacUpdateFeed {
  version: string;
  build: number;
  url: URL;
  notes: string | null;

  constructor(o: { version: string; build: number; url: URL; notes?: string | null }) {
    this.version = o.version;
    this.build = o.build;
    this.url = o.url;
    this.notes = o.notes ?? null;
  }

  static feedURL(siteHostValue: string): URL | null {
    try {
      return new URL(`https://${siteHostValue}/mac/latest.json`);
    } catch {
      return null;
    }
  }

  static decode(data: string): MacUpdateFeed | null {
    let raw: unknown;
    try {
      raw = JSON.parse(data);
    } catch {
      return null;
    }
    if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return null;
    const o = raw as Record<string, unknown>;
    if (typeof o.version !== "string" || typeof o.build !== "number" || typeof o.url !== "string") return null;
    if (o.notes !== undefined && o.notes !== null && typeof o.notes !== "string") return null;
    let url: URL;
    try {
      url = new URL(o.url);
    } catch {
      return null;
    }
    return new MacUpdateFeed({ version: o.version, build: o.build, url, notes: typeof o.notes === "string" ? o.notes : null });
  }

  /** Plus récente que la build qui tourne ? Le numéro de build seul fait foi. */
  isNewer(current: string | null): boolean {
    if (current === null || !/^[+-]?\d+$/.test(current)) return false;
    return this.build > Number(current);
  }

  /** Une lecture par jour au plus (une horloge reculée relit aussitôt). */
  static isDue(lastCheck: Date | null, now: Date = new Date()): boolean {
    if (lastCheck === null) return true;
    return now < lastCheck || (now.getTime() - lastCheck.getTime()) / 1000 >= 86_400;
  }
}
