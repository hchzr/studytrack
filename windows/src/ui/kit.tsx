// Petites briques d'interface partagées par les écrans, dans la langue visuelle
// « Carnet » (tokens.css + kit.css). Un écran compose avec elles et ne
// réinvente ni titre, ni carte, ni bouton, ni menu — c'est ce qui donne à
// l'app une seule main. Les styles vivent dans kit.css ; ici, le comportement
// et l'accessibilité (rôles, clavier, focus).

import {
  useCallback, useEffect, useLayoutEffect, useRef, useState,
  type ButtonHTMLAttributes, type CSSProperties, type MouseEvent as ReactMouseEvent, type ReactNode,
} from "react";
import { createPortal } from "react-dom";
import { Check, Minus, Plus } from "lucide-react";
import { Icon, type IconName } from "./icons.tsx";

export { Icon, type IconName } from "./icons.tsx";

/** Des classes conditionnelles : `cx("btn", primary && "btn-primary")`. */
export function cx(...parts: (string | false | null | undefined)[]): string {
  return parts.filter(Boolean).join(" ");
}

// MARK: Mise en page

/** En-tête de page : grand titre serif + sous-titre optionnel, actions à droite. */
export function PageHeader({ title, subtitle, actions }:
  { title: ReactNode; subtitle?: ReactNode; actions?: ReactNode }) {
  return (
    <header style={{ display: "flex", alignItems: "flex-end", justifyContent: "space-between", marginBottom: 24, gap: 16 }}>
      <div style={{ minWidth: 0 }}>
        <h1 className="serif" style={{ fontSize: 30, margin: 0, lineHeight: 1.15 }}>{title}</h1>
        {subtitle && <p style={{ margin: "4px 0 0", color: "var(--ink-secondary)" }}>{subtitle}</p>}
      </div>
      {actions && <div className="hstack" style={{ flexShrink: 0 }}>{actions}</div>}
    </header>
  );
}

/** Une section titrée en petites capitales, avec une action optionnelle à droite. */
export function Section({ title, action, children, style }:
  { title?: ReactNode; action?: ReactNode; children: ReactNode; style?: CSSProperties }) {
  return (
    <section style={{ marginBottom: 28, ...style }}>
      {(title || action) && (
        <div className="hstack" style={{ margin: "0 2px 10px", minHeight: 20 }}>
          {title && <h2 className="caps" style={{ margin: 0 }}>{title}</h2>}
          <span className="spacer" />
          {action}
        </div>
      )}
      {children}
    </section>
  );
}

export function Card({ children, accent, flat, onClick, style, className }: {
  children: ReactNode; accent?: string; flat?: boolean; onClick?: () => void;
  style?: CSSProperties; className?: string;
}) {
  return (
    <div className={cx("card", flat && "flat", onClick && "interactive", className)}
      style={{ ...(accent ? { borderLeft: `3px solid ${accent}` } : null), ...style }}
      onClick={onClick}
      role={onClick ? "button" : undefined}
      tabIndex={onClick ? 0 : undefined}
      onKeyDown={onClick ? (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); onClick(); } } : undefined}>
      {children}
    </div>
  );
}

/** L'équivalent de `ContentUnavailableView` : une icône, un titre, une phrase, une action. */
export function EmptyState({ icon, title, children, action }:
  { icon?: IconName; title: ReactNode; children?: ReactNode; action?: ReactNode }) {
  return (
    <div className="empty">
      {icon && <Icon name={icon} size={30} strokeWidth={1.5} className="empty-icon" />}
      <h3>{title}</h3>
      {children && <p>{children}</p>}
      {action && <div style={{ marginTop: 8 }}>{action}</div>}
    </div>
  );
}

/** Une barre d'avancement fine, couleur du cours ou de l'encre. */
export function ProgressBar({ value, color, height }: { value: number; color?: string; height?: number }) {
  const pct = Math.max(0, Math.min(1, Number.isFinite(value) ? value : 0)) * 100;
  return (
    <div className="progress" style={height ? { height } : undefined} role="progressbar"
      aria-valuenow={Math.round(pct)} aria-valuemin={0} aria-valuemax={100}>
      <span style={{ width: `${pct}%`, background: color }} />
    </div>
  );
}

export function Badge({ children, tone }: { children: ReactNode; tone?: "correct" | "review" | "wrong" }) {
  return <span className={cx("badge", tone)}>{children}</span>;
}

// MARK: Boutons

type ButtonProps = ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: "default" | "primary" | "ghost" | "danger";
  size?: "sm" | "md" | "lg";
  icon?: IconName;
  trailingIcon?: IconName;
};

export function Button({ variant = "default", size = "md", icon, trailingIcon, className, children, type, ...rest }: ButtonProps) {
  const iconSize = size === "sm" ? 13 : 15;
  return (
    <button type={type ?? "button"} {...rest}
      className={cx("btn", variant !== "default" && `btn-${variant}`, size !== "md" && `btn-${size}`, className)}>
      {icon && <Icon name={icon} size={iconSize} />}
      {children}
      {trailingIcon && <Icon name={trailingIcon} size={iconSize} />}
    </button>
  );
}

/** Un bouton d'icône seule : `label` sert d'infobulle et de nom accessible. */
export function IconButton({ icon, label, size = "md", bordered, className, ...rest }:
  ButtonHTMLAttributes<HTMLButtonElement> & { icon: IconName; label: string; size?: "sm" | "md"; bordered?: boolean }) {
  return (
    <button type="button" title={label} aria-label={label} {...rest}
      className={cx("icon-btn", size === "sm" && "sm", bordered && "bordered", className)}>
      <Icon name={icon} size={size === "sm" ? 14 : 16} />
    </button>
  );
}

/** Une pastille à bascule (filtre, choix d'un cours). */
export function Chip({ selected, onClick, dot, icon, children, disabled }: {
  selected?: boolean; onClick?: () => void; dot?: string; icon?: IconName; children: ReactNode; disabled?: boolean;
}) {
  return (
    <button type="button" className="chip" aria-pressed={selected ?? false} onClick={onClick} disabled={disabled}>
      {dot && <span className="dot" style={{ background: dot }} />}
      {icon && <Icon name={icon} size={13} />}
      {children}
    </button>
  );
}

/** Un choix exclusif en pilule (le `Picker(.segmented)` du Swift). */
export function Segmented<T extends string | number>({ value, options, onChange, ariaLabel }: {
  value: T; options: { value: T; label: ReactNode }[]; onChange: (value: T) => void; ariaLabel?: string;
}) {
  return (
    <div className="seg" role="group" aria-label={ariaLabel}>
      {options.map((o) => (
        <button key={String(o.value)} type="button" aria-pressed={o.value === value} onClick={() => onChange(o.value)}>
          {o.label}
        </button>
      ))}
    </div>
  );
}

// MARK: Champs

export function Switch({ checked, onChange, label, ariaLabel, disabled }:
  { checked: boolean; onChange: (value: boolean) => void; label?: ReactNode; ariaLabel?: string; disabled?: boolean }) {
  return (
    <label className="switch">
      <input type="checkbox" role="switch" checked={checked} disabled={disabled}
        aria-label={ariaLabel ?? (typeof label === "string" ? label : undefined)}
        onChange={(e) => onChange(e.target.checked)} />
      <span className="switch-track" aria-hidden="true"><span className="switch-thumb" /></span>
      {label && <span style={{ fontSize: 13 }}>{label}</span>}
    </label>
  );
}

/** Une case à cocher habillée, avec un libellé et une précision optionnelle. */
export function Checkbox({ checked, onChange, label, hint, disabled, ariaLabel }: {
  checked: boolean; onChange: (value: boolean) => void; label?: ReactNode; hint?: ReactNode;
  disabled?: boolean; ariaLabel?: string;
}) {
  return (
    <label className="check" style={disabled ? { opacity: 0.5, cursor: "default" } : undefined}>
      <input type="checkbox" checked={checked} disabled={disabled} aria-label={ariaLabel}
        onChange={(e) => onChange(e.target.checked)} />
      <span className="check-box" aria-hidden="true"><Check size={12} strokeWidth={3} /></span>
      {(label || hint) && (
        <span className="check-text">{label && <span>{label}</span>}{hint && <small>{hint}</small>}</span>
      )}
    </label>
  );
}

/** Un menu déroulant natif (clavier et lecteur d'écran gratuits), habillé. */
export function Select<T extends string>({ value, options, onChange, ariaLabel, style, disabled }: {
  value: T; options: { value: T; label: string }[]; onChange: (value: T) => void;
  ariaLabel?: string; style?: CSSProperties; disabled?: boolean;
}) {
  return (
    <select className="select" value={value} aria-label={ariaLabel} style={style} disabled={disabled}
      onChange={(e) => onChange(e.target.value as T)}>
      {options.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
    </select>
  );
}

/** Un pas-à-pas numérique, borné. */
export function Stepper({ value, min, max, step = 1, onChange, label, format }: {
  value: number; min: number; max: number; step?: number; onChange: (value: number) => void;
  label: string; format?: (value: number) => string;
}) {
  const clamp = (next: number) => Math.min(max, Math.max(min, next));
  return (
    <div className="stepper" role="group" aria-label={label}>
      <button type="button" onClick={() => onChange(clamp(value - step))} disabled={value <= min}
        aria-label={`Diminuer ${label}`}><Minus size={13} /></button>
      <span className="stepper-value mono" aria-live="polite">{format ? format(value) : value}</span>
      <button type="button" onClick={() => onChange(clamp(value + step))} disabled={value >= max}
        aria-label={`Augmenter ${label}`}><Plus size={13} /></button>
    </div>
  );
}

// MARK: Menu contextuel

export type MenuItem =
  | { label: string; icon?: IconName; danger?: boolean; disabled?: boolean; action: () => void }
  | "divider";

/**
 * Le `.contextMenu` du Swift : `const menu = useContextMenu();` puis
 * `onContextMenu={menu.open(items)}` sur l'élément, et `{menu.element}` dans le rendu.
 * Se ferme au clic dehors, à Échap, au défilement ; flèches haut/bas au clavier.
 */
export function useContextMenu() {
  const [state, setState] = useState<{ x: number; y: number; items: MenuItem[] } | null>(null);
  const close = useCallback(() => setState(null), []);
  const open = useCallback((items: MenuItem[]) => (e: ReactMouseEvent) => {
    e.preventDefault();
    setState({ x: e.clientX, y: e.clientY, items });
  }, []);
  const openAt = useCallback((x: number, y: number, items: MenuItem[]) => setState({ x, y, items }), []);
  const element = state ? <ContextMenu {...state} onClose={close} /> : null;
  return { open, openAt, close, element };
}

function ContextMenu({ x, y, items, onClose }: { x: number; y: number; items: MenuItem[]; onClose: () => void }) {
  const ref = useRef<HTMLDivElement>(null);
  const [pos, setPos] = useState({ left: x, top: y });

  // Gardé dans la fenêtre : retourné vers la gauche/le haut près du bord.
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const r = el.getBoundingClientRect();
    setPos({
      left: x + r.width > window.innerWidth - 8 ? Math.max(8, x - r.width) : x,
      top: y + r.height > window.innerHeight - 8 ? Math.max(8, y - r.height) : y,
    });
    el.querySelector<HTMLButtonElement>("button:not(:disabled)")?.focus();
  }, [x, y]);

  useEffect(() => {
    const down = (e: MouseEvent) => { if (!ref.current?.contains(e.target as Node)) onClose(); };
    const key = (e: KeyboardEvent) => {
      if (e.key === "Escape") { onClose(); return; }
      if (e.key !== "ArrowDown" && e.key !== "ArrowUp") return;
      e.preventDefault();
      const buttons = [...(ref.current?.querySelectorAll<HTMLButtonElement>("button:not(:disabled)") ?? [])];
      const i = buttons.indexOf(document.activeElement as HTMLButtonElement);
      const next = e.key === "ArrowDown" ? (i + 1) % buttons.length : (i - 1 + buttons.length) % buttons.length;
      buttons[next]?.focus();
    };
    window.addEventListener("mousedown", down);
    window.addEventListener("keydown", key);
    window.addEventListener("blur", onClose);
    window.addEventListener("wheel", onClose, { passive: true });
    return () => {
      window.removeEventListener("mousedown", down);
      window.removeEventListener("keydown", key);
      window.removeEventListener("blur", onClose);
      window.removeEventListener("wheel", onClose);
    };
  }, [onClose]);

  return createPortal(
    <div ref={ref} className="menu" role="menu" style={pos}>
      {items.map((item, i) => item === "divider"
        ? <hr key={i} />
        : (
          <button key={i} type="button" role="menuitem" disabled={item.disabled}
            className={item.danger ? "danger" : undefined}
            onClick={() => { onClose(); item.action(); }}>
            {item.icon && <Icon name={item.icon} size={14} />}
            {item.label}
          </button>
        ))}
    </div>,
    document.body,
  );
}

// MARK: Couleurs partagées

export const CONFIDENCE_COLOR: Record<string, string> = {
  high: "var(--correct)", medium: "var(--review)", low: "var(--wrong)",
};
