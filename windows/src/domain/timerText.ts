/** Lit et écrit une durée courte, telle qu'on la tape.
 *
 * Un champ éditable doit accepter ce que les gens écrivent vraiment : « 90 »,
 * « 1:30 », « 1h30 », « 1 h 30 », « 45m ». Refuser tout sauf un format imposé
 * rendrait le champ plus pénible que les boutons qu'il remplace.
 *
 * Fonctions **pures** : elles se testent sur des chaînes, y compris celles qui ne
 * doivent **pas** passer.
 */

/** Comme `String(format: "%.1f")` : un cas exactement à mi-chemin (0,25) va au pair, pas vers le haut. */
function format1(value: number): string {
  const quarters = value * 4;
  if (Number.isInteger(quarters) && Math.abs(quarters) % 2 === 1) {
    const floor = Math.floor(value * 10);
    return ((floor % 2 === 0 ? floor : floor + 1) / 10).toFixed(1);
  }
  return value.toFixed(1);
}

const pad2 = (n: number) => String(n).padStart(2, "0");

/** `Double("…")` de Swift : refuse le vide et les blancs, accepte exposants, « inf » et « nan ». */
function parseDouble(raw: string): number | null {
  if (/^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(raw)) return Number(raw);
  if (/^[+-]?(inf|infinity)$/i.test(raw)) return raw.startsWith("-") ? -Infinity : Infinity;
  if (/^[+-]?nan$/i.test(raw)) return NaN;
  return null;
}

/** Les mêmes remplacements que `replacingOccurrences(of:with:)`. */
const replaceAll = (text: string, from: string, to: string) => text.split(from).join(to);

export const TimerText = {
  /** Borne haute : douze heures. Au-delà, ce n'est plus une session d'étude. */
  maximumHours: 12,

  /** « 07:42 », « 1:02:09 » — l'affichage d'un chrono.
   *
   * Tronqué à la seconde : un compte à rebours passe `rounded(.up)` pour
   * afficher « 25:00 » au départ et « 00:01 » à la dernière seconde, pas
   * « 24:59 » puis « 00:00 » une seconde trop tôt.
   */
  clock(seconds: number): string {
    const total = Math.max(0, Math.trunc(seconds));
    const hours = Math.floor(total / 3600);
    const minutes = Math.floor((total % 3600) / 60);
    const secs = total % 60;
    return hours > 0 ? `${hours}:${pad2(minutes)}:${pad2(secs)}` : `${pad2(minutes)}:${pad2(secs)}`;
  },

  /** « 12:07 », « 1h05 » : un chrono qui tient dans un petit rond. */
  compact(seconds: number): string {
    const total = Math.max(0, Math.trunc(seconds));
    if (total >= 3600) {
      return `${Math.floor(total / 3600)}h${pad2(Math.floor((total % 3600) / 60))}`;
    }
    return `${pad2(Math.floor(total / 60))}:${pad2(total % 60)}`;
  },

  /** « 1:30 », « 90 », « 1h30 », « 45m », « 1,5h » → secondes.
   *
   * `null` quand rien n'est lisible — l'appelant garde alors la valeur en place
   * plutôt que de mettre zéro.
   */
  seconds(raw: string): number | null {
    let text = raw.trim().toLowerCase();
    text = replaceAll(text, " ", "");

    // La virgule décimale, en français.
    text = replaceAll(text, ",", ".");
    // Les séparateurs « h » et « : » sont interchangeables.
    text = replaceAll(text, "heures", "h");
    text = replaceAll(text, "heure", "h");
    text = replaceAll(text, "minutes", "m");
    text = replaceAll(text, "minute", "m");
    text = replaceAll(text, "min", "m");
    text = replaceAll(text, " ", "");

    if (text === "") return null;

    // « 1h30 » ou « 1.5h » ou « 1h ».
    if (text.includes("h")) {
      const index = text.indexOf("h");
      const first = text.slice(0, index);
      const rest = text.slice(index + 1);
      const hours = parseDouble(first) ?? 0;
      const minutes = minutesValue(rest);
      if (!Number.isFinite(hours) || minutes === null) return null;
      return clamp(hours * 3600 + minutes * 60);
    }

    // « 1:30 » — et c'est **heures:minutes**.
    //
    // Un champ de temps d'étude n'est pas un chronomètre : taper « 1:30 »
    // veut dire une heure et demie, jamais une minute et demie. Le format
    // affiché est le même, pour qu'écrire et relire se répondent.
    // Trois segments — « 1:30:15 » — restent des heures, minutes, secondes.
    if (text.includes(":")) {
      const parts = text.split(":");
      if (parts.length < 2 || parts.length > 3) return null;
      // « :30 » se lit comme « 0:30 » : on ne refuse pas une saisie dont le
      // sens est évident.
      const parsed = parts.map((part) => parseDouble(part === "" ? "0" : part));
      if (parsed.some((value) => value === null)) return null;
      const values = parsed as number[];
      if (values.length === 3) return clamp(values[0] * 3600 + values[1] * 60 + values[2]);
      return clamp(values[0] * 3600 + values[1] * 60);
    }

    // « 45m », « 30s », ou un nombre nu — qui veut dire des **minutes** :
    // taper « 90 » pour quatre-vingt-dix minutes est le geste naturel.
    if (text.endsWith("m")) {
      const minutes = parseDouble(text.slice(0, -1));
      if (minutes === null) return null;
      return clamp(minutes * 60);
    }
    if (text.endsWith("s")) {
      const value = parseDouble(text.slice(0, -1));
      if (value === null) return null;
      return clamp(value);
    }
    const minutes = parseDouble(text);
    if (minutes === null) return null;
    return clamp(minutes * 60);
  },

  /** « 1:30 » pour une heure et demie, « 0:45 » pour quarante-cinq minutes.
   *
   * Le format du champ, et celui que `seconds(raw)` relit : écrire et relire
   * se répondent. Les secondes sont arrondies — on ajuste un temps d'étude à la
   * minute, pas au dixième.
   */
  text(seconds: number): string {
    const total = Math.max(0, Math.round(seconds / 60));
    return `${Math.floor(total / 60)}:${pad2(total % 60)}`;
  },
};

/** Les minutes d'un fragment : « 30 », « 30m », « 30.5 ». */
function minutesValue(raw: string): number | null {
  let text = raw;
  if (text.endsWith("m")) text = text.slice(0, -1);
  if (text.startsWith(".")) text = "0" + text;
  if (text === "") return 0;
  return parseDouble(text);
}

function clamp(seconds: number): number {
  if (!Number.isFinite(seconds) || seconds < 0) return 0;
  return Math.min(seconds, TimerText.maximumHours * 3600);
}

// MARK: - Formats des widgets (Shared/WidgetBridge.swift)

/** Les textes courts des widgets : heures arrondies, compte à rebours en jours. */
export const WidgetFormat = {
  /** « 12 », « 1,5 » : des heures, sans unité, pour un anneau. */
  shortHours(seconds: number): string {
    const hours = Math.max(0, seconds) / 3600;
    if (hours >= 10 || hours === Math.round(hours)) return String(Math.round(hours));
    return format1(hours).replace(".", ",");
  },

  /** « 45 min », « 2 h », « 1,6 h » — dixièmes d'heure **arrondis**.
   *
   * La version précédente écrivait `minutes / 10` : 1 h 35 donnait « 1,3 h »,
   * soit dix-sept minutes de moins que la réalité.
   */
  hours(seconds: number): string {
    const totalMinutes = Math.floor(Math.max(0, seconds) / 60);
    if (totalMinutes < 60) return `${totalMinutes} min`;
    const tenths = Math.round((totalMinutes / 60) * 10);
    const hours = Math.floor(tenths / 10);
    const fraction = tenths % 10;
    return fraction === 0 ? `${hours} h` : `${hours},${fraction} h`;
  },

  /** « J-12 », « Demain », « Aujourd'hui ». Les jours se comptent en heure locale. */
  countdown(date: Date, reference: Date = new Date()): string {
    const day = (d: Date) => Date.UTC(d.getFullYear(), d.getMonth(), d.getDate());
    const days = Math.round((day(date) - day(reference)) / 86_400_000);
    if (days <= 0) return "Aujourd'hui";
    if (days === 1) return "Demain";
    return `J-${days}`;
  },
};
