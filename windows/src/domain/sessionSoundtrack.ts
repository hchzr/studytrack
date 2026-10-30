import type { DeskMoment } from "./deskMoment.ts";

/** La bande-son d'une session : une playlist qui démarre avec le mode étude,
 * se tait pendant les pauses et s'éteint à la fin.
 *
 * La décision est ici, pure et testée ; jouer, baisser le volume, mettre en
 * pause est dans le lecteur de l'app.
 */

/** Une playlist ou un album choisi pour les sessions. */
export interface SoundtrackChoice {
  kind: "playlist" | "album";
  id: string;
  title: string;
  shuffled: boolean;
}

/** Ce que fait la musique pendant une pause (Pomodoro, pause du cours). */
export type SoundtrackBreakPolicy = "pause" | "lower" | "keep";
export const soundtrackBreakPolicies: SoundtrackBreakPolicy[] = ["pause", "lower", "keep"];

/** Où en est la session, vue de la musique. */
export type SoundtrackPhase = "running" | "onBreak" | "paused" | "ended";

export type SoundtrackAction =
  | "none"
  /** Lancer la playlist choisie. */
  | "start"
  | "fadeOutAndPause"
  | "resumeAndFadeIn"
  | "lower"
  | "restoreVolume"
  | "fadeOutAndStop";

export const SessionSoundtrack = {
  /** Ce qu'il faut faire quand la session passe de `previous` à `current`.
   *
   * - Jamais pendant un cours : on écoute le cours.
   * - Rien sans playlist choisie.
   * - On n'arrête que la musique qu'on a lancée : si elle jouait déjà avant la
   *   session (la sienne), on la laisse.
   * - Une pause manuelle ne touche pas à la musique ; seule la pause du
   *   rythme (Pomodoro, cours) la suit.
   */
  action(args: {
    from: SoundtrackPhase | null | undefined;
    to: SoundtrackPhase;
    moment: DeskMoment;
    hasChoice: boolean;
    ownsPlayback: boolean;
    policy: SoundtrackBreakPolicy;
  }): SoundtrackAction {
    const { from: previous, to: current, moment, hasChoice, ownsPlayback, policy } = args;
    if (moment === "lecture" || !hasChoice) {
      // La session finit : si la musique est la nôtre, elle s'éteint quand même.
      return current === "ended" && ownsPlayback ? "fadeOutAndStop" : "none";
    }
    if (current === "ended") return ownsPlayback ? "fadeOutAndStop" : "none";
    if (current === "running" && (previous == null || previous === "ended")) return "start";
    if (previous === "running" && current === "onBreak") {
      switch (policy) {
        case "pause": return ownsPlayback ? "fadeOutAndPause" : "none";
        case "lower": return ownsPlayback ? "lower" : "none";
        case "keep": return "none";
      }
    }
    if (previous === "onBreak" && current === "running") {
      switch (policy) {
        case "pause": return ownsPlayback ? "resumeAndFadeIn" : "none";
        case "lower": return ownsPlayback ? "restoreVolume" : "none";
        case "keep": return "none";
      }
    }
    return "none";
  },

  /** Les paliers d'un fondu : `steps` valeurs de `from` à `to` (la dernière est `to`). */
  fade(from: number, to: number, steps: number): number[] {
    if (!(steps > 0)) return [to];
    return Array.from({ length: steps }, (_, i) => from + ((to - from) * (i + 1)) / steps);
  },

  /** Le choix en JSON (à ranger dans le magasin clé-valeur). */
  encode(choice: SoundtrackChoice | null | undefined): string | null {
    return choice ? JSON.stringify(choice) : null;
  },

  decode(text: string | null | undefined): SoundtrackChoice | null {
    if (text == null) return null;
    try {
      const data = JSON.parse(text);
      if ((data?.kind !== "playlist" && data?.kind !== "album") || typeof data.id !== "string"
        || typeof data.title !== "string" || typeof data.shuffled !== "boolean") return null;
      return { kind: data.kind, id: data.id, title: data.title, shuffled: data.shuffled };
    } catch {
      return null;
    }
  },
};
