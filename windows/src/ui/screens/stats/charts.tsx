// Les graphiques du bilan, en SVG — pas de bibliothèque : une barre empilée,
// des camemberts, une ligne par série et des barres « fait / prévu ».
//
// Les formes suivent Swift Charts de près : mêmes couleurs, mêmes opacités de
// sélection, même règle pointillée pour la moyenne, même barre-repère pour le
// prévu. Le clic remplace le glissement du doigt.

import { useId, useLayoutEffect, useRef, useState } from "react";
import type { PointerEvent as ReactPointerEvent, ReactNode, RefObject } from "react";
import { createPortal } from "react-dom";
import { DateUtils } from "../../../domain/dateUtils.ts";
import type { CategoryStyle } from "./statsData.ts";
import "./stats.css";

// MARK: - Infobulle au survol

/**
 * L'infobulle des graphiques : le Mac montre la valeur sous le doigt (la
 * sélection de Swift Charts) ; ici le survol la remplace, le clic épingle
 * toujours. Portée dans `body` pour ne jamais être rognée par une carte.
 */
function useTip() {
  const [tip, setTip] = useState<{ x: number; y: number; content: ReactNode } | null>(null);
  const show = (content: ReactNode) => (event: ReactPointerEvent) =>
    setTip({ x: event.clientX, y: event.clientY, content });
  const hide = (): void => setTip(null);
  const element = tip
    ? createPortal(
      <div className="chart-tip" style={{
        left: Math.min(tip.x + 14, window.innerWidth - 240), top: tip.y + 16,
      }}>
        {tip.content}
      </div>,
      document.body,
    )
    : null;
  return { show, hide, element };
}

function TipRow({ color, opacity = 1, label, value }: { color?: string; opacity?: number; label: string; value: string }) {
  return (
    <div className="chart-tip-row">
      {color && <span className="sw" style={{ background: color, opacity }} />}
      <span>{label}</span>
      <b className="mono">{value}</b>
    </div>
  );
}

function pct(part: number, total: number): string {
  return total <= 0 ? "0 %" : `${Math.round((part / total) * 100)} %`;
}

// MARK: - Échelles

interface Scale {
  max: number;
  ticks: number[];
}

function niceStep(rough: number): number {
  const power = Math.pow(10, Math.floor(Math.log10(rough)));
  const normalized = rough / power;
  const step = normalized <= 1 ? 1 : normalized <= 2 ? 2 : normalized <= 2.5 ? 2.5 : normalized <= 5 ? 5 : 10;
  return step * power;
}

/** Trois graduations environ, un maximum rond, jamais zéro. */
function niceScale(rawMax: number, desired: number, integer = false): Scale {
  const maxValue = Math.max(1, rawMax);
  if (maxValue <= 1) return { max: 1, ticks: [0, 1] };
  let step = niceStep(maxValue / desired);
  if (integer) step = Math.max(1, Math.ceil(step));
  const max = Math.ceil(maxValue / step) * step;
  const ticks: number[] = [];
  for (let value = 0; value <= max + 1e-9; value += step) ticks.push(value);
  return { max, ticks };
}

interface Point { x: number; y: number }

/**
 * Une courbe monotone (Fritsch–Carlson), l'équivalent de
 * `.interpolationMethod(.monotone)` : douce sans dépasser les points.
 */
function monotonePath(points: Point[]): string {
  const count = points.length;
  if (count === 0) return "";
  if (count === 1) return `M ${points[0].x} ${points[0].y}`;
  const dx: number[] = [];
  const slope: number[] = [];
  for (let index = 0; index < count - 1; index++) {
    dx[index] = points[index + 1].x - points[index].x;
    slope[index] = dx[index] === 0 ? 0 : (points[index + 1].y - points[index].y) / dx[index];
  }
  const tangent = new Array<number>(count).fill(0);
  tangent[0] = slope[0];
  tangent[count - 1] = slope[count - 2];
  for (let index = 1; index < count - 1; index++) {
    tangent[index] = (slope[index - 1] + slope[index]) / 2;
  }
  for (let index = 0; index < count - 1; index++) {
    if (slope[index] === 0) {
      tangent[index] = 0;
      tangent[index + 1] = 0;
    }
  }
  for (let index = 0; index < count - 1; index++) {
    const a = tangent[index] / slope[index];
    const b = tangent[index + 1] / slope[index];
    const magnitude = a * a + b * b;
    if (magnitude > 9) {
      const scale = 3 / Math.sqrt(magnitude);
      tangent[index] = scale * a * slope[index];
      tangent[index + 1] = scale * b * slope[index];
    }
  }
  let path = `M ${points[0].x} ${points[0].y}`;
  for (let index = 0; index < count - 1; index++) {
    const x1 = points[index].x + dx[index] / 3;
    const y1 = points[index].y + (tangent[index] * dx[index]) / 3;
    const x2 = points[index + 1].x - dx[index] / 3;
    const y2 = points[index + 1].y - (tangent[index + 1] * dx[index]) / 3;
    path += ` C ${x1} ${y1}, ${x2} ${y2}, ${points[index + 1].x} ${points[index + 1].y}`;
  }
  return path;
}

const numberText = { fontFamily: "var(--mono)" } as const;

/**
 * La largeur réelle de la feuille : les SVG des graphiques sont dessinés en
 * pixels, pas mis à l'échelle d'un `viewBox` — sinon les libellés rétrécissent
 * dès qu'une carte partage la ligne avec une autre.
 */
function useMeasuredWidth(): [RefObject<HTMLDivElement | null>, number] {
  const ref = useRef<HTMLDivElement | null>(null);
  const [width, setWidth] = useState(760);
  useLayoutEffect(() => {
    const element = ref.current;
    if (!element) return;
    const update = (): void => setWidth(Math.max(240, element.getBoundingClientRect().width || 760));
    update();
    const observer = new ResizeObserver(update);
    observer.observe(element);
    return () => observer.disconnect();
  }, []);
  return [ref, width];
}

// MARK: - Répartition (une barre empilée)

export interface SplitSlice {
  name: string;
  seconds: number;
  color: string;
  opacity: number;
}

export function SplitBar({ slices, selected, onSelect }: {
  slices: SplitSlice[];
  selected: string | null;
  onSelect: (name: string) => void;
}) {
  const uid = useId().replace(/:/g, "");
  const tip = useTip();
  const total = slices.reduce((sum, slice) => sum + slice.seconds, 0);
  let cursor = 0;
  return (
    <>
    {tip.element}
    <svg viewBox="0 0 1000 26" width="100%" height={26} role="img"
      aria-label="Répartition du temps par nature de travail"
      style={{ display: "block", width: "100%", height: 26, borderRadius: 6, overflow: "hidden" }}>
      <defs>
        <clipPath id={uid}>
          <rect x={0} y={0} width={1000} height={26} rx={6} />
        </clipPath>
      </defs>
      <g clipPath={`url(#${uid})`}>
        {slices.map((slice) => {
          const width = total === 0 ? 0 : (slice.seconds / total) * 1000;
          const x = cursor;
          cursor += width;
          return (
            <rect
              key={slice.name}
              x={x}
              y={0}
              width={width}
              height={26}
              className="stats-hit"
              data-testid={`split-${slice.name}`}
              style={{ fill: slice.color, fillOpacity: (selected === null || selected === slice.name ? 1 : 0.35) * slice.opacity }}
              onClick={() => onSelect(slice.name)}
              onPointerMove={tip.show(
                <TipRow color={slice.color} opacity={slice.opacity}
                  label={slice.name} value={`${DateUtils.durationLabel(slice.seconds)} · ${pct(slice.seconds, total)}`} />,
              )}
              onPointerLeave={tip.hide}
            />
          );
        })}
      </g>
    </svg>
    </>
  );
}

// MARK: - Camembert (anneau)

export interface DonutSlice {
  name: string;
  seconds: number;
  color: string;
  opacity?: number;
}

export function Donut({ slices, total, selected, onSelect, innerRatio, inset, size = 150, children, formatValue }: {
  slices: DonutSlice[];
  total: number;
  selected: string | null;
  onSelect: (name: string) => void;
  innerRatio: number;
  /** `angularInset`, en degrés. */
  inset: number;
  size?: number;
  children?: ReactNode;
  /** La valeur de l'infobulle (par défaut une durée). */
  formatValue?: (value: number) => string;
}) {
  const tip = useTip();
  const format = formatValue ?? ((value: number) => DateUtils.durationLabel(value));
  const inner = innerRatio * 50;
  let offset = 0;
  return (
    <div style={{ position: "relative", width: size, height: size, flexShrink: 0 }}>
      {tip.element}
      <svg viewBox="0 0 100 100" width={size} height={size} role="img" aria-label="Répartition du temps">
        {slices.map((slice) => {
          const fraction = total === 0 ? 0 : slice.seconds / total;
          const isSelected = selected === slice.name;
          const outer = isSelected ? 50 : 48;
          const radius = (outer + inner) / 2;
          const stroke = outer - inner;
          const circumference = 2 * Math.PI * radius;
          const gap = (inset / 360) * circumference;
          const length = Math.max(0.01, fraction * circumference - gap);
          const dashOffset = -offset * circumference;
          offset += fraction;
          const dimmed = selected !== null && !isSelected;
          return (
            <circle
              key={slice.name}
              cx={50}
              cy={50}
              r={radius}
              fill="none"
              className="stats-hit"
              data-testid={`donut-${slice.name}`}
              style={{
                stroke: slice.color,
                strokeOpacity: (dimmed ? 0.4 : 1) * (slice.opacity ?? 1),
                strokeWidth: stroke,
              }}
              strokeDasharray={`${length} ${circumference - length}`}
              strokeDashoffset={dashOffset}
              transform="rotate(-90 50 50)"
              onClick={() => onSelect(slice.name)}
              onPointerMove={tip.show(
                <TipRow color={slice.color} opacity={slice.opacity ?? 1} label={slice.name}
                  value={`${format(slice.seconds)} · ${pct(slice.seconds, total)}`} />,
              )}
              onPointerLeave={tip.hide}
            />
          );
        })}
      </svg>
      <div style={{
        position: "absolute", inset: 0, display: "grid", placeItems: "center",
        textAlign: "center", pointerEvents: "none", padding: 8,
      }}>
        {children}
      </div>
    </div>
  );
}

// MARK: - Le temps, jour par jour / semaine par semaine

export interface TimeBarPoint {
  bin: Date;
  category: string;
  seconds: number;
}

export function TimeBars({ bars, bins, range, categoryOrder, styles, selectedBin, onSelect, axisLabel, xStride, tipTitle, goalHours }: {
  bars: TimeBarPoint[];
  bins: Date[];
  range: { start: Date; end: Date };
  categoryOrder: string[];
  styles: Record<string, CategoryStyle>;
  selectedBin: Date | null;
  onSelect: (bin: Date) => void;
  axisLabel: (date: Date) => string;
  xStride: number;
  /** Le titre de l'infobulle d'une barre (jour ou semaine en toutes lettres). */
  tipTitle?: (date: Date) => string;
  /** La ligne pointillée « objectif », en heures (le `RuleMark` du Mac). */
  goalHours?: number;
}) {
  const [container, width] = useMeasuredWidth();
  const tip = useTip();
  const [hover, setHover] = useState<number | null>(null);
  const left = 38;
  const right = 12;
  const top = 10;
  const bottom = 26;
  const plotHeight = 160;
  const plotWidth = width - left - right;
  const height = top + plotHeight + bottom;

  const totalsByBin = new Map<number, number>();
  const byBin = new Map<number, TimeBarPoint[]>();
  for (const bar of bars) {
    const key = bar.bin.getTime();
    totalsByBin.set(key, (totalsByBin.get(key) ?? 0) + bar.seconds);
    byBin.set(key, [...(byBin.get(key) ?? []), bar]);
  }
  const rawMax = Math.max(0, ...[...totalsByBin.values()].map((seconds) => seconds / 3600));
  const scale = niceScale(Math.max(rawMax, goalHours ?? 0), 3);

  const span = Math.max(1, range.end.getTime() - range.start.getTime());
  const binStep = bins.length > 1
    ? bins[1].getTime() - bins[0].getTime()
    : span;
  const slot = (plotWidth * binStep) / span;
  const barWidth = Math.max(3, Math.min(26, slot * 0.62));
  // Le centre de la case du jour (le `unit: .day` de Swift Charts), pas son début.
  const xFor = (date: Date): number =>
    left + ((date.getTime() - range.start.getTime()) / span) * plotWidth + slot / 2;
  const yFor = (hours: number): number =>
    top + plotHeight - (hours / scale.max) * plotHeight;

  return (
    <div ref={container} style={{ width: "100%" }}>
    {tip.element}
    <svg viewBox={`0 0 ${width} ${height}`} width={width} height={height} role="img"
      aria-label="Temps par jour et par catégorie" style={{ display: "block", overflow: "visible" }}>
      {scale.ticks.map((tick) => (
        <g key={tick}>
          <line x1={left} y1={yFor(tick)} x2={width - right} y2={yFor(tick)}
            style={{ stroke: "var(--rule)", strokeWidth: 1 }} />
          <text x={left - 8} y={yFor(tick)} textAnchor="end" dominantBaseline="middle"
            style={{ ...numberText, fill: "var(--ink-tertiary)", fontSize: 10 }}>
            {Math.round(tick)} h
          </text>
        </g>
      ))}

      {[selectedBin, hover === null ? null : bins[hover]].map((bin, index) => {
        if (!bin) return null;
        const band = Math.max(6, slot * 0.9);
        const x = xFor(bin) - band / 2;
        return (
          <rect key={index} x={x} y={top} width={band} height={plotHeight} rx={4}
            style={{ fill: "var(--ink)", opacity: index === 0 ? 0.08 : 0.05 }} />
        );
      })}

      {bins.map((bin) => {
        const list = [...(byBin.get(bin.getTime()) ?? [])].sort(
          (a, b) => categoryOrder.indexOf(a.category) - categoryOrder.indexOf(b.category),
        );
        let stack = 0;
        const center = xFor(bin);
        const dimmed = selectedBin !== null && selectedBin.getTime() !== bin.getTime();
        return (
          <g key={bin.getTime()} style={{ opacity: dimmed ? 0.35 : 1 }}>
            {list.map((bar) => {
              const hours = bar.seconds / 3600;
              const barHeight = (hours / scale.max) * plotHeight;
              const y = top + plotHeight - stack - barHeight;
              stack += barHeight;
              const style = styles[bar.category] ?? { color: "var(--ink-secondary)", opacity: 1 };
              return (
                <rect key={bar.category} x={center - barWidth / 2} y={y}
                  width={barWidth} height={Math.max(0, barHeight)} rx={2}
                  style={{ fill: style.color, fillOpacity: style.opacity }} />
              );
            })}
          </g>
        );
      })}

      {bins.map((bin, index) => {
        if (index % Math.max(1, xStride) !== 0) return null;
        return (
          <text key={`label-${bin.getTime()}`} x={xFor(bin)} y={top + plotHeight + 16}
            textAnchor="middle" style={{ fill: "var(--ink-secondary)", fontSize: 10 }}>
            {axisLabel(bin)}
          </text>
        );
      })}

      {goalHours !== undefined && goalHours > 0 && (
        <g pointerEvents="none">
          <line x1={left} y1={yFor(goalHours)} x2={width - right} y2={yFor(goalHours)}
            strokeDasharray="3 3" style={{ stroke: "var(--correct)", strokeWidth: 1 }} />
          <text x={width - right} y={yFor(goalHours) - 4} textAnchor="end"
            style={{ fill: "var(--ink-secondary)", fontSize: 10 }}>
            objectif
          </text>
        </g>
      )}

      {bins.map((bin, index) => {
        const list = byBin.get(bin.getTime()) ?? [];
        const total = totalsByBin.get(bin.getTime()) ?? 0;
        const rows = [...list].sort((a, b) => b.seconds - a.seconds);
        return (
          <rect key={`hit-${bin.getTime()}`} x={xFor(bin) - slot / 2} y={top}
            width={Math.max(3, slot)} height={plotHeight} fill="transparent"
            className="stats-hit" data-testid={`time-bin-${index}`} onClick={() => onSelect(bin)}
            onPointerMove={(event) => {
              setHover(index);
              tip.show(
                <>
                  <div className="chart-tip-title">{(tipTitle ?? axisLabel)(bin)}</div>
                  {rows.length === 0
                    ? <div className="chart-tip-empty">Rien</div>
                    : rows.map((bar) => {
                      const style = styles[bar.category] ?? { color: "var(--ink-secondary)", opacity: 1 };
                      return <TipRow key={bar.category} color={style.color} opacity={style.opacity}
                        label={bar.category} value={DateUtils.durationLabel(bar.seconds)} />;
                    })}
                  {rows.length > 1 && <TipRow label="Total" value={DateUtils.durationLabel(total)} />}
                </>,
              )(event);
            }}
            onPointerLeave={() => { setHover(null); tip.hide(); }} />
        );
      })}
    </svg>
    </div>
  );
}

// MARK: - Une ligne par série

export interface LineSeries {
  name: string;
  color: string;
  values: number[];
  /** Aire légère sous la courbe (la tendance du temps). */
  fill?: boolean;
  /** Points sur la courbe (l'avancement). */
  markers?: boolean;
}

export function LineChart({ weeks, series, xLabel, formatY, average, selectedIndex, onSelect, plotHeight = 150, xStride = 2, integerAxis = false }: {
  weeks: Date[];
  series: LineSeries[];
  xLabel: (date: Date) => string;
  formatY: (value: number) => string;
  average?: number;
  selectedIndex: number | null;
  onSelect: (index: number) => void;
  plotHeight?: number;
  xStride?: number;
  /** Des graduations entières : l'avancement compte des éléments, pas des heures. */
  integerAxis?: boolean;
}) {
  const [container, width] = useMeasuredWidth();
  const tip = useTip();
  const [hover, setHover] = useState<number | null>(null);
  const left = 40;
  const right = 14;
  const top = 12;
  const bottom = 26;
  const plotWidth = width - left - right;
  const height = top + plotHeight + bottom;

  const rawMax = Math.max(0, ...series.flatMap((item) => item.values));
  const scale = niceScale(rawMax, 3, integerAxis);
  const count = weeks.length;
  const xFor = (index: number): number =>
    count <= 1 ? left + plotWidth / 2 : left + (index / (count - 1)) * plotWidth;
  const yFor = (value: number): number =>
    top + plotHeight - (value / scale.max) * plotHeight;

  // Les zones cliquables : une par semaine, bornées par les milieux voisins.
  const edges: number[] = [];
  for (let index = 0; index < count; index++) {
    edges.push(index === 0 ? left : (xFor(index - 1) + xFor(index)) / 2);
  }
  edges.push(width - right);

  return (
    <div ref={container} style={{ width: "100%" }}>
    {tip.element}
    <svg viewBox={`0 0 ${width} ${height}`} width={width} height={height} role="img"
      aria-label="Évolution par semaine" style={{ display: "block", overflow: "visible" }}>
      {scale.ticks.map((tick) => (
        <g key={tick}>
          <line x1={left} y1={yFor(tick)} x2={width - right} y2={yFor(tick)}
            style={{ stroke: "var(--rule)", strokeWidth: 1 }} />
          <text x={left - 8} y={yFor(tick)} textAnchor="end" dominantBaseline="middle"
            style={{ ...numberText, fill: "var(--ink-tertiary)", fontSize: 10 }}>
            {formatY(tick)}
          </text>
        </g>
      ))}

      {series.map((item) => {
        const points = item.values.map((value, index) => ({ x: xFor(index), y: yFor(value) }));
        const path = monotonePath(points);
        const area = `${path} L ${points[points.length - 1].x} ${top + plotHeight} L ${points[0].x} ${top + plotHeight} Z`;
        return (
          <g key={item.name}>
            {item.fill && count > 1 && (
              <path d={area} style={{ fill: item.color, opacity: 0.12 }} />
            )}
            <path d={path} fill="none" strokeLinecap="round"
              style={{ stroke: item.color, strokeWidth: 2.5 }} />
            {item.markers && points.map((point, index) => (
              <circle key={index} cx={point.x} cy={point.y} r={2.8}
                style={{ fill: item.color }} />
            ))}
          </g>
        );
      })}

      {average !== undefined && average > 0 && (
        <line x1={left} y1={yFor(average)} x2={width - right} y2={yFor(average)}
          strokeDasharray="4 4"
          style={{ stroke: "var(--ink-tertiary)", strokeWidth: 1 }} />
      )}

      {[selectedIndex, hover].map((active, slot) => (
        active !== null && active >= 0 && active < count && (
          <g key={slot}>
            <line x1={xFor(active)} y1={top} x2={xFor(active)} y2={top + plotHeight}
              style={{ stroke: "var(--ink)", opacity: slot === 0 ? 0.25 : 0.15, strokeWidth: 1 }} />
            {series.map((item) => (
              <circle key={`sel-${item.name}`} cx={xFor(active)} cy={yFor(item.values[active] ?? 0)}
                r={4} style={{ fill: item.color, stroke: "var(--sheet)", strokeWidth: 1.5 }} />
            ))}
          </g>
        )
      ))}

      {weeks.map((week, index) => {
        if (index % Math.max(1, xStride) !== 0) return null;
        return (
          <text key={week.getTime()} x={xFor(index)} y={top + plotHeight + 16}
            textAnchor="middle" style={{ fill: "var(--ink-secondary)", fontSize: 10 }}>
            {xLabel(week)}
          </text>
        );
      })}

      {weeks.map((week, index) => (
        <rect key={`hit-${week.getTime()}`} x={edges[index]} y={top}
          width={Math.max(2, edges[index + 1] - edges[index])} height={plotHeight}
          fill="transparent" className="stats-hit" data-testid={`week-${index}`} onClick={() => onSelect(index)}
          onPointerMove={(event) => {
            setHover(index);
            tip.show(
              <>
                <div className="chart-tip-title">{`Semaine du ${DateUtils.shortDay(week)}`}</div>
                {series.map((item) => (
                  <TipRow key={item.name} color={item.color} label={item.name}
                    value={formatY(item.values[index] ?? 0)} />
                ))}
              </>,
            )(event);
          }}
          onPointerLeave={() => { setHover(null); tip.hide(); }} />
      ))}
    </svg>
    </div>
  );
}

// MARK: - Fait / prévu, cours par cours

export interface PaceBarRow {
  code: string;
  color: string;
  done: number;
  expected: number;
}

export function PaceBars({ rows, emptyLabel }: { rows: PaceBarRow[]; emptyLabel: string }) {
  const [container, width] = useMeasuredWidth();
  const tip = useTip();
  if (rows.length === 0) {
    return <div ref={container} style={{ color: "var(--ink-secondary)", fontSize: 13 }}>{emptyLabel}</div>;
  }
  const left = 74;
  const right = 16;
  const top = 10;
  const rowHeight = 34;
  const axisHeight = 24;
  const plotWidth = width - left - right;
  const height = rows.length * rowHeight + top + axisHeight;
  const domain = 112;
  const xFor = (percentValue: number): number => left + (percentValue / domain) * plotWidth;

  return (
    <div ref={container} style={{ width: "100%" }}>
    {tip.element}
    <svg viewBox={`0 0 ${width} ${height}`} width={width} height={height} role="img"
      aria-label="Part faite et part prévue à ce jour, par cours"
      style={{ display: "block", overflow: "visible" }}>
      {[0, 25, 50, 75, 100].map((tick) => (
        <g key={tick}>
          <line x1={xFor(tick)} y1={top} x2={xFor(tick)} y2={top + rows.length * rowHeight}
            style={{ stroke: "var(--rule)", strokeWidth: 1 }} />
          <text x={xFor(tick)} y={height - 4} textAnchor="middle"
            style={{ ...numberText, fill: "var(--ink-tertiary)", fontSize: 10 }}>
            {tick} %
          </text>
        </g>
      ))}

      {rows.map((row, index) => {
        const center = top + index * rowHeight + rowHeight / 2;
        const donePercent = row.done * 100;
        const expectedPercent = row.expected * 100;
        const barWidth = Math.max(0, xFor(donePercent) - left);
        const labelX = left + barWidth + 4;
        const behind = row.done + 0.05 < row.expected;
        const placeLeft = labelX + 26 > width - right;
        return (
          <g key={row.code}>
            <text x={left - 8} y={center} textAnchor="end" dominantBaseline="middle"
              style={{ fill: "var(--ink)", fontSize: 11, fontWeight: 600 }}>
              {row.code}
            </text>
            <rect x={left} y={center - 7} width={barWidth} height={14} rx={3}
              style={{ fill: row.color }} />
            <rect x={xFor(expectedPercent) - 1.5} y={center - 11} width={3} height={22} rx={1.5}
              style={{ fill: "var(--ink)" }} />
            <text
              x={placeLeft ? left + barWidth - 4 : labelX}
              y={center}
              textAnchor={placeLeft ? "end" : "start"}
              dominantBaseline="middle"
              style={{
                ...numberText, fontSize: 10,
                fill: behind ? "var(--wrong)" : "var(--ink-secondary)",
              }}
            >
              {Math.round(donePercent)} %
            </text>
            <rect x={0} y={center - rowHeight / 2} width={width} height={rowHeight} fill="transparent"
              onPointerMove={tip.show(
                <>
                  <div className="chart-tip-title">{row.code}</div>
                  <TipRow color={row.color} label="Fait" value={`${Math.round(donePercent)} %`} />
                  <TipRow label="Prévu à ce jour" value={`${Math.round(expectedPercent)} %`} />
                </>,
              )}
              onPointerLeave={tip.hide} />
          </g>
        );
      })}
    </svg>
    </div>
  );
}
