// Les briques propres au bilan : la feuille titrée (comme `CarnetSectionTitle`)
// et les légendes de graphique. Boutons, pastilles et segments viennent du kit.

import type { CSSProperties, ReactNode } from "react";
import { cx } from "../../kit.tsx";
import "./stats.css";

/** Une feuille du bilan : titre minuscule, accessoire à droite, contenu dessous. */
export function StatCard({ title, accessory, children, style }: {
  title: string;
  accessory?: ReactNode;
  children: ReactNode;
  style?: CSSProperties;
}) {
  return (
    <section style={{ minWidth: 0, ...style }}>
      <div className="stat-card-head">
        <h2 className="caps" style={{ margin: 0 }}>{title}</h2>
        {accessory && <div className="acc">{accessory}</div>}
      </div>
      <div className="card" style={{ padding: 16, minWidth: 0 }}>
        {children}
      </div>
    </section>
  );
}

/** Une pastille de légende : carré de couleur, nom, valeur mono. */
export function LegendChip({ color, opacity = 1, label, value, dimmed = false }: {
  color: string;
  opacity?: number;
  label: string;
  value?: string;
  dimmed?: boolean;
}) {
  return (
    <span className={cx("legend-chip", dimmed && "dim")}>
      <span className="sw" style={{ background: color, opacity }} />
      <span style={{ whiteSpace: "nowrap" }}>{label}</span>
      {value && <span className="mono muted">{value}</span>}
    </span>
  );
}

/** Une pastille ronde de légende (camembert des matières). */
export function LegendDot({ color, label, value, dimmed = false }: {
  color: string;
  label: string;
  value?: string;
  dimmed?: boolean;
}) {
  return (
    <div className={cx("legend-row", dimmed && "dim")}>
      <span className="dot" style={{ background: color }} />
      <span className="name">{label}</span>
      <span className="spacer" />
      {value && <span className="mono muted" style={{ flexShrink: 0 }}>{value}</span>}
    </div>
  );
}
