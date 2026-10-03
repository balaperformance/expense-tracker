import type { CSSProperties } from 'react';

import { ProgressTrack } from '@/components/finance/Budget';
import { Icon, type IconName } from '@/components/ui/Icon';
import { dueStatusText, dueSummaryText, type CardSummary } from '@/domain/creditCards';

import styles from './CreditCards.module.css';

/** Utilisation colour: calm below 30%, a caution from 70%, the expense colour from 90%. */
function utilisationTone(utilisation: number): string {
  if (utilisation >= 0.9) return 'var(--expense)';
  if (utilisation >= 0.7) return 'var(--warning)';
  if (utilisation >= 0.3) return 'var(--accent)';
  return 'var(--income)';
}

function dueTone(summary: CardSummary): { tone: string; icon: IconName } {
  const due = summary.lastStatement;
  switch (due.status) {
    case 'overdue':
      return { tone: 'var(--expense)', icon: 'warning' };
    case 'due':
      return { tone: due.daysToDue <= 3 ? 'var(--warning)' : 'var(--primary)', icon: 'calendar' };
    case 'paid':
      return { tone: 'var(--income)', icon: 'checkCircle' };
    case 'nothingDue':
      return { tone: 'var(--muted)', icon: 'checkCircle' };
  }
}

/** How much of the limit is used, coloured by how close it is to the limit. */
export function UtilisationTrack({ ratio }: { ratio: number }) {
  return <ProgressTrack ratio={ratio} tone={utilisationTone(ratio)} />;
}

export function DueLine({ summary, currency }: { summary: CardSummary; currency: string }) {
  const { tone, icon } = dueTone(summary);
  const status = summary.lastStatement.status;
  return (
    <div className={styles.due} style={{ '--tone': tone } as CSSProperties}>
      <Icon name={icon} size={16} />
      <span className={`${styles.dueText} t-ellipsis`}>{dueSummaryText(summary, currency)}</span>
      {status === 'due' || status === 'overdue' ? <span className={styles.dueStatus}>{dueStatusText(summary.lastStatement)}</span> : null}
    </div>
  );
}
