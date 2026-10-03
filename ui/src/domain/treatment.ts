/**
 * What a bank movement is recorded as — the "Record as" choice — and the exact
 * request that makes it so. Shared by the statement import (before anything
 * is saved) and the account statement's edit sheet (after).
 *
 * Pure: it builds the JSON for `apply_bank_treatment` / `record_bank_movement`
 * (migration 005), which do every write of a change in one transaction.
 *
 *   expense        → an expense row (+ its ledger debit); may be paid for someone
 *   income         → an income row (+ its ledger credit)
 *   refund         → ledger credit only
 *   transfer       → to/from one of your accounts: both legs, linked
 *                    to a credit card: that card's bill payment
 *                    to/from cash: ledger movement only
 *   loan (out)     → ledger debit + a claim on the person — money lent
 *   loan (in)      → ledger credit that repays a loan
 *   reimbursement  → ledger credit that pays back a purchase made for someone
 *
 * Only expense and income ever reach the income and spending figures.
 */
import { daysBetween, type IsoDate } from '@/lib/dates';

import type { LedgerEntry, ReceivableKind } from './models';
import type { TransactionKind, TransactionType } from './statementImport/model';

/** Where a transfer went (money out) or came from (money in). */
export type TransferTarget =
  | { type: 'account'; accountId: string }
  /** Money out only: paying the card's bill. */
  | { type: 'card'; cardId: string }
  /** Cash, or an account not tracked here: the balance moves and nothing else. */
  | { type: 'cash' };

/** What a repayment or reimbursement pays back. */
export type SettlementTarget =
  /** A loan or a paid-for purchase already recorded. */
  | { type: 'claim'; receivableId: string; kind: ReceivableKind }
  /** A purchase not yet marked as paid for someone — marked now, for [person]. */
  | { type: 'expense'; expenseId: string }
  /** A row earlier in the same import: money lent, or an expense paid for someone. */
  | { type: 'pending'; itemId: string; kind: ReceivableKind };

export const TREATMENT_LABELS: Record<TransactionKind, string> = {
  expense: 'Expense',
  income: 'Income',
  refund: 'Refund',
  transfer: 'Transfer',
  loan: 'Loan',
  reimbursement: 'Reimbursement',
};

/** Kinds valid for a direction: money out can't be income, money in can't be an expense. */
export function kindsFor(type: TransactionType): readonly TransactionKind[] {
  return type === 'debit' ? ['expense', 'transfer', 'loan'] : ['income', 'refund', 'transfer', 'loan', 'reimbursement'];
}

/**
 * The kinds the database can store right now: loans and reimbursements need
 * migration 005 ([treatments]); without it they are not offered.
 */
export function availableKinds(type: TransactionType, treatments: boolean): readonly TransactionKind[] {
  return kindsFor(type).filter((kind) => treatments || (kind !== 'loan' && kind !== 'reimbursement'));
}

/** One line under "Record as" for the treatments that are neither income nor spending. */
export function treatmentHint(kind: TransactionKind, type: TransactionType): string | null {
  switch (kind) {
    case 'refund':
      return 'Balance only — not counted as income';
    case 'transfer':
      return 'Your own money moving — not income or spending';
    case 'loan':
      return type === 'debit' ? 'Owed back to you — not spending' : 'Repays a loan — not income';
    case 'reimbursement':
      return 'Pays back a purchase — not income';
    default:
      return null;
  }
}

/** The editable treatment of one movement, as a form holds it. */
export type TreatmentState = {
  kind: TransactionKind;
  categoryId: string | null;
  transferTarget: TransferTarget | null;
  /** Who was lent to, who was paid for, or who is paying back. */
  person: string;
  dueDate: IsoDate | null;
  note: string;
  /** An expense paid on someone else's behalf: it is owed back and is not your spending. */
  reimbursable: boolean;
  settles: SettlementTarget | null;
};

export type TreatmentProblem = 'category' | 'transferTarget' | 'loanPerson' | 'loan' | 'settles' | 'settlePerson' | 'paidForPerson';

/** The first thing missing before the treatment can be saved, or null. */
export function treatmentProblem(state: TreatmentState, type: TransactionType): TreatmentProblem | null {
  const person = state.person.trim();
  switch (state.kind) {
    case 'expense':
      if (state.categoryId == null) return 'category';
      return state.reimbursable && !person ? 'paidForPerson' : null;
    case 'transfer':
      return state.transferTarget ? null : 'transferTarget';
    case 'loan':
      if (type === 'debit') return person ? null : 'loanPerson';
      return state.settles && state.settles.type !== 'expense' && state.settles.kind === 'loan' ? null : 'loan';
    case 'reimbursement':
      if (!state.settles || (state.settles.type !== 'expense' && state.settles.kind !== 'reimbursable')) return 'settles';
      return state.settles.type === 'expense' && !person ? 'settlePerson' : null;
    default:
      return null;
  }
}

export function treatmentProblemMessage(problem: TreatmentProblem, type: TransactionType): string {
  switch (problem) {
    case 'category':
      return 'Choose a category for this expense.';
    case 'transferTarget':
      return type === 'debit' ? 'Choose where the money went.' : 'Choose where the money came from.';
    case 'loanPerson':
      return 'Add who you lent the money to.';
    case 'loan':
      return 'Choose the loan this repays.';
    case 'settles':
      return 'Choose the purchase this pays back.';
    case 'settlePerson':
      return 'Add who is paying you back.';
    case 'paidForPerson':
      return 'Add who you paid for.';
  }
}

/** What a settlement points at once same-import rows have been saved. */
export type ResolvedSettlement = { receivableId: string } | { expenseId: string; person: string } | { entryId: string };

export type TreatmentRequest = {
  kind: TransactionKind;
  direction: TransactionType;
  /** The movement's own figures; omitted ones stay as they are. */
  amount?: number;
  date?: IsoDate;
  description?: string | null;
  categoryId?: string | null;
  merchant?: string | null;
  expenseDescription?: string | null;
  notes?: string | null;
  paymentMethodId?: string | null;
  /** Paid for someone: their name; null stops it being owed back; undefined leaves it as it is. */
  reimbursablePerson?: string | null;
  source?: string | null;
  incomeDescription?: string | null;
  transferTarget?: TransferTarget | null;
  /** A row already on the other account to use as the other leg. */
  matchEntryId?: string | null;
  /** The text of a newly added other leg. */
  counterpartDescription?: string | null;
  /** When a transfer stops being one, keep its other leg as plain money in/out. */
  keepPreviousCounterpart?: boolean;
  person?: string | null;
  dueDate?: IsoDate | null;
  note?: string | null;
  settles?: ResolvedSettlement | null;
};

const text = (value: string | null | undefined) => {
  const trimmed = value?.trim();
  return trimmed ? trimmed : null;
};

/** The JSON body of `p_treatment`. Keys are only present when they mean something to the function. */
export function treatmentPayload(request: TreatmentRequest): Record<string, unknown> {
  const body: Record<string, unknown> = {};
  if (request.amount !== undefined) body.amount = Math.round(request.amount * 100) / 100;
  if (request.date !== undefined) body.date = request.date;
  if (request.description !== undefined) body.description = text(request.description);
  if (request.keepPreviousCounterpart) body.keep_previous_counterpart = true;

  switch (request.kind) {
    case 'expense':
      body.type = 'expense';
      body.category_id = request.categoryId ?? null;
      if (request.merchant !== undefined) body.merchant = text(request.merchant);
      if (request.expenseDescription !== undefined) body.expense_description = text(request.expenseDescription);
      if (request.notes !== undefined) body.notes = text(request.notes);
      if (request.paymentMethodId !== undefined) body.payment_method_id = request.paymentMethodId;
      if (request.reimbursablePerson !== undefined) {
        body.reimbursable_person = text(request.reimbursablePerson);
        if (body.reimbursable_person) {
          body.due_date = request.dueDate ?? null;
          body.note = text(request.note);
        }
      }
      return body;
    case 'income':
      body.type = 'income';
      if (request.source !== undefined) body.source = text(request.source);
      if (request.incomeDescription !== undefined) body.income_description = text(request.incomeDescription);
      return body;
    case 'refund':
      body.type = 'plain';
      return body;
    case 'transfer': {
      const target = request.transferTarget;
      if (target?.type === 'account') {
        body.type = 'transfer';
        body.counterparty_account_id = target.accountId;
        if (request.matchEntryId) body.match_entry_id = request.matchEntryId;
        if (request.counterpartDescription !== undefined) body.counterpart_description = text(request.counterpartDescription);
      } else if (target?.type === 'card' && request.direction === 'debit') {
        body.type = 'card_payment';
        body.credit_card_id = target.cardId;
      } else {
        body.type = 'plain';
      }
      return body;
    }
    case 'loan':
      if (request.direction === 'debit') {
        body.type = 'loan';
        body.person = text(request.person);
        body.due_date = request.dueDate ?? null;
        body.note = text(request.note);
        return body;
      }
      return settlementBody(body, request.settles);
    case 'reimbursement':
      return settlementBody(body, request.settles);
  }
}

function settlementBody(body: Record<string, unknown>, settles: ResolvedSettlement | null | undefined): Record<string, unknown> {
  body.type = 'settlement';
  if (!settles) return body;
  if ('receivableId' in settles) body.receivable_id = settles.receivableId;
  else if ('entryId' in settles) body.settle_entry_id = settles.entryId;
  else {
    body.settle_expense_id = settles.expenseId;
    body.person = text(settles.person);
  }
  return body;
}

/** The "Record as" choice and details of a movement already saved — what its edit sheet opens with. */
export function treatmentOfEntry(entry: LedgerEntry): Omit<TreatmentState, 'dueDate' | 'note'> {
  const base = { categoryId: null, transferTarget: null, person: '', reimbursable: false, settles: null };
  const claim = entry.claim;
  if (entry.expenseId != null) {
    const paidFor = claim?.role === 'source' && claim.kind === 'reimbursable';
    return { ...base, kind: 'expense', categoryId: entry.categoryId, reimbursable: paidFor, person: paidFor ? claim.person : '' };
  }
  if (entry.incomeId != null) return { ...base, kind: 'income' };
  if (entry.transferGroupId != null) {
    return {
      ...base,
      kind: 'transfer',
      transferTarget: entry.counterpartyAccountId ? { type: 'account', accountId: entry.counterpartyAccountId } : null,
    };
  }
  if (entry.creditCardId != null) return { ...base, kind: 'transfer', transferTarget: { type: 'card', cardId: entry.creditCardId } };
  if (claim?.role === 'source' && claim.kind === 'loan') return { ...base, kind: 'loan', person: claim.person };
  if (entry.receivableId != null) {
    const kind = claim?.kind ?? 'reimbursable';
    return {
      ...base,
      kind: kind === 'loan' ? 'loan' : 'reimbursement',
      person: claim?.person ?? '',
      settles: { type: 'claim', receivableId: entry.receivableId, kind },
    };
  }
  // A plain movement: money out with no other record went to cash or an untracked account.
  return entry.direction === 'debit' ? { ...base, kind: 'transfer', transferTarget: { type: 'cash' } } : { ...base, kind: 'refund' };
}

// ---------------------------------------------------------------------------
// Linking the other leg of a transfer
// ---------------------------------------------------------------------------

/** A movement with no other record: not a document, transfer leg, card payment or claim. */
export const isPlainMovement = (entry: LedgerEntry) =>
  entry.expenseId == null &&
  entry.incomeId == null &&
  entry.transferGroupId == null &&
  entry.creditCardId == null &&
  entry.receivableId == null &&
  entry.claim == null;

/** Banks can post the two sides of a transfer a day or two apart. */
export const TRANSFER_MATCH_DAYS = 3;

/**
 * Rows on the other account that can be this transfer's other leg: the
 * opposite direction, the same amount, within a few days, and not already a
 * transfer leg, card payment or claim. Rows recorded as an expense or income
 * qualify — when both statements were imported, the other side often was —
 * and linking one removes that record, since a transfer is neither.
 * Closest date first, then plain rows before expense or income ones.
 */
export function findTransferMatches(
  entries: readonly LedgerEntry[],
  { direction, amount, date, nearbyDays = TRANSFER_MATCH_DAYS }: { direction: 'debit' | 'credit'; amount: number; date: IsoDate; nearbyDays?: number },
): LedgerEntry[] {
  const wanted = Math.round(amount * 100);
  const distance = (e: LedgerEntry) => Math.abs(daysBetween(e.txnDate, date));
  return entries
    .filter(
      (e) =>
        e.direction !== direction &&
        Math.round(e.amount * 100) === wanted &&
        distance(e) <= nearbyDays &&
        e.transferGroupId == null &&
        e.creditCardId == null &&
        e.receivableId == null &&
        e.claim == null,
    )
    .sort((a, b) => distance(a) - distance(b) || Number(!isPlainMovement(a)) - Number(!isPlainMovement(b)) || (a.id < b.id ? -1 : 1));
}

/** How a candidate other leg is described: "Recorded as income", "Recorded as an expense", or null when plain. */
export function matchRecordedAs(entry: LedgerEntry): string | null {
  if (entry.incomeId != null) return 'recorded as income — it will no longer count as income';
  if (entry.expenseId != null) return 'recorded as an expense — it will no longer count as spending';
  return null;
}

export function sameTransferTarget(a: TransferTarget | null, b: TransferTarget | null): boolean {
  if (a == null || b == null) return a === b;
  if (a.type !== b.type) return false;
  if (a.type === 'account' && b.type === 'account') return a.accountId === b.accountId;
  if (a.type === 'card' && b.type === 'card') return a.cardId === b.cardId;
  return true;
}
