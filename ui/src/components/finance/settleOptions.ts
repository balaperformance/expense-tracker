/**
 * The choices offered when a repayment or reimbursement is matched to what it
 * pays back: claims already recorded, rows earlier in the same import, and
 * purchases not yet marked as paid for anyone.
 */
import { cardLabel, expenseTitle, type CreditCard, type Expense } from '@/domain/models';
import { isOpen, personKey, type ClaimSummary } from '@/domain/receivables';
import { pendingClaimsFor, type ReviewItem } from '@/domain/statementImport/review';
import type { SettlementTarget } from '@/domain/treatment';
import { dayMonth, formatCurrency } from '@/lib/format';

/** One thing a repayment or reimbursement can pay back. */
export type SettleOption = {
  key: string;
  target: SettlementTarget;
  label: string;
  /** The person it is with, when known (a purchase not yet paid for anyone has none). */
  person: string | null;
  /** What went out. */
  principal: number;
  /** What has come back already, not counting this movement. */
  received: number;
};

export const settleKey = (target: SettlementTarget | null) =>
  target == null
    ? ''
    : target.type === 'claim'
      ? `claim:${target.receivableId}`
      : target.type === 'pending'
        ? `pending:${target.itemId}`
        : `expense:${target.expenseId}`;

const cents = (value: number) => Math.round(value * 100);

/**
 * Open claims of [kind], plus the one [current] points at even if settled.
 * [excludeEntryId] is the movement being edited — its own earlier amount is not
 * counted as already received. [pendingElsewhere] adds repayments waiting in
 * the same import, by receivable id.
 */
export function claimOptions({
  claims,
  kind,
  current,
  excludeEntryId = null,
  pendingElsewhere,
  currency,
}: {
  claims: readonly ClaimSummary[];
  kind: 'loan' | 'reimbursable';
  current: SettlementTarget | null;
  excludeEntryId?: string | null;
  pendingElsewhere?: ReadonlyMap<string, number>;
  currency: string;
}): SettleOption[] {
  const currentId = current?.type === 'claim' ? current.receivableId : null;
  return claims
    .filter((c) => c.receivable.kind === kind && c.source != null && (isOpen(c.status) || c.receivable.id === currentId))
    .map((c) => {
      const counted = c.repayments.filter((r) => r.entryId !== excludeEntryId).reduce((sum, r) => sum + cents(r.amount), 0);
      const received = (counted + cents(pendingElsewhere?.get(c.receivable.id) ?? 0)) / 100;
      const left = (cents(c.principal) - cents(received)) / 100;
      const what = kind === 'loan' ? `lent ${dayMonth(c.source?.date ?? '')}` : `${c.source?.title ?? 'purchase'} · ${dayMonth(c.source?.date ?? '')}`;
      return {
        key: settleKey({ type: 'claim', receivableId: c.receivable.id, kind }),
        target: { type: 'claim', receivableId: c.receivable.id, kind },
        label: `${c.receivable.person} · ${formatCurrency(left, currency)} left of ${formatCurrency(c.principal, currency)} · ${what}`,
        person: c.receivable.person,
        principal: c.principal,
        received,
      };
    });
}

/** Rows earlier in this import that a later one can pay back. */
export function pendingOptions({
  items,
  kind,
  exceptId,
  pendingElsewhere,
  currency,
}: {
  items: readonly ReviewItem[];
  kind: 'loan' | 'reimbursable';
  exceptId: string;
  pendingElsewhere: ReadonlyMap<string, number>;
  currency: string;
}): SettleOption[] {
  return pendingClaimsFor(items, kind)
    .filter((i) => i.id !== exceptId)
    .map((i) => ({
      key: settleKey({ type: 'pending', itemId: i.id, kind }),
      target: { type: 'pending', itemId: i.id, kind },
      label: `${i.person.trim()} · ${formatCurrency(i.amount, currency)} · ${dayMonth(i.transactionDate)} · in this statement`,
      person: i.person.trim(),
      principal: i.amount,
      received: pendingElsewhere.get(i.id) ?? 0,
    }));
}

/** Purchases not yet marked as paid for anyone — choosing one marks it. Card purchases first. */
export function purchaseOptions({
  purchases,
  claims,
  cards,
  currency,
}: {
  purchases: readonly Expense[];
  claims: readonly ClaimSummary[];
  cards: readonly CreditCard[];
  currency: string;
}): SettleOption[] {
  const claimed = new Set(claims.map((c) => c.receivable.expenseId).filter(Boolean));
  return purchases
    .filter((e) => !claimed.has(e.id))
    .sort((a, b) => Number(b.creditCardId != null) - Number(a.creditCardId != null))
    .map((e) => {
      const card = e.creditCardId ? cards.find((c) => c.id === e.creditCardId) : undefined;
      return {
        key: settleKey({ type: 'expense', expenseId: e.id }),
        target: { type: 'expense', expenseId: e.id },
        label: `${dayMonth(e.expenseDate)} · ${expenseTitle(e)} · ${formatCurrency(e.amount, currency)}${card ? ` · ${cardLabel(card)}` : ''}`,
        person: null,
        principal: e.amount,
        received: 0,
      };
    });
}

/** Options for [person] first, so the right loan or purchase is near the top. */
export function byPersonFirst(options: readonly SettleOption[], person: string): SettleOption[] {
  const key = personKey(person);
  if (!key) return [...options];
  return [...options].sort((a, b) => Number(personKey(b.person) === key) - Number(personKey(a.person) === key));
}
