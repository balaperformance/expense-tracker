import type { CSSProperties, ReactNode } from 'react';

import { IconButton } from '@/components/ui/Button';
import { Icon, type IconName } from '@/components/ui/Icon';
import { Hero } from '@/components/ui/Surface';
import { monthYear } from '@/lib/format';

import styles from './Finance.module.css';
import { Money } from './Money';

type BalanceCardProps = {
  income: number;
  expense: number;
  currency: string;
  monthLabel: string;
  /** Every bank and cash account's balance added up; null when there are no accounts. */
  bankTotal: number | null;
  bankTotalHidden: boolean;
  onToggleBankTotal: () => void;
};

/**
 * The dashboard's hero: what is available now, then the month so far. The
 * month is still running — a salary paid at month-end has not arrived yet —
 * so income received and spending sit side by side as figures to date and
 * are never netted into a verdict on the month. Without accounts there is no
 * balance, and the figure is the month's spending. The corner glow stays a
 * neutral blue-gray: green belongs to Income alone.
 */
export function BalanceCard({ income, expense, currency, monthLabel, bankTotal, bankTotalHidden, onToggleBankTotal }: BalanceCardProps) {
  const monthBadge = <span className={styles.heroBadge}>{monthLabel}</span>;
  return (
    <Hero glow="var(--hero-glow)">
      <div className={styles.eyebrowRow}>
        <span className="t-eyebrow grow" style={{ color: 'var(--hero-accent)' }}>
          {bankTotal != null ? 'Available balance' : 'Spent this month'}
        </span>
        {bankTotal != null ? (
          <IconButton
            icon={bankTotalHidden ? 'eye' : 'eyeOff'}
            label={bankTotalHidden ? 'Show balance' : 'Hide balance'}
            small
            color="var(--muted)"
            iconSize={18}
            onClick={onToggleBankTotal}
          />
        ) : (
          monthBadge
        )}
      </div>
      <div className={styles.net}>
        {bankTotal != null ? (
          <Money amount={bankTotal} currency={currency} obscured={bankTotalHidden} animate />
        ) : (
          <Money amount={expense} currency={currency} animate />
        )}
      </div>
      {bankTotal != null ? (
        <div className={styles.bankLine}>
          <span className="grow">So far this month</span>
          {monthBadge}
        </div>
      ) : null}
      <div className={styles.legs}>
        <Leg label="Income received" amount={income} currency={currency} tone="var(--income)" icon="moneyIn" />
        {bankTotal != null ? <Leg label="Spent this month" amount={expense} currency={currency} tone="var(--expense)" icon="moneyOut" /> : null}
      </div>
    </Hero>
  );
}

function Leg({ label, amount, currency, tone, icon }: { label: string; amount: number; currency: string; tone: string; icon: IconName }) {
  return (
    <div className={styles.leg} style={{ '--tone': tone } as CSSProperties}>
      <span className={styles.legIcon}>
        <Icon name={icon} size={14} />
      </span>
      <span className={styles.legText}>
        <span className="t-label-sm">{label}</span>
        <Money amount={amount} currency={currency} compact className={styles.legAmount} />
      </span>
    </div>
  );
}

export type QuickAction = { label: string; icon: IconName; tone?: string; onClick: () => void };

export function QuickActions({ actions }: { actions: QuickAction[] }) {
  return (
    <div className={styles.quick}>
      {actions.map((action) => (
        <button
          key={action.label}
          type="button"
          className={styles.quickAction}
          style={action.tone ? ({ '--tone': action.tone } as CSSProperties) : undefined}
          onClick={action.onClick}
        >
          <span className={styles.quickTile}>
            <span className={styles.quickWell}>
              <Icon name={action.icon} size={20} />
            </span>
          </span>
          <span className={styles.quickLabel}>{action.label}</span>
        </button>
      ))}
    </div>
  );
}

export function StatTile({
  label,
  amount,
  currency,
  icon,
  tone,
  coloured,
}: {
  label: string;
  amount: number;
  currency: string;
  icon: IconName;
  tone: string;
  coloured?: boolean;
}) {
  return (
    <div className={styles.stat} style={{ '--tone': tone } as CSSProperties}>
      <span className={styles.statLabel}>
        <span className={styles.statIcon}>
          <Icon name={icon} size={12} />
        </span>
        <span className="t-ellipsis">{label}</span>
      </span>
      <Money amount={amount} currency={currency} compact className={styles.statValue} style={coloured ? { color: tone } : undefined} />
    </div>
  );
}

export function MonthStepper({
  month,
  onPrevious,
  onNext,
  label,
  trailing,
}: {
  month: string;
  onPrevious: () => void;
  onNext: (() => void) | null;
  label?: string;
  trailing?: ReactNode;
}) {
  return (
    <div className={styles.stepper}>
      <IconButton icon="chevronLeft" label="Previous month" onClick={onPrevious} />
      <span className={styles.stepperLabel} aria-live="polite">
        {label ?? monthYear(month)}
      </span>
      <IconButton icon="chevronRight" label="Next month" onClick={onNext ?? undefined} disabled={!onNext} />
      {trailing}
    </div>
  );
}
