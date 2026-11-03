// La calculatrice et le grapheur du bureau (StudyKit/CalcPane.swift, `MathWorkbench` pur et
// testé) : ce qu'on allait chercher sur GeoGebra, sans quitter le mode étude. Une expression en
// x se trace, une équation se résout, les complexes et les matrices de MATH-111 se calculent.
// La session (définitions, historique) vit le temps de l'app.

import { useEffect, useMemo, useRef, useState } from "react";
import { MathWorkbench, MathSession, type MathOutput } from "../../../domain/mathWorkbench.ts";
import { MathEngine, type MathPoint } from "../../../domain/mathEngine.ts";
import { Icon } from "../../icons.tsx";
import { Kicker } from "../parts.tsx";

type Entry = { input: string; result: { ok: true; output: MathOutput } | { ok: false; message: string } };

/** Une session par app (comme `CalcModel` du bureau). */
const session = new MathSession();
const history: Entry[] = [];

const COLORS = ["var(--ink)", "var(--wrong)", "var(--correct)", "var(--review)", "#5B6CC9"];
const KEYS = ["π", "e", "√(", "^", "²", "!", "sin(", "cos(", "tan(", "ln(", "log(", "abs(", "(", ")", "x", "i"];
const EXAMPLES = ["x^3 - 2x", "x^2 = 2", "z^5 = 1", "(1+2i)/(3-i)", "A = [[1,2],[3,4]]", "inv(A)", "f'(1)", "int(f, 0, 2)"];

export function CalcPane({ openWeb }: { openWeb: (url: string) => void }) {
  const [line, setLine] = useState("");
  const [, bump] = useState(0);
  const [range, setRange] = useState<[number, number]>([-5, 5]);
  const input = useRef<HTMLInputElement | null>(null);
  const list = useRef<HTMLDivElement | null>(null);
  useEffect(() => { input.current?.focus(); }, []);
  useEffect(() => { list.current?.scrollTo({ top: list.current.scrollHeight }); }, [history.length]);

  const run = (text = line) => {
    const value = text.trim();
    if (!value) return;
    try {
      history.push({ input: value, result: { ok: true, output: MathWorkbench.run(value, session) } });
      setLine("");
    } catch (error) {
      history.push({ input: value, result: { ok: false, message: error instanceof Error ? error.message : String(error) } });
    }
    bump((n) => n + 1);
  };

  const names = [...session.engine.functions.entries()].filter(([, f]) => f.parameters.length === 1).map(([name]) => name).sort();
  return (
    <div style={{ display: "flex", height: "100%", minHeight: 0 }}>
      <section style={{ width: 420, flexShrink: 0, display: "flex", flexDirection: "column", borderRight: "1px solid var(--rule)", minHeight: 0 }}>
        <header style={{ display: "flex", alignItems: "center", gap: 10, padding: 16 }}>
          <span className="serif" style={{ fontSize: 20, flex: 1, color: "var(--ink)" }}>Calcul</span>
          <div className="seg" role="group" aria-label="Angles">
            <button type="button" aria-pressed={!session.engine.degrees} onClick={() => { session.engine.degrees = false; bump((n) => n + 1); }}>rad</button>
            <button type="button" aria-pressed={session.engine.degrees} onClick={() => { session.engine.degrees = true; bump((n) => n + 1); }}>deg</button>
          </div>
          <button type="button" className="icon-btn" title="GeoGebra" onClick={() => openWeb("https://www.geogebra.org/calculator")}>
            <Icon name="arrow.up.right.square" size={15} />
          </button>
        </header>
        <div ref={list} style={{ flex: 1, overflowY: "auto", minHeight: 0 }}>
          {history.length === 0 && (
            <div style={{ padding: 16, display: "flex", flexDirection: "column", gap: 8 }}>
              <span className="serif" style={{ fontSize: 16, color: "var(--ink)" }}>Comme sur papier</span>
              {EXAMPLES.map((sample) => (
                <button key={sample} type="button" className="link-btn mono" style={{ alignSelf: "flex-start", textDecoration: "none", fontSize: 13 }}
                  onClick={() => run(sample)}>{sample}</button>
              ))}
              <span style={{ fontSize: 12, color: "var(--ink-tertiary)" }}>Une expression en x se trace ; une équation se résout.</span>
            </div>
          )}
          {history.map((entry, index) => (
            <div key={index} onClick={() => { setLine(entry.input); input.current?.focus(); }}
              style={{ padding: "8px 16px", borderBottom: "1px solid var(--rule)", cursor: "pointer" }}>
              <div className="mono" style={{ color: "var(--ink-secondary)", fontSize: 13 }}>{entry.input}</div>
              <Result entry={entry} />
            </div>
          ))}
        </div>
        <div style={{ display: "grid", gridTemplateColumns: "repeat(8, 1fr)", gap: 6, padding: "8px 12px 0" }}>
          {KEYS.map((key) => (
            <button key={key} type="button" className="mono" onClick={() => { setLine(line + (key === "√(" ? "sqrt(" : key)); input.current?.focus(); }}
              style={{ minHeight: 28, borderRadius: 7, border: 0, background: "var(--sheet-raised)", color: "var(--ink)", cursor: "pointer", fontSize: 13 }}>
              {key.length > 1 ? key.replace("(", "") : key}
            </button>
          ))}
        </div>
        <form onSubmit={(event) => { event.preventDefault(); run(); }}
          style={{ display: "flex", alignItems: "center", gap: 8, margin: 12, padding: "8px 12px", borderRadius: 12, border: "1px solid var(--rule)", background: "var(--sheet)" }}>
          <span style={{ fontSize: 20, color: "var(--ink-tertiary)" }}>›</span>
          <input ref={input} className="mono" value={line} onChange={(event) => setLine(event.target.value)}
            placeholder="x^2 - 2, z^3 = i, det([[1,2],[3,4]])" aria-label="Calcul"
            style={{ flex: 1, border: 0, outline: "none", background: "transparent", color: "var(--ink)", fontSize: 17 }} />
        </form>
      </section>
      <section style={{ flex: 1, minWidth: 0, padding: 16, display: "flex", flexDirection: "column", gap: 12, overflowY: "auto" }}>
        <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
          <span className="serif" style={{ fontSize: 20, flex: 1, color: "var(--ink)" }}>Graphe</span>
          <button type="button" className="btn" title="Zoomer" onClick={() => setRange(zoom(range, 0.5))}>+</button>
          <button type="button" className="btn" title="Dézoomer" onClick={() => setRange(zoom(range, 2))}>−</button>
          <button type="button" className="btn" title="Gauche" onClick={() => setRange(shift(range, -0.25))}><Icon name="chevron.left" size={13} /></button>
          <button type="button" className="btn" title="Droite" onClick={() => setRange(shift(range, 0.25))}><Icon name="chevron.right" size={13} /></button>
          <button type="button" className="btn" onClick={() => setRange([-5, 5])}>−5…5</button>
        </div>
        {names.length === 0 ? (
          <div className="bf-center" style={{ height: 380 }}>
            <Icon name="function" size={26} />
            <span>Aucune fonction — essaie <span className="mono">f(x) = x^2 - 2</span></span>
          </div>
        ) : (
          <>
            <Graph names={names} range={range} />
            <div style={{ display: "flex", gap: 14, flexWrap: "wrap" }}>
              {names.map((name, index) => (
                <span key={name} style={{ display: "inline-flex", alignItems: "center", gap: 6, fontSize: 13 }}>
                  <span style={{ width: 14, height: 3, borderRadius: 2, background: COLORS[index % COLORS.length] }} />
                  <span className="mono">{name}({session.engine.functions.get(name)?.parameters[0] ?? "x"})</span>
                  <button type="button" className="icon-btn" title="Retirer" onClick={() => { session.engine.functions.delete(name); bump((n) => n + 1); }}>
                    <Icon name="xmark" size={11} />
                  </button>
                </span>
              ))}
            </div>
          </>
        )}
        <Kicker>{MathEngine.format(range[0])} à {MathEngine.format(range[1])}</Kicker>
      </section>
    </div>
  );
}

function zoom([a, b]: [number, number], factor: number): [number, number] {
  const mid = (a + b) / 2;
  const half = ((b - a) / 2) * factor;
  return [mid - half, mid + half];
}

function shift([a, b]: [number, number], fraction: number): [number, number] {
  const delta = (b - a) * fraction;
  return [a + delta, b + delta];
}

function Result({ entry }: { entry: Entry }) {
  const big = { fontSize: 22, color: "var(--ink)", userSelect: "text" as const };
  if (!entry.result.ok) return <div style={{ color: "var(--wrong)", fontSize: 13 }}>{entry.result.message}</div>;
  const output = entry.result.output;
  switch (output.kind) {
    case "value": return <div className="mono" style={big}>= {output.value}</div>;
    case "plotted": return <div style={{ fontSize: 13, color: "var(--ink)" }}>{output.definition} — tracée</div>;
    case "defined": return <div style={{ fontSize: 13, color: "var(--ink-secondary)" }}>{output.text}</div>;
    case "complex":
      return <div><div className="mono" style={big}>= {output.value}</div><div className="mono" style={{ fontSize: 13, color: "var(--ink-secondary)" }}>{output.polar}</div></div>;
    case "solutions":
      return <div>{output.roots.map((root, i) => <div key={i} className="mono" style={{ fontSize: 17, color: "var(--ink)" }}>{output.variable} = {root}</div>)}</div>;
    case "matrix":
      return (
        <table className="mono" style={{ borderLeft: "1.5px solid var(--ink)", borderRight: "1.5px solid var(--ink)", borderCollapse: "separate", borderSpacing: "14px 4px", fontSize: 17, color: "var(--ink)" }}>
          <tbody>{output.rows.map((row, r) => <tr key={r}>{row.map((cell, c) => <td key={c} style={{ textAlign: "right" }}>{cell}</td>)}</tr>)}</tbody>
        </table>
      );
  }
}

/** Le tracé : des morceaux continus (coupés aux asymptotes), les racines marquées. */
function Graph({ names, range }: { names: string[]; range: [number, number] }) {
  const width = 800;
  const height = 420;
  const [a, b] = range;
  const data = useMemo(() => names.map((name) => ({
    name,
    points: MathEngine.sample(name, a, b, 400, session.engine),
    roots: MathEngine.roots(name, a, b, session.engine),
  })), [names.join(), a, b, session.engine.degrees]);
  const values = data.flatMap((d) => d.points.map((p) => p.y)).sort((x, y) => x - y);
  let low = -5;
  let high = 5;
  if (values.length > 4) {
    const lo = values[Math.floor(values.length * 0.02)];
    const hi = values[Math.floor(values.length * 0.98)];
    const pad = Math.max(0.5, (hi - lo) * 0.1);
    low = Math.min(lo, 0) - pad;
    high = Math.max(hi, 0) + pad;
  }
  const X = (x: number) => ((x - a) / (b - a)) * width;
  const Y = (y: number) => height - ((y - low) / (high - low)) * height;
  const step = (b - a) / 399;
  const segments = (points: MathPoint[]) => {
    const out: MathPoint[][] = [];
    let current: MathPoint[] = [];
    for (const point of points) {
      const last = current[current.length - 1];
      if (last && (point.x - last.x > step * 1.5 || Math.abs(point.y - last.y) > 1e4)) {
        if (current.length > 1) out.push(current);
        current = [];
      }
      current.push(point);
    }
    if (current.length > 1) out.push(current);
    return out;
  };
  const ticks = (from: number, to: number) => {
    const span = to - from;
    const raw = span / 8;
    const magnitude = 10 ** Math.floor(Math.log10(raw));
    const unit = [1, 2, 5, 10].map((m) => m * magnitude).find((m) => m >= raw) ?? raw;
    const out: number[] = [];
    for (let t = Math.ceil(from / unit) * unit; t <= to; t += unit) out.push(Math.round(t / unit) * unit);
    return out;
  };
  return (
    <svg viewBox={`0 0 ${width} ${height}`} style={{ width: "100%", height: "auto", border: "1px solid var(--rule)", borderRadius: 12, background: "var(--sheet)" }}>
      {ticks(a, b).map((t) => <g key={`x${t}`}><line x1={X(t)} x2={X(t)} y1={0} y2={height} stroke="var(--rule)" /><text x={X(t) + 3} y={height - 4} fontSize={11} fill="var(--ink-tertiary)">{MathEngine.format(t)}</text></g>)}
      {ticks(low, high).map((t) => <g key={`y${t}`}><line x1={0} x2={width} y1={Y(t)} y2={Y(t)} stroke="var(--rule)" /><text x={4} y={Y(t) - 3} fontSize={11} fill="var(--ink-tertiary)">{MathEngine.format(t)}</text></g>)}
      {a < 0 && b > 0 && <line x1={X(0)} x2={X(0)} y1={0} y2={height} stroke="var(--ink-tertiary)" />}
      {low < 0 && high > 0 && <line x1={0} x2={width} y1={Y(0)} y2={Y(0)} stroke="var(--ink-tertiary)" />}
      {data.map((d, index) => (
        <g key={d.name} stroke={COLORS[index % COLORS.length]} fill="none" strokeWidth={2}>
          {segments(d.points).map((segment, s) => (
            <polyline key={s} points={segment.map((p) => `${X(p.x).toFixed(1)},${Y(Math.max(low - 1e3, Math.min(high + 1e3, p.y))).toFixed(1)}`).join(" ")} />
          ))}
          {d.roots.map((root) => (
            <g key={root}>
              <circle cx={X(root)} cy={Y(0)} r={4} fill={COLORS[index % COLORS.length]} stroke="none" />
              <text x={X(root) + 5} y={Y(0) - 7} fontSize={11} fill="var(--ink-secondary)" stroke="none">{MathEngine.format(Math.round(root * 1000) / 1000)}</text>
            </g>
          ))}
        </g>
      ))}
    </svg>
  );
}
