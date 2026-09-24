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
  bankTotal: number | null;
  bankTotalHidden: boolean;
  onToggleBankTotal: () => void;
};

/**
 * The dashboard's Net hero. The corner glow stays a neutral blue-gray
 * whichever way the month went: the figure's sign carries the direction, and
 * green belongs to Income alone.
 */
export function BalanceCard({ income, expense, currency, monthLabel, bankTotal, bankTotalHidden, onToggleBankTotal }: BalanceCardProps) {
  const net = income - expense;
  const share = income > 0 ? expense / income : 0;
  return (
    <Hero glow="var(--hero-glow)">
      <div className={styles.eyebrowRow}>
        <span className="t-eyebrow grow" style={{ color: 'var(--hero-accent)' }}>
          Net this month
        </span>
        <span className={styles.heroBadge}>{monthLabel}</span>
      </div>
      <div className={styles.net}>
        <Money amount={net} currency={currency} signed={net !== 0} animate />
      </div>
      {income > 0 ? (
        <div className={styles.spendBar} role="img" aria-label={`Spent ${Math.round(share * 100)} percent of income`}>
          <span className={styles.barFill} style={{ width: `${Math.min(share, 1) * 100}%`, background: 'var(--expense)' }} />
        </div>
      ) : null}
      <div className={styles.legs}>
        <Leg label="Income" amount={income} currency={currency} tone="var(--income)" icon="moneyIn" />
        <Leg label="Expenses" amount={expense} currency={currency} tone="var(--expense)" icon="moneyOut" />
      </div>
      {bankTotal != null ? (
        <div className={styles.bankLine}>
          <Icon name="bankSolid" size={16} color="var(--hero-accent)" />
          <span className="grow">In bank accounts</span>
          <Money amount={bankTotal} currency={currency} obscured={bankTotalHidden} />
          <IconButton
            icon={bankTotalHidden ? 'eye' : 'eyeOff'}
            label={bankTotalHidden ? 'Show balance' : 'Hide balance'}
            small
            color="var(--muted)"
            iconSize={18}
            onClick={onToggleBankTotal}
          />
        </div>
      ) : null}
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
