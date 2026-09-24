import type { ReactNode } from 'react';

import { useLongPress } from '@/hooks/useLongPress';

import {
  expenseCategoryName,
  expenseTitle,
  incomeSubtitle,
  incomeTitle,
  type Expense,
  type Income,
} from '@/domain/models';
import { relativeDay } from '@/lib/format';

import { CategoryAvatar, IncomeAvatar } from './Avatars';
import styles from './Finance.module.css';
import { Money, type AmountTone } from './Money';

type TransactionRowProps = {
  leading: ReactNode;
  title: string;
  meta: (string | null | undefined | false)[];
  amount: number;
  currency: string;
  tone: AmountTone;
  signed?: boolean;
  trailingBelow?: string;
  titleLines?: 1 | 2;
  onClick?: () => void;
  /** Long-press on touch, right-click with a mouse. */
  onLongPress?: () => void;
};

/** One line of a transaction list: avatar, title, "meta · meta", signed amount. */
export function TransactionRow({
  leading,
  title,
  meta,
  amount,
  currency,
  tone,
  signed = true,
  trailingBelow,
  titleLines = 1,
  onClick,
  onLongPress,
}: TransactionRowProps) {
  const pressHandlers = useLongPress(onLongPress);
  const parts = meta.filter((m): m is string => typeof m === 'string' && m.trim().length > 0);
  const content = (
    <>
      {leading}
      <span className={styles.txnText}>
        <span className={[styles.txnTitle, titleLines === 2 && styles.txnTitleTwoLines].filter(Boolean).join(' ')}>{title}</span>
        {parts.length ? <span className={styles.txnMeta}>{parts.join(' · ')}</span> : null}
      </span>
      <span className={styles.txnAmount}>
        <Money amount={amount} currency={currency} tone={tone} signed={signed} emphasis />
        {trailingBelow ? <span className={styles.txnBelow}>{trailingBelow}</span> : null}
      </span>
    </>
  );
  if (onClick || onLongPress) {
    return (
      <button type="button" className={styles.txn} onClick={onClick} {...pressHandlers}>
        {content}
      </button>
    );
  }
  return <div className={styles.txn}>{content}</div>;
}

export function ExpenseRow({
  expense,
  currency,
  onClick,
  showDate = true,
  sourceLabel,
}: {
  expense: Expense;
  currency: string;
  onClick?: () => void;
  showDate?: boolean;
  sourceLabel?: string | null;
}) {
  return (
    <TransactionRow
      leading={<CategoryAvatar icon={expense.category?.icon} color={expense.category?.color} />}
      title={expenseTitle(expense)}
      meta={[
        showDate && relativeDay(expense.expenseDate),
        expenseCategoryName(expense),
        sourceLabel ?? expense.paymentMethod?.name,
      ]}
      amount={-expense.amount}
      currency={currency}
      tone="negative"
      onClick={onClick}
    />
  );
}

export function IncomeRow({
  income,
  currency,
  onClick,
  showDate = true,
  destinationLabel,
}: {
  income: Income;
  currency: string;
  onClick?: () => void;
  showDate?: boolean;
  destinationLabel?: string | null;
}) {
  return (
    <TransactionRow
      leading={<IncomeAvatar />}
      title={incomeTitle(income)}
      meta={[showDate && relativeDay(income.incomeDate), incomeSubtitle(income), destinationLabel]}
      amount={income.amount}
      currency={currency}
      tone="positive"
      onClick={onClick}
    />
  );
}

export function DayHeader({
  label,
  total,
  currency,
  tone = 'neutral',
  first,
}: {
  label: string;
  total: number;
  currency: string;
  tone?: AmountTone;
  first?: boolean;
}) {
  return (
    <div className={[styles.dayHeader, first && styles.dayHeaderFirst].filter(Boolean).join(' ')}>
      <span className={styles.dayLabel}>{label}</span>
      <Money amount={total} currency={currency} compact tone={tone} className={styles.dayTotal} />
    </div>
  );
}
