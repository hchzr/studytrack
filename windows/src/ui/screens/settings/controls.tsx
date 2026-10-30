// Les petites briques de formulaire de l'écran Réglages. Elles restent dans le
// dossier de l'écran : aucun autre écran n'a besoin de cette forme-là.

import type { ReactNode } from "react";

/** Une ligne « libellé à gauche, contrôle à droite », séparée par un filet. */
export function SettingRow({ label, hint, children }:
  { label: ReactNode; hint?: ReactNode; children?: ReactNode }) {
  return (
    <div className="settings-row">
      <div className="settings-row-text">
        <div className="settings-label">{label}</div>
        {hint && <p className="settings-hint">{hint}</p>}
      </div>
      {children && <div className="settings-control">{children}</div>}
    </div>
  );
}

/** Un interrupteur accessible (la case native, habillée en pastille). */
export function Switch({ checked, onChange, label, ariaLabel, disabled }:
  { checked: boolean; onChange: (value: boolean) => void; label?: string; ariaLabel?: string; disabled?: boolean }) {
  return (
    <label className="settings-switch">
      <input
        type="checkbox"
        checked={checked}
        disabled={disabled}
        aria-label={ariaLabel ?? label}
        onChange={(event) => onChange(event.target.checked)}
      />
      <span className="settings-switch-track" aria-hidden="true">
        <span className="settings-switch-thumb" />
      </span>
      {label && <span className="settings-switch-label">{label}</span>}
    </label>
  );
}

/** Un pas-à-pas numérique, borné, avec deux boutons explicites. */
export function Stepper({ value, min, max, step = 1, onChange, label, format }:
  {
    value: number;
    min: number;
    max: number;
    step?: number;
    onChange: (value: number) => void;
    label: string;
    format?: (value: number) => string;
  }) {
  const clamp = (next: number) => Math.min(max, Math.max(min, next));
  return (
    <div className="settings-stepper" role="group" aria-label={label}>
      <button type="button" onClick={() => onChange(clamp(value - step))}
        disabled={value <= min} aria-label={`Diminuer ${label}`}>−</button>
      <span className="settings-stepper-value mono" aria-live="polite">{format ? format(value) : value}</span>
      <button type="button" onClick={() => onChange(clamp(value + step))}
        disabled={value >= max} aria-label={`Augmenter ${label}`}>+</button>
    </div>
  );
}

/** Un chiffre mis en avant dans le récapitulatif des cours. */
export function Stat({ value, label }: { value: number | string; label: string }) {
  return (
    <div className="settings-stat">
      <strong className="mono">{value}</strong>
      <span>{label}</span>
    </div>
  );
}
