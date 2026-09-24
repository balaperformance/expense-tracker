import { useId, useState, type CSSProperties, type PointerEvent } from 'react';

import { Money } from '@/components/finance/Money';
import { Icon } from '@/components/ui/Icon';
import type { MonthlyPoint } from '@/domain/analytics';
import { formatCurrency, monthYear, shortMonth } from '@/lib/format';
import { useElementSize } from '@/hooks/useElementSize';

import styles from './Charts.module.css';

const LEFT_AXIS = 48;
const BOTTOM_AXIS = 26;
/** The floor for a chart that fills its container. */
const FILL_MIN_HEIGHT = 180;

const clamp = (value: number, min: number, max: number) => Math.min(Math.max(value, min), max);

type TrendChartProps = {
  points: readonly MonthlyPoint[];
  currency: string;
  /** Draws income beside expense (reports); otherwise expense alone (dashboard). */
  showIncome?: boolean;
  /** A fixed height, or 'fill' to take whatever height the surrounding layout gives it. */
  height?: number | 'fill';
  selectedIndex?: number;
  onSelect?: (index: number) => void;
};

/**
 * Six months of bars. The selected month carries the emphasis gradient; the
 * others are the same hue washed back. Touch anywhere in a column to pick it.
 */
export function MonthlyTrendChart({ points, currency, showIncome = false, height: heightProp = 164, selectedIndex, onSelect }: TrendChartProps) {
  const [ref, size] = useElementSize<HTMLDivElement>();
  const [probe, setProbe] = useState<number | null>(null);
  const gradientId = useId().replace(/[^a-zA-Z0-9_-]/g, '');
  const fill = heightProp === 'fill';
  const width = size.width;
  const height = fill ? Math.max(size.height, FILL_MIN_HEIGHT) : heightProp;
  const last = points.length - 1;
  const selected = Math.min(Math.max(selectedIndex ?? last, 0), Math.max(last, 0));

  const max = points.reduce((m, p) => Math.max(m, showIncome ? Math.max(p.expense, p.income) : p.expense), 0);
  const ceiling = max <= 0 ? 100 : max * 1.2;
  const step = ceiling / 3;
  const plotWidth = Math.max(0, width - LEFT_AXIS);
  const plotHeight = height - BOTTOM_AXIS;
  const slot = points.length ? plotWidth / points.length : 0;
  const y = (value: number) => plotHeight - (value / ceiling) * plotHeight;

  const indexAt = (event: PointerEvent<HTMLDivElement>) => {
    const box = event.currentTarget.getBoundingClientRect();
    const x = event.clientX - box.left - LEFT_AXIS;
    return Math.min(Math.max(Math.floor(x / (slot || 1)), 0), last);
  };
  const pick = (event: PointerEvent<HTMLDivElement>) => {
    if (!points.length) return;
    const index = indexAt(event);
    setProbe(index);
    if (index !== selected) onSelect?.(index);
  };

  const tooltipPoint = probe != null ? points[probe] : undefined;
  const tooltipValue = tooltipPoint ? (showIncome ? Math.max(tooltipPoint.expense, tooltipPoint.income) : tooltipPoint.expense) : 0;

  // Bars widen with the room they have, within a range that stays elegant.
  const pairWidth = clamp(slot * 0.15, 7, 15);
  const soloWidth = clamp(slot * 0.26, 14, 28);
  const soloIdleWidth = Math.round(soloWidth * 0.78);
  const expenseFill = `url(#${gradientId}-expense)`;
  const incomeFill = `url(#${gradientId}-income)`;

  return (
    <div
      ref={ref}
      className={fill ? `${styles.bars} ${styles.barsFill}` : styles.bars}
      style={fill ? { '--chart-min': `${FILL_MIN_HEIGHT}px` } as CSSProperties : { height }}
      onPointerDown={pick}
      onPointerMove={(event) => {
        if (event.pointerType === 'mouse' || event.buttons) pick(event);
      }}
      onPointerLeave={() => setProbe(null)}
      onPointerUp={(event) => {
        if (event.pointerType !== 'mouse') setProbe(null);
      }}
      role="img"
      aria-label={`Monthly ${showIncome ? 'income and expenses' : 'spending'}: ${points
        .map((p) => `${shortMonth(p.month)} ${formatCurrency(p.expense, currency, { compact: true })}`)
        .join(', ')}`}
    >
      {width > 0 ? (
        <svg width={width} height={height} aria-hidden>
          <defs>
            <linearGradient id={`${gradientId}-expense`} x1="0" y1="1" x2="0" y2="0">
              <stop offset="0" stopColor="var(--chart-expense)" />
              <stop offset="1" stopColor="var(--chart-expense-hi)" />
            </linearGradient>
            <linearGradient id={`${gradientId}-income`} x1="0" y1="1" x2="0" y2="0">
              <stop offset="0" stopColor="var(--chart-income)" />
              <stop offset="1" stopColor="var(--chart-income-hi)" />
            </linearGradient>
          </defs>
          {probe != null && slot > 0 ? (
            <rect
              className={styles.column}
              x={LEFT_AXIS + slot * probe + 3}
              y={0}
              width={Math.max(0, slot - 6)}
              height={plotHeight}
              rx={10}
            />
          ) : null}
          {[0, 1, 2, 3].map((i) => {
            const value = step * i;
            const lineY = y(value);
            return (
              <g key={i}>
                <line
                  className={i === 0 ? styles.baseLine : styles.gridLine}
                  x1={LEFT_AXIS}
                  x2={width}
                  y1={lineY}
                  y2={lineY}
                />
                {value > 0 && value <= ceiling - step * 0.4 ? (
                  <text className={styles.axisLabel} x={LEFT_AXIS - 8} y={lineY + 4} textAnchor="end">
                    {formatCurrency(value, currency, { compact: true })}
                  </text>
                ) : null}
              </g>
            );
          })}
          {points.map((point, i) => {
            const isSelected = i === selected;
            const center = LEFT_AXIS + slot * i + slot / 2;
            const label = shortMonth(point.month);
            const pillWidth = label.length * 7 + 16;
            const soloBarWidth = isSelected ? soloWidth : soloIdleWidth;
            const bars = showIncome
              ? [
                  {
                    value: point.expense,
                    width: pairWidth,
                    x: center - pairWidth - 2,
                    fill: expenseFill,
                    opacity: isSelected ? 1 : 0.45,
                    radius: pairWidth / 2,
                  },
                  {
                    value: point.income,
                    width: pairWidth,
                    x: center + 2,
                    fill: incomeFill,
                    opacity: isSelected ? 1 : 0.45,
                    radius: pairWidth / 2,
                  },
                ]
              : [
                  {
                    value: point.expense,
                    width: soloBarWidth,
                    x: center - soloBarWidth / 2,
                    fill: isSelected ? expenseFill : 'var(--chart-idle)',
                    opacity: 1,
                    radius: Math.min(8, soloBarWidth / 2),
                  },
                ];
            return (
              <g key={point.month}>
                {bars.map((bar, b) => {
                  const barHeight = Math.max(0, plotHeight - y(bar.value));
                  if (barHeight <= 0) return null;
                  const r = Math.min(bar.radius, bar.width / 2, barHeight);
                  const top = plotHeight - barHeight;
                  // Rounded top, square base.
                  const d = `M${bar.x},${plotHeight} V${top + r} Q${bar.x},${top} ${bar.x + r},${top} H${bar.x + bar.width - r} Q${bar.x + bar.width},${top} ${bar.x + bar.width},${top + r} V${plotHeight} Z`;
                  return (
                    <path
                      key={b}
                      className={styles.bar}
                      d={d}
                      fill={bar.fill}
                      opacity={bar.opacity}
                      style={{ animationDelay: `${i * 40}ms` }}
                    />
                  );
                })}
                {isSelected ? (
                  <rect
                    className={styles.monthPill}
                    x={center - pillWidth / 2}
                    y={plotHeight + 6}
                    width={pillWidth}
                    height={17}
                    rx={8.5}
                  />
                ) : null}
                <text
                  className={[styles.monthLabel, isSelected && styles.monthLabelOn].filter(Boolean).join(' ')}
                  x={center}
                  y={plotHeight + 18}
                  textAnchor="middle"
                >
                  {label}
                </text>
              </g>
            );
          })}
        </svg>
      ) : null}
      {tooltipPoint && probe != null && tooltipValue > 0 ? (
        <span className={styles.tooltip} style={{ left: LEFT_AXIS + slot * probe + slot / 2, top: y(tooltipValue) }}>
          {formatCurrency(tooltipValue, currency, { compact: true })}
        </span>
      ) : null}
    </div>
  );
}

/** The selected month's spend with its change against the month before, over the bars. */
export function MonthlyTrendCard({ points, currency, chartHeight = 168 }: { points: readonly MonthlyPoint[]; currency: string; chartHeight?: number }) {
  const [selected, setSelected] = useState<number | null>(null);
  if (!points.length) return null;
  const index = Math.min(selected ?? points.length - 1, points.length - 1);
  const point = points[index];
  const previous = index > 0 ? points[index - 1] : undefined;
  if (!point) return null;

  return (
    <div>
      <div className={styles.trendHead}>
        <div className="grow stack gap-xs">
          <span className="t-label-sm">{monthYear(point.month)}</span>
          <Money amount={point.expense} currency={currency} tone="negative" animate className={styles.trendFigure} />
        </div>
        {previous && previous.expense > 0 ? <DeltaBadge current={point.expense} previous={previous.expense} previousLabel={shortMonth(previous.month)} /> : null}
      </div>
      <MonthlyTrendChart points={points} currency={currency} height={chartHeight} selectedIndex={index} onSelect={setSelected} />
    </div>
  );
}

function DeltaBadge({ current, previous, previousLabel }: { current: number; previous: number; previousLabel: string }) {
  const change = (current - previous) / previous;
  const up = current > previous;
  return (
    <span className={styles.delta} style={{ '--tone': up ? 'var(--expense)' : 'var(--income)' } as CSSProperties}>
      <Icon name={up ? 'up' : 'down'} size={11} />
      {Math.round(Math.abs(change) * 100)}% vs {previousLabel}
    </span>
  );
}

export function ChartLegend({ entries }: { entries: { label: string; color: string }[] }) {
  return (
    <div className={styles.legend}>
      {entries.map((entry) => (
        <span key={entry.label} className={styles.legendItem}>
          <span className={styles.legendSwatch} style={{ background: entry.color }} />
          {entry.label}
        </span>
      ))}
    </div>
  );
}
