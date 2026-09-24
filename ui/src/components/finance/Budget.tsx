import type { CSSProperties } from 'react';

import { Icon } from '@/components/ui/Icon';
import { Card } from '@/components/ui/Surface';
import {
  budgetIsApproaching,
  budgetIsOver,
  budgetRatio,
  budgetRemaining,
  type BudgetProgress,
} from '@/domain/analytics';
import { budgetLabel } from '@/domain/models';
import { formatPercent } from '@/lib/format';

import { CategoryAvatar } from './Avatars';
import styles from './Finance.module.css';
import { Money } from './Money';

function budgetTone(progress: BudgetProgress): string {
  if (budgetIsOver(progress)) return 'var(--expense)';
  if (budgetIsApproaching(progress)) return 'var(--warning)';
  return 'var(--income)';
}

/** A soft track with a filled share, grown in once (never looped). */
export function ProgressTrack({ ratio, tone }: { ratio: number; tone: string }) {
  const clamped = Math.min(Math.max(ratio, 0), 1);
  return (
    <div className={styles.bar} style={{ '--tone': tone } as CSSProperties} role="presentation">
      <span className={styles.barFill} style={{ width: `${clamped * 100}%` }} />
    </div>
  );
}

export function BudgetCard({
  progress,
  currency,
  onClick,
  showAvatar = true,
}: {
  progress: BudgetProgress;
  currency: string;
  onClick?: () => void;
  showAvatar?: boolean;
}) {
  const tone = budgetTone(progress);
  const ratio = budgetRatio(progress);
  const over = budgetIsOver(progress);
  const body = (
    <div className={styles.budget} style={{ '--tone': tone } as CSSProperties}>
      <div className={styles.budgetHead}>
        {showAvatar ? (
          <CategoryAvatar icon={progress.budget.category?.icon ?? 'savings'} color={progress.budget.category?.color} size={30} />
        ) : null}
        <span className={styles.budgetName}>{budgetLabel(progress.budget)}</span>
        <span className={styles.budgetPercent}>{formatPercent(ratio)}</span>
      </div>
      <ProgressTrack ratio={ratio} tone={tone} />
      <div className={styles.budgetFoot}>
        <span>
          <Money amount={progress.spent} currency={currency} compact /> of{' '}
          <Money amount={progress.budget.amount} currency={currency} compact />
        </span>
        <span className={styles.budgetLeft}>
          <Money amount={Math.abs(budgetRemaining(progress))} currency={currency} compact /> {over ? 'over' : 'left'}
        </span>
      </div>
    </div>
  );
  return (
    <Card padding="flush" onClick={onClick} ariaLabel={onClick ? `${budgetLabel(progress.budget)} budget` : undefined}>
      {body}
    </Card>
  );
}

export function BudgetAlertBanner({ alerts, onClick }: { alerts: BudgetProgress[]; onClick?: () => void }) {
  const [first] = alerts;
  if (!first) return null;
  const anyOver = alerts.some(budgetIsOver);
  const tone = anyOver ? 'var(--expense)' : 'var(--warning)';
  const message =
    alerts.length === 1
      ? `${budgetIsOver(first) ? 'Over' : 'Close to'} your ${budgetLabel(first.budget).toLowerCase()}`
      : `${alerts.length} budgets need attention`;
  const content = (
    <>
      <Icon name={anyOver ? 'warning' : 'info'} size={20} />
      <span className="grow">{message}</span>
      {onClick ? <Icon name="chevronRight" size={20} /> : null}
    </>
  );
  return onClick ? (
    <button type="button" className={styles.alert} style={{ '--tone': tone } as CSSProperties} onClick={onClick}>
      {content}
    </button>
  ) : (
    <div className={styles.alert} style={{ '--tone': tone } as CSSProperties} role="status">
      {content}
    </div>
  );
}
