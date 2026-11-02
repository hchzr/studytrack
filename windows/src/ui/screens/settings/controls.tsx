// Les briques propres à l'écran Réglages. Interrupteurs, pas-à-pas, segments,
// menus et boutons viennent du kit : ici ne reste que la ligne de formulaire
// et le chiffre du récapitulatif.

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

/** Un chiffre mis en avant dans le récapitulatif des cours. */
export function Stat({ value, label }: { value: number | string; label: string }) {
  return (
    <div className="settings-stat">
      <strong className="mono">{value}</strong>
      <span>{label}</span>
    </div>
  );
}
