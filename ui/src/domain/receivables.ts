/**
 * Money owed to the user (migration 005): money lent, and purchases paid on
 * someone else's behalf. Pure, so every figure here is unit-tested.
 *
 * Nothing about what is owed is stored. A claim names its source — the lent
 * debit or the purchase — and repayments are ledger credits that name the
 * claim, so
 *
 *   outstanding = source amount − every repayment received
 *
 * is recalculated from the rows themselves after any edit or deletion.
 */
import { daysBetween, type IsoDate } from '@/lib/dates';
import { optStr, str, type Row } from '@/lib/row';

import type { ReceivableKind } from './models';

export type Receivable = {
  id: string;
  userId: string;
  kind: ReceivableKind;
  person: string;
  /** Money lent: the debit that paid it. */
  ledgerEntryId: string | null;
  /** Paid on someone's behalf: the purchase. */
  expenseId: string | null;
  dueDate: IsoDate | null;
  note: string | null;
  createdAt: string | null;
};

export function receivableFromRow(row: Row): Receivable {
  const due = optStr(row, 'due_date');
  return {
    id: str(row, 'id'),
    userId: str(row, 'user_id'),
    kind: row.kind === 'reimbursable' ? 'reimbursable' : 'loan',
    person: optStr(row, 'person')?.trim() || 'Someone',
    ledgerEntryId: optStr(row, 'ledger_entry_id'),
    expenseId: optStr(row, 'expense_id'),
    dueDate: due ? due.slice(0, 10) : null,
    note: optStr(row, 'note'),
    createdAt: optStr(row, 'created_at'),
  };
}

/** The money that went out for the claim, read from its own row. */
export type ClaimSource = {
  date: IsoDate;
  amount: number;
  title: string;
  /** The bank account it left, for a lent debit or a bank-funded purchase. */
  accountId: string | null;
  /** The card it was charged to, for a card purchase. */
  cardId: string | null;
  /** The bank movement behind it, when there is one (the lent debit, or a bank purchase's debit). */
  ledgerEntryId: string | null;
  expenseId: string | null;
};

/** A ledger credit received against a claim. */
export type ClaimRepayment = {
  entryId: string;
  receivableId: string;
  accountId: string;
  amount: number;
  date: IsoDate;
  description: string | null;
};

export type ClaimStatus = 'open' | 'partial' | 'settled' | 'overpaid';

export type ClaimSummary = {
  receivable: Receivable;
  /** Null only if the source row could not be read; the claim then counts nothing. */
  source: ClaimSource | null;
  principal: number;
  received: number;
  /** Below zero when more came back than went out. */
  outstanding: number;
  status: ClaimStatus;
  /** Oldest first. */
  repayments: ClaimRepayment[];
  overdue: boolean;
};

const cents = (value: number) => Math.round(value * 100);

export function claimStatus(principal: number, received: number): ClaimStatus {
  const left = cents(principal) - cents(received);
  if (left > 0) return cents(received) > 0 ? 'partial' : 'open';
  return left === 0 ? 'settled' : 'overpaid';
}

/** One summary per claim: what went out, what came back, what is left. Open claims first, then newest. */
export function summariseClaims({
  receivables,
  sources,
  repayments,
  today,
}: {
  receivables: readonly Receivable[];
  /** By receivable id. */
  sources: ReadonlyMap<string, ClaimSource>;
  repayments: readonly ClaimRepayment[];
  today: IsoDate;
}): ClaimSummary[] {
  const byClaim = new Map<string, ClaimRepayment[]>();
  for (const repayment of repayments) {
    byClaim.set(repayment.receivableId, [...(byClaim.get(repayment.receivableId) ?? []), repayment]);
  }
  const summaries = receivables.map((receivable): ClaimSummary => {
    const source = sources.get(receivable.id) ?? null;
    const received = (byClaim.get(receivable.id) ?? []).sort((a, b) => (a.date < b.date ? -1 : a.date > b.date ? 1 : 0));
    const principal = source?.amount ?? 0;
    const receivedTotal = received.reduce((sum, r) => sum + cents(r.amount), 0) / 100;
    const status = claimStatus(principal, receivedTotal);
    return {
      receivable,
      source,
      principal,
      received: receivedTotal,
      outstanding: (cents(principal) - cents(receivedTotal)) / 100,
      status,
      repayments: received,
      overdue: isOpen(status) && receivable.dueDate != null && receivable.dueDate < today,
    };
  });
  return summaries.sort((a, b) => {
    const open = Number(isOpen(b.status)) - Number(isOpen(a.status));
    if (open !== 0) return open;
    const aDate = a.source?.date ?? '';
    const bDate = b.source?.date ?? '';
    return aDate < bDate ? 1 : aDate > bDate ? -1 : 0;
  });
}

export const isOpen = (status: ClaimStatus) => status === 'open' || status === 'partial';

/** "Loan to Arun" / "Paid for Arun". */
export function claimTitle(claim: Pick<Receivable, 'kind' | 'person'>): string {
  return claim.kind === 'loan' ? `Loan to ${claim.person}` : `Paid for ${claim.person}`;
}

export const CLAIM_STATUS_LABELS: Record<ClaimStatus, string> = {
  open: 'Not repaid yet',
  partial: 'Partly repaid',
  settled: 'Settled',
  overpaid: 'Overpaid',
};

/** The same person however it was typed: "arun " and "Arun" are one. */
export const personKey = (name: string | null | undefined) => (name ?? '').trim().replace(/\s+/g, ' ').toLowerCase();

/** Everyone the user has a claim with, spelled as they last wrote it, most recent first. */
export function knownPeople(claims: readonly ClaimSummary[]): string[] {
  const seen = new Map<string, { name: string; date: string }>();
  for (const claim of claims) {
    const key = personKey(claim.receivable.person);
    const date = claim.source?.date ?? claim.receivable.createdAt ?? '';
    const known = seen.get(key);
    if (!known || date > known.date) seen.set(key, { name: claim.receivable.person, date });
  }
  return [...seen.values()].sort((a, b) => (a.date < b.date ? 1 : a.date > b.date ? -1 : 0)).map((p) => p.name);
}

export type PersonBalance = { person: string; outstanding: number; open: number; claims: ClaimSummary[] };

/** "arun" and "Arun" are one person; the capitalised spelling is the one shown. */
function preferredSpelling(current: string, other: string): string {
  const capital = (name: string) => /^\p{Lu}/u.test(name.trim());
  return !capital(current) && capital(other) ? other.trim() : current.trim();
}

/** Claims grouped by person, those owing the most first. */
export function balancesByPerson(claims: readonly ClaimSummary[]): PersonBalance[] {
  const groups = new Map<string, PersonBalance>();
  for (const claim of claims) {
    const key = personKey(claim.receivable.person);
    const group = groups.get(key) ?? { person: claim.receivable.person.trim(), outstanding: 0, open: 0, claims: [] };
    group.person = preferredSpelling(group.person, claim.receivable.person);
    group.claims.push(claim);
    if (isOpen(claim.status)) {
      group.outstanding = (cents(group.outstanding) + cents(claim.outstanding)) / 100;
      group.open += 1;
    }
    groups.set(key, group);
  }
  return [...groups.values()].sort((a, b) => b.outstanding - a.outstanding || a.person.localeCompare(b.person));
}

/** Total still owed across open claims. */
export function totalOutstanding(claims: readonly ClaimSummary[]): number {
  return claims.filter((c) => isOpen(c.status)).reduce((sum, c) => sum + cents(c.outstanding), 0) / 100;
}

/**
 * What would be left on [claim] after [amount] more comes back. [excludeEntryId]
 * leaves out a repayment already counted (the one being edited), and
 * [pendingElsewhere] adds repayments waiting in the same import.
 */
export function outstandingAfter(
  claim: Pick<ClaimSummary, 'principal' | 'repayments'>,
  amount: number,
  { excludeEntryId = null, pendingElsewhere = 0 }: { excludeEntryId?: string | null; pendingElsewhere?: number } = {},
): number {
  const counted = claim.repayments.filter((r) => r.entryId !== excludeEntryId).reduce((sum, r) => sum + cents(r.amount), 0);
  return (cents(claim.principal) - counted - cents(pendingElsewhere) - cents(amount)) / 100;
}

export function dueText(claim: ClaimSummary, today: IsoDate): string | null {
  const due = claim.receivable.dueDate;
  if (!due || !isOpen(claim.status)) return null;
  const days = daysBetween(today, due);
  if (days < 0) return `Overdue by ${-days} ${days === -1 ? 'day' : 'days'}`;
  if (days === 0) return 'Due today';
  return `Due in ${days} ${days === 1 ? 'day' : 'days'}`;
}
