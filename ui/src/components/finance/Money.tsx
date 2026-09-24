import { useEffect, useRef, useState, type CSSProperties } from 'react';

import { formatCurrency } from '@/lib/format';

export type AmountTone = 'neutral' | 'positive' | 'negative' | 'warning' | 'transfer' | 'auto';

const TONE_COLOR: Record<Exclude<AmountTone, 'neutral' | 'auto'>, string> = {
  positive: 'var(--income)',
  negative: 'var(--expense)',
  warning: 'var(--warning)',
  transfer: 'var(--transfer)',
};

function toneColor(tone: AmountTone, amount: number): string | undefined {
  if (tone === 'neutral') return undefined;
  if (tone === 'auto') return amount === 0 ? undefined : amount > 0 ? TONE_COLOR.positive : TONE_COLOR.negative;
  return TONE_COLOR[tone];
}

const reducedMotion = () => window.matchMedia('(prefers-reduced-motion: reduce)').matches;

/** Counts a figure from its previous value to the new one (AppMotion.figure). */
function useCountingNumber(value: number, enabled: boolean): number {
  const [shown, setShown] = useState(value);
  // Where the figure currently is, so an interrupted count continues smoothly.
  const current = useRef(value);
  const active = enabled && !reducedMotion();
  useEffect(() => {
    if (!active || current.current === value) {
      current.current = value;
      // Keep the counter in step while not animating, so a later count
      // starts from the true figure.
      const sync = requestAnimationFrame(() => setShown(value));
      return () => cancelAnimationFrame(sync);
    }
    const start = performance.now();
    const origin = current.current;
    let frame = requestAnimationFrame(function step(now: number) {
      const t = Math.min(1, (now - start) / 420);
      const next = origin + (value - origin) * (1 - Math.pow(1 - t, 3));
      current.current = next;
      setShown(next);
      if (t < 1) frame = requestAnimationFrame(step);
    });
    return () => cancelAnimationFrame(frame);
  }, [value, active]);
  return active ? shown : value;
}

type MoneyProps = {
  amount: number;
  currency: string;
  tone?: AmountTone;
  compact?: boolean;
  /** Prefix + / − so direction is readable without colour. */
  signed?: boolean;
  /** Bolder, for the amount a row is scanned for. */
  emphasis?: boolean;
  obscured?: boolean;
  animate?: boolean;
  className?: string;
  style?: CSSProperties;
};

/**
 * Every rendered currency value. Tabular figures keep columns of amounts from
 * jittering; the sign is a true minus so it reads as one.
 */
export function Money({ amount, currency, tone = 'neutral', compact, signed, emphasis, obscured, animate, className, style }: MoneyProps) {
  const shown = useCountingNumber(amount, Boolean(animate && !obscured));
  const classes = ['money', className].filter(Boolean).join(' ');
  if (obscured) {
    return (
      <span className={classes} style={{ color: 'var(--muted)', letterSpacing: 1.5, ...style }} aria-label="Hidden amount">
        ••••••
      </span>
    );
  }
  const text = formatCurrency(Math.abs(shown), currency, { compact });
  const prefix = !signed ? '' : amount < 0 ? '−' : '+';
  return (
    <span
      className={classes}
      style={{ color: toneColor(tone, amount), fontWeight: emphasis ? 700 : undefined, ...style }}
    >
      {prefix}
      {!signed && amount < 0 && Math.abs(amount) >= 0.005 ? '-' : ''}
      {text}
    </span>
  );
}
