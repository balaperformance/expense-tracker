import { useEffect, useState, type CSSProperties } from 'react';

import { Money } from '@/components/finance/Money';
import { CategoryGlyph } from '@/components/ui/Icon';
import { shareOf, sumBy, type CategorySpend } from '@/domain/analytics';
import { formatPercent } from '@/lib/format';

import { ProgressTrack } from '../finance/Budget';

import styles from './Charts.module.css';
import { MAX_SLICES, segmentColor } from './palette';

/** Fires once after mount, so a chart can grow in from nothing. */
function useEntered(): boolean {
  const [entered, setEntered] = useState(false);
  useEffect(() => {
    const frame = requestAnimationFrame(() => setEntered(true));
    return () => cancelAnimationFrame(frame);
  }, []);
  return entered;
}

type Slice = { value: number; color: string };

function slicesOf(breakdown: readonly CategorySpend[]): Slice[] {
  const count = breakdown.length;
  if (count <= MAX_SLICES) return breakdown.map((c, i) => ({ value: c.total, color: segmentColor(i, count) }));
  const named = breakdown.slice(0, MAX_SLICES - 1).map((c, i) => ({ value: c.total, color: segmentColor(i, count) }));
  const rest = sumBy(breakdown.slice(MAX_SLICES - 1), (c) => c.total);
  return rest > 0 ? [...named, { value: rest, color: 'var(--chart-other)' }] : named;
}

/** Spending by category as a ring, with the period total at its centre. */
export function CategoryDonut({ breakdown, currency, size = 148 }: { breakdown: readonly CategorySpend[]; currency: string; size?: number }) {
  const entered = useEntered();
  if (!breakdown.length) return null;
  const total = sumBy(breakdown, (c) => c.total);
  const slices = slicesOf(breakdown);
  const thickness = size * 0.17;
  const radius = size * 0.31 + thickness / 2;
  const circumference = 2 * Math.PI * radius;
  const gap = slices.length > 1 ? 3 : 0;
  // Each arc starts where the previous one ended.
  const arcs = slices.reduce<{ color: string; length: number; start: number }[]>((list, slice) => {
    const previous = list[list.length - 1];
    const start = previous ? previous.start + previous.length : 0;
    return [...list, { color: slice.color, length: total > 0 ? (slice.value / total) * circumference : 0, start }];
  }, []);

  return (
    <div className={styles.donut} style={{ width: size, height: size }}>
      <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`} aria-hidden>
        <circle className={styles.donutTrack} cx={size / 2} cy={size / 2} r={radius} strokeWidth={thickness} />
        {arcs.map((arc, i) => {
          const dash = Math.max(0, arc.length - gap);
          return (
            <circle
              key={i}
              className={styles.slice}
              cx={size / 2}
              cy={size / 2}
              r={radius}
              stroke={arc.color}
              strokeWidth={thickness}
              strokeDasharray={entered ? `${dash} ${circumference - dash}` : `0 ${circumference}`}
              strokeDashoffset={-arc.start}
            />
          );
        })}
      </svg>
      <div className={styles.donutCenter}>
        <span className="t-label-sm">Total spent</span>
        <Money amount={total} currency={currency} compact className={styles.donutTotal} />
      </div>
    </div>
  );
}

/** The ranked legend beneath the ring — same colours, same order. */
export function CategoryBreakdownList({
  breakdown,
  currency,
  limit,
}: {
  breakdown: readonly CategorySpend[];
  currency: string;
  limit?: number;
}) {
  if (!breakdown.length) return null;
  const total = sumBy(breakdown, (c) => c.total);
  const visible = limit == null ? breakdown : breakdown.slice(0, limit);
  return (
    <div className={styles.breakdown}>
      {visible.map((spend, i) => {
        const tone = segmentColor(i, breakdown.length);
        const share = shareOf(spend, total);
        return (
          <div key={spend.categoryId ?? 'none'} className={styles.breakdownRow} style={{ '--tone': tone } as CSSProperties}>
            <span className={styles.breakdownIcon} aria-hidden>
              <CategoryGlyph icon={spend.icon} size={15} />
            </span>
            <div className={styles.breakdownBody}>
              <div className={styles.breakdownTop}>
                <span className={styles.breakdownName}>{spend.name}</span>
                <Money amount={spend.total} currency={currency} compact className={styles.breakdownAmount} />
              </div>
              <div className={styles.breakdownBar}>
                <div className="grow">
                  <ProgressTrack ratio={share} tone={tone} />
                </div>
                <span className={styles.breakdownPercent}>{formatPercent(share)}</span>
              </div>
            </div>
          </div>
        );
      })}
    </div>
  );
}
