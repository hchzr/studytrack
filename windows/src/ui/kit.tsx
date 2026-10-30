// Petites briques d'interface partagées par les écrans, dans la langue visuelle
// « Carnet » (tokens.css). On évite de réinventer un titre ou une carte partout.

import type { ReactNode } from "react";

/** En-tête de page : grand titre serif + sous-titre optionnel. */
export function PageHeader({ title, subtitle, actions }:
  { title: string; subtitle?: string; actions?: ReactNode }) {
  return (
    <header style={{ display: "flex", alignItems: "baseline", justifyContent: "space-between", marginBottom: 24, gap: 16 }}>
      <div>
        <h1 className="serif" style={{ fontSize: 30, margin: 0 }}>{title}</h1>
        {subtitle && <p style={{ margin: "4px 0 0", color: "var(--ink-secondary)" }}>{subtitle}</p>}
      </div>
      {actions}
    </header>
  );
}

export function Section({ title, children }: { title?: string; children: ReactNode }) {
  return (
    <section style={{ marginBottom: 28 }}>
      {title && <h2 style={{ fontSize: 13, textTransform: "uppercase", letterSpacing: 0.6,
        color: "var(--ink-tertiary)", margin: "0 0 10px" }}>{title}</h2>}
      {children}
    </section>
  );
}

export function Card({ children, accent }: { children: ReactNode; accent?: string }) {
  return (
    <div className="card" style={accent ? { borderLeft: `3px solid ${accent}` } : undefined}>{children}</div>
  );
}

/** Un bandeau pour un écran encore à faire : indique quoi porter et d'où. */
export function Placeholder({ screen, from }: { screen: string; from: string }) {
  return (
    <div className="card" style={{ color: "var(--ink-secondary)" }}>
      <strong>{screen}</strong> — à porter depuis <code className="mono">{from}</code>.
    </div>
  );
}

export const CONFIDENCE_COLOR: Record<string, string> = {
  high: "var(--correct)", medium: "var(--review)", low: "var(--wrong)",
};
