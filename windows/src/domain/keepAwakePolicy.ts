/** Garder le Mac éveillé pendant le mode étude — et seulement quand ça sert.
 *
 * La décision est ici, pure et testée ; l'assertion d'énergie elle-même vit
 * dans l'app (sous Windows, à brancher sur l'API d'exécution de l'hôte).
 *
 * Le principe : la moindre dépense. On ne tient la machine éveillée que pendant
 * que le chrono **tourne** — en pause, l'étudiant·e est parti·e et elle dort
 * comme d'habitude. L'écran ne reste allumé que si on l'a demandé, et jamais en
 * mode économie d'énergie ni sur une batterie presque vide : là, seule la
 * machine reste éveillée (la musique continue, le verrou tient, l'écran
 * s'éteint). Fermer le capot endort toujours la machine.
 */

/** Le réglage. */
export type KeepAwakeMode = "off" | "system" | "display";
export const keepAwakeModes: KeepAwakeMode[] = ["off", "system", "display"];

/** Ce qu'il faut tenir, maintenant. */
export type KeepAwakeHold = "system" | "display";

export interface KeepAwakePower {
  lowPowerMode: boolean;
  onBattery: boolean;
  /** 0…1, `null` sans batterie (poste de bureau). */
  batteryLevel?: number | null;
}

export const KeepAwakePolicy = {
  /** En dessous, sur batterie, l'écran n'est plus tenu allumé. */
  lowBattery: 0.2,

  /** Une session sans heure de fin : l'assertion expire d'elle-même au bout
   * de ce délai, et se renouvelle tant que le chrono tourne. Un plantage ne
   * peut donc pas laisser la machine éveillée pour toujours. */
  openEndedLease: 2 * 3600,
  /** La marge après l'heure de fin prévue (le temps de terminer, de prolonger). */
  endMargin: 5 * 60,

  /** `Power.init(...)` : tout est faux par défaut. */
  power(partial: Partial<KeepAwakePower> = {}): KeepAwakePower {
    return { lowPowerMode: false, onBattery: false, batteryLevel: null, ...partial };
  },

  get plugged(): KeepAwakePower {
    return KeepAwakePolicy.power();
  },

  hold(args: {
    mode: KeepAwakeMode;
    studying: boolean;
    running: boolean;
    onBreak: boolean;
    power: KeepAwakePower;
  }): KeepAwakeHold | null {
    const { mode, studying, running, onBreak, power } = args;
    if (mode === "off" || !studying || !(running || onBreak)) return null;
    // Pause Pomodoro : on s'éloigne de l'écran, il peut s'éteindre.
    if (mode !== "display" || onBreak) return "system";
    const lowBattery = power.onBattery && (power.batteryLevel ?? 1) < KeepAwakePolicy.lowBattery;
    return power.lowPowerMode || lowBattery ? "system" : "display";
  },

  /** Quand l'assertion doit expirer d'elle-même. */
  expiry(until: Date | null | undefined, now: Date = new Date()): Date {
    if (!until || !(until.getTime() > now.getTime())) {
      return new Date(now.getTime() + KeepAwakePolicy.openEndedLease * 1000);
    }
    return new Date(until.getTime() + KeepAwakePolicy.endMargin * 1000);
  },
};
