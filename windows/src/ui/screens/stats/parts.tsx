// Les briques propres au bilan : la feuille titrée (comme `CarnetSectionTitle`),
// les pastilles de période, les flèches de semaine et les légendes de graphique.

import type { CSSProperties, ReactNode } from "react";

/** Une feuille du bilan : titre minuscule, accessoire à droite, contenu dessous. */
export function StatCard({ title, accessory, children, style }: {
  title: string;
  accessory?: ReactNode;
  children: ReactNode;
  style?: CSSProperties;
}) {
  return (
    <section style={{ minWidth: 0, ...style }}>
      <div style={{
        display: "flex", alignItems: "baseline", justifyContent: "space-between",
        gap: 12, marginBottom: 10, minHeight: 18,
      }}>
        <h2 style={{
          fontSize: 13, textTransform: "uppercase", letterSpacing: 0.6,
          color: "var(--ink-tertiary)", margin: 0,
        }}>
          {title}
        </h2>
        {accessory && (
          <div style={{ fontSize: 13, color: "var(--ink-secondary)", textAlign: "right", minWidth: 0 }}>
            {accessory}
          </div>
        )}
      </div>
      <div className="card" style={{ padding: 16, minWidth: 0 }}>
        {children}
      </div>
    </section>
  );
}

export function Chip({ label, selected, onClick }: {
  label: string;
  selected: boolean;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      className="stats-chip"
      aria-pressed={selected}
      onClick={onClick}
      style={{
        padding: "5px 12px", borderRadius: 999, fontSize: 13,
        border: "1px solid " + (selected ? "var(--ink)" : "var(--rule)"),
        background: selected ? "var(--ink)" : "var(--sheet)",
        color: selected ? "var(--sheet)" : "var(--ink)",
        cursor: "pointer",
      }}
    >
      {label}
    </button>
  );
}

export function RoundButton({ label, children, onClick, disabled = false }: {
  label: string;
  children: ReactNode;
  onClick: () => void;
  disabled?: boolean;
}) {
  return (
    <button
      type="button"
      className="stats-round"
      title={label}
      aria-label={label}
      onClick={onClick}
      disabled={disabled}
      style={{
        width: 34, height: 32, display: "grid", placeItems: "center",
        borderRadius: 10, border: "1px solid var(--rule)", background: "var(--sheet)",
        color: "var(--ink)", fontSize: 15,
        opacity: disabled ? 0.35 : 1, cursor: disabled ? "default" : "pointer",
      }}
    >
      {children}
    </button>
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
    <span style={{
      display: "inline-flex", alignItems: "center", gap: 5, fontSize: 12,
      opacity: dimmed ? 0.45 : 1, minWidth: 0,
    }}>
      <span style={{
        width: 10, height: 10, borderRadius: 2, background: color,
        opacity, flexShrink: 0,
      }} />
      <span style={{ color: "var(--ink)", whiteSpace: "nowrap" }}>{label}</span>
      {value && <span className="mono" style={{ color: "var(--ink-secondary)" }}>{value}</span>}
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
    <div style={{
      display: "flex", alignItems: "center", gap: 6, fontSize: 12,
      opacity: dimmed ? 0.45 : 1, minWidth: 0,
    }}>
      <span style={{ width: 9, height: 9, borderRadius: "50%", background: color, flexShrink: 0 }} />
      <span style={{ color: "var(--ink)", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
        {label}
      </span>
      <span style={{ flex: 1 }} />
      {value && <span className="mono" style={{ color: "var(--ink-secondary)", flexShrink: 0 }}>{value}</span>}
    </div>
  );
}
