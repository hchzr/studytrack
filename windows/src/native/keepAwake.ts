// Garder la machine éveillée pendant le mode étude (MacKeepAwake). La décision
// est `KeepAwakePolicy.hold` (domaine, testé) ; ici on la nourrit avec le
// chrono et on la transmet à Rust (SetThreadExecutionState).
//
// Aucun battement : on se réévalue à chaque changement du chrono, et un seul
// minuteur est posé avant l'échéance du bail pour le renouveler.

import { NATIVE_SETTINGS_EVENT } from "./settings.ts";
import {
  KeepAwakePolicy,
  type KeepAwakeMode,
  type KeepAwakePower,
} from "../domain/keepAwakePolicy.ts";
import { callNative } from "./tauri.ts";

/** Ce que le chrono doit dire pour décider. */
export interface KeepAwakeSource {
  studying: boolean;
  /** Le temps de travail compte. */
  running: boolean;
  /** Une pause Pomodoro décompte. */
  onBreak: boolean;
  /** Fin prévue du mode étude ; `null` : session sans fin. */
  until: Date | null;
}

export interface KeepAwakePlan {
  mode: "off" | "system" | "display";
  /** Le bail en secondes (sans objet quand `off`). */
  leaseSeconds: number;
}

/** La décision, pure. */
export function planKeepAwake(
  mode: KeepAwakeMode,
  source: KeepAwakeSource,
  power: KeepAwakePower,
  now: Date,
): KeepAwakePlan {
  const hold = KeepAwakePolicy.hold({
    mode, studying: source.studying, running: source.running, onBreak: source.onBreak, power,
  });
  if (hold === null) return { mode: "off", leaseSeconds: 0 };
  const expiry = KeepAwakePolicy.expiry(source.until, now);
  return { mode: hold, leaseSeconds: Math.max(60, Math.ceil((expiry.getTime() - now.getTime()) / 1000)) };
}

/** Faut-il (re)parler à Rust ? Même tenue et même échéance (à la minute) : non. */
export function needsUpdate(
  previous: { mode: string; expiryMs: number } | null,
  next: KeepAwakePlan,
  nowMs: number,
): boolean {
  if (!previous) return next.mode !== "off";
  if (previous.mode !== next.mode) return true;
  if (next.mode === "off") return false;
  return Math.abs(previous.expiryMs - (nowMs + next.leaseSeconds * 1000)) >= 60_000;
}

/** L'alimentation, quand le moteur web la donne (batterie) ; sinon « sur secteur ». */
export async function readPower(): Promise<KeepAwakePower> {
  try {
    const nav = navigator as Navigator & {
      getBattery?: () => Promise<{ charging: boolean; level: number }>;
    };
    const battery = await nav.getBattery?.();
    if (battery) return KeepAwakePolicy.power({ onBattery: !battery.charging, batteryLevel: battery.level });
  } catch {
    // pas de batterie lisible
  }
  return KeepAwakePolicy.plugged;
}

/** Ce que `startKeepAwake` lit du contrôleur de chrono. */
export interface KeepAwakeTimer {
  subscribe(listener: () => void): () => void;
  source(): KeepAwakeSource;
}

export function startKeepAwake(
  timer: KeepAwakeTimer,
  readMode: () => KeepAwakeMode,
  send: (plan: KeepAwakePlan) => void | Promise<unknown> = (plan) =>
    callNative("set_keep_awake", { mode: plan.mode, leaseSeconds: plan.leaseSeconds }),
  now: () => Date = () => new Date(),
  power: () => Promise<KeepAwakePower> = readPower,
): () => void {
  let held: { mode: string; expiryMs: number } | null = null;
  let renewal: ReturnType<typeof setTimeout> | null = null;
  let sequence = 0;
  let stopped = false;

  const evaluate = async () => {
    const mine = ++sequence;
    const mode = readMode();
    const source = timer.source();
    // L'alimentation ne se lit que si elle peut changer la décision.
    const level = mode === "display" && source.studying ? await power() : KeepAwakePolicy.plugged;
    if (stopped || mine !== sequence) return;
    const at = now();
    const plan = planKeepAwake(mode, source, level, at);
    if (renewal) clearTimeout(renewal);
    renewal = null;
    if (plan.mode !== "off") {
      // Un seul réveil, juste avant l'échéance du bail.
      renewal = setTimeout(() => void evaluate(), Math.max(30, plan.leaseSeconds - 60) * 1000);
    }
    if (!needsUpdate(held, plan, at.getTime())) return;
    held = plan.mode === "off" ? null : { mode: plan.mode, expiryMs: at.getTime() + plan.leaseSeconds * 1000 };
    await send(plan);
  };

  const unsubscribe = timer.subscribe(() => void evaluate());
  // Un changement dans Réglages › Chrono s'applique à la session en cours.
  const onSettings = () => void evaluate();
  globalThis.addEventListener?.(NATIVE_SETTINGS_EVENT, onSettings);
  void evaluate();
  return () => {
    stopped = true;
    unsubscribe();
    globalThis.removeEventListener?.(NATIVE_SETTINGS_EVENT, onSettings);
    if (renewal) clearTimeout(renewal);
    if (held) void send({ mode: "off", leaseSeconds: 0 });
  };
}
