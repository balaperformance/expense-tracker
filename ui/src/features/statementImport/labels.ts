import type { DuplicateMatch, StatementPeriod, StatementPeriodKind, TransactionKind, TransactionType } from '@/domain/statementImport/model';
import { TREATMENT_LABELS } from '@/domain/treatment';
import { dayMonth, dayMonthYear } from '@/lib/format';

export const KIND_LABELS: Record<TransactionKind, string> = TREATMENT_LABELS;

/** The treatment as a row shows it: a loan reads as what it is in that direction. */
export function kindLabel(kind: TransactionKind, type: TransactionType): string {
  if (kind === 'loan') return type === 'debit' ? 'Money lent' : 'Loan repayment';
  return KIND_LABELS[kind];
}

const PERIOD_KIND: Record<StatementPeriodKind, string | null> = {
  weekly: 'Weekly',
  fortnightly: 'Fortnightly',
  monthly: 'Monthly',
  custom: null,
};

export function periodLabel(period: StatementPeriod | null, kind: StatementPeriodKind): string {
  if (!period) return 'Period not stated';
  const span = period.from === period.to ? dayMonthYear(period.from) : `${dayMonth(period.from)} – ${dayMonthYear(period.to)}`;
  const named = PERIOD_KIND[kind];
  return named ? `${named} · ${span}` : span;
}

export function duplicateBadge(match: DuplicateMatch): string {
  switch (match.type) {
    case 'overlap':
      return 'In an earlier statement';
    case 'existing':
      return 'Already recorded';
    case 'nearby':
      return `Similar on ${dayMonth(match.existingDate)}`;
  }
}

export function duplicateText(match: DuplicateMatch): string {
  switch (match.type) {
    case 'overlap':
      return 'This row also appears in a statement you added earlier, so it is left out. Include it only if it really happened twice.';
    case 'existing':
      return match.strength === 'exact'
        ? `Already recorded for this account as "${match.existingLabel}" on the same day. Left out to avoid counting it twice.`
        : `An entry with the same amount on the same day is already recorded ("${match.existingLabel}"). Left out unless you include it.`;
    case 'nearby':
      return `"${match.existingLabel}" on ${dayMonthYear(match.existingDate)} has the same amount. Check it is not the same transaction.`;
  }
}
