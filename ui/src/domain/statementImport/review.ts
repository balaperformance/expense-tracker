/**
 * The review step as pure state: what the user sees, selects and edits
 * before anything is written. The screen renders this; it does not decide it.
 */
import type { IsoDate } from '@/lib/dates';

import type { ExpenseCategory } from '../models';
import { personKey } from '../receivables';
import { categoryByName, fallbackCategory } from '../sms/smsDraft';
import {
  kindsFor,
  sameTransferTarget,
  treatmentProblem,
  treatmentProblemMessage,
  type SettlementTarget,
  type TransferTarget,
  type TreatmentProblem,
  type TreatmentState,
} from '../treatment';

import { fingerprintOf, isBlockingDuplicate } from './duplicates';
import { AUTO_SELECT_CONFIDENCE, type NormalizedTransaction, type TransactionKind, type TransactionType } from './model';

export { kindsFor };

/** A row already on the other account, chosen as this transfer's other leg. */
export type TransferMatch = { entryId: string; label: string };

export type ReviewItem = NormalizedTransaction & {
  selected: boolean;
  /** The user's own category, for expenses. */
  categoryId: string | null;
  /** The user chose to import a row flagged as a duplicate. */
  duplicateOverridden: boolean;
  edited: boolean;
  /** Transfer: the other side. Null until known — then it is imported as balance only. */
  transferTarget: TransferTarget | null;
  /**
   * Transfer to an account: the row to link as the other leg, or 'new' to add
   * one. Null leaves it to the import, which links a single exact match.
   */
  transferMatch: TransferMatch | 'new' | null;
  /** Who was lent to, who was paid for, or who is paying back. */
  person: string;
  dueDate: IsoDate | null;
  note: string;
  /** An expense paid on someone else's behalf: owed back, not personal spending. */
  reimbursable: boolean;
  /** A repayment or reimbursement: what it pays back. */
  settles: SettlementTarget | null;
};

export function toReviewItems(transactions: readonly NormalizedTransaction[], categories: readonly ExpenseCategory[]): ReviewItem[] {
  const fallback = fallbackCategory(categories);
  return transactions.map((t) => ({
    ...t,
    categoryId: t.kind === 'expense' ? (categoryByName(categories, t.category)?.id ?? fallback?.id ?? null) : null,
    selected: !isBlockingDuplicate(t.duplicate) && t.confidence >= AUTO_SELECT_CONFIDENCE,
    duplicateOverridden: false,
    edited: false,
    transferTarget: t.transferTarget ?? (t.creditCardId ? { type: 'card', cardId: t.creditCardId } : null),
    transferMatch: null,
    person: '',
    dueDate: null,
    note: '',
    reimbursable: false,
    settles: null,
  }));
}

export type ReviewEdit = Partial<{
  transactionDate: IsoDate;
  description: string;
  amount: number;
  transactionType: TransactionType;
  kind: TransactionKind;
  categoryId: string | null;
  /** Income source label. */
  category: string | null;
  /** Payee / payer — stored as the expense merchant. */
  counterparty: string | null;
  /** The account the row belongs to. Only rows of a multi-account statement can move. */
  bankAccountId: string;
  /** "HH:mm". */
  transactionTime: string | null;
  /** The statement's note, written to the expense's Notes. */
  notes: string | null;
  tags: readonly string[];
  transferTarget: TransferTarget | null;
  transferMatch: TransferMatch | 'new' | null;
  person: string;
  dueDate: IsoDate | null;
  note: string;
  reimbursable: boolean;
  settles: SettlementTarget | null;
}>;

export type ReviewAction =
  | { type: 'toggle'; id: string }
  | { type: 'setSelected'; ids: readonly string[]; selected: boolean }
  | { type: 'edit'; id: string; patch: ReviewEdit }
  /** The same treatment for several rows at once ("apply to similar"). */
  | { type: 'editMany'; ids: readonly string[]; patch: ReviewEdit }
  | { type: 'remove'; id: string }
  | { type: 'append'; items: readonly ReviewItem[] }
  | { type: 'replace'; items: readonly ReviewItem[] }
  /** Fresh duplicate flags (e.g. after a retried ledger check). */
  | { type: 'applyDuplicates'; marked: readonly NormalizedTransaction[] };

function applyEdit(item: ReviewItem, patch: ReviewEdit): ReviewItem {
  const next: ReviewItem = { ...item, ...patch, edited: true };
  if (patch.transactionType && !kindsFor(next.transactionType).includes(next.kind)) {
    next.kind = next.transactionType === 'debit' ? 'expense' : 'income';
  }
  // Details that only fit one direction do not survive a switch.
  if (next.transactionType === 'credit') {
    if (next.transferTarget?.type === 'card') next.transferTarget = null;
    next.reimbursable = false;
  } else if (next.settles) {
    next.settles = null;
  }
  // A card bill is the transfer target "card"; keep the classifier's field in step.
  if (patch.transferTarget !== undefined || patch.transactionType !== undefined) {
    next.creditCardId = next.transferTarget?.type === 'card' ? next.transferTarget.cardId : null;
  }
  if (patch.categoryId !== undefined) next.categorySource = 'user';
  const accountChanged = patch.bankAccountId !== undefined && patch.bankAccountId !== item.bankAccountId;
  if (accountChanged) {
    next.accountStatus = 'chosen';
    // A transfer cannot go to the account it is on.
    if (next.transferTarget?.type === 'account' && next.transferTarget.accountId === next.bankAccountId) next.transferTarget = null;
  }
  const identityChanged =
    patch.transactionDate !== undefined || patch.amount !== undefined || patch.transactionType !== undefined || accountChanged;
  // A chosen other leg only fits the account, amount and date it was found for.
  if (
    patch.transferMatch === undefined &&
    (identityChanged || (patch.transferTarget !== undefined && !sameTransferTarget(patch.transferTarget, item.transferTarget)))
  ) {
    next.transferMatch = null;
  }
  if (identityChanged) {
    next.fingerprint = fingerprintOf(next);
    // The import re-checks against the ledger before writing, so an edit that
    // now matches a recorded row is still caught.
    next.duplicate = null;
    next.duplicateOverridden = false;
  }
  return next;
}

/** Rows that pointed at [ids] as the loan or purchase they repay no longer can. */
function withoutPendingLinks(items: ReviewItem[], ids: ReadonlySet<string>): ReviewItem[] {
  return items.map((item) =>
    item.settles?.type === 'pending' && ids.has(item.settles.itemId) ? { ...item, settles: null } : item,
  );
}

export function reviewReducer(items: ReviewItem[], action: ReviewAction): ReviewItem[] {
  switch (action.type) {
    case 'toggle':
      return items.map((item) =>
        item.id === action.id
          ? { ...item, selected: !item.selected, duplicateOverridden: !item.selected && isBlockingDuplicate(item.duplicate) }
          : item,
      );
    case 'setSelected': {
      const ids = new Set(action.ids);
      return items.map((item) =>
        ids.has(item.id)
          ? { ...item, selected: action.selected, duplicateOverridden: action.selected && isBlockingDuplicate(item.duplicate) }
          : item,
      );
    }
    case 'edit':
    case 'editMany': {
      const ids = new Set(action.type === 'edit' ? [action.id] : action.ids);
      const edited = items.map((item) => (ids.has(item.id) ? applyEdit(item, action.patch) : item));
      // A row that stopped being money lent (or a purchase paid for someone) can no longer be repaid.
      const stale = new Set(edited.filter((item) => ids.has(item.id) && !pendingKindOf(item)).map((item) => item.id));
      return stale.size ? withoutPendingLinks(edited, stale) : edited;
    }
    case 'remove':
      return withoutPendingLinks(
        items.filter((item) => item.id !== action.id),
        new Set([action.id]),
      );
    case 'append':
      return [...items, ...action.items];
    case 'replace':
      return [...action.items];
    case 'applyDuplicates': {
      const byId = new Map(action.marked.map((t) => [t.id, t.duplicate]));
      return items.map((item) => {
        if (!byId.has(item.id)) return item;
        const duplicate = byId.get(item.id) ?? null;
        // A newly found duplicate is deselected — unless the user already chose to import it.
        const newlyBlocking = isBlockingDuplicate(duplicate) && !isBlockingDuplicate(item.duplicate) && !item.duplicateOverridden;
        return { ...item, duplicate, selected: newlyBlocking ? false : item.selected };
      });
    }
  }
}

// ---------------------------------------------------------------------------
// Treatment details
// ---------------------------------------------------------------------------

/** The item's treatment in the shape the shared rules and fields use. */
export function reviewTreatment(item: ReviewItem): TreatmentState {
  return {
    kind: item.kind,
    categoryId: item.categoryId,
    transferTarget: item.transferTarget,
    person: item.person,
    dueDate: item.dueDate,
    note: item.note,
    reimbursable: item.reimbursable,
    settles: item.settles,
  };
}

/** What a row can lack: a treatment detail, or — on a multi-account statement — its account. */
export type ReviewProblem = TreatmentProblem | 'account';

/**
 * What the item still needs before it can be imported as chosen. A row whose
 * account could not be matched needs one first. A missing category is not
 * counted (the fallback category covers it); a transfer with no other side is
 * reported but still imports, as balance only.
 */
export function detailProblem(item: ReviewItem): ReviewProblem | null {
  if (!item.bankAccountId) return 'account';
  const problem = treatmentProblem(reviewTreatment(item), item.transactionType);
  return problem === 'category' ? null : problem;
}

export function reviewProblemMessage(problem: ReviewProblem, type: TransactionType): string {
  if (problem === 'account') return type === 'debit' ? 'Choose the account it was paid from.' : 'Choose the account it was received in.';
  return treatmentProblemMessage(problem, type);
}

/** Money lent, or a purchase paid for someone, that a later row in the same import may repay. */
export function pendingKindOf(item: ReviewItem): 'loan' | 'reimbursable' | null {
  if (item.transactionType !== 'debit' || !item.person.trim()) return null;
  if (item.kind === 'loan') return 'loan';
  if (item.kind === 'expense' && item.reimbursable) return 'reimbursable';
  return null;
}

/** Rows of this import that [item] could pay back — selected, and of the right kind. */
export function pendingClaimsFor(items: readonly ReviewItem[], kind: 'loan' | 'reimbursable'): ReviewItem[] {
  return items.filter((i) => i.selected && pendingKindOf(i) === kind);
}

/** Repayments in this import already pointing at a claim, by claim key (receivable id or item id). */
export function pendingRepayments(items: readonly ReviewItem[], exceptItemId: string | null): Map<string, number> {
  const totals = new Map<string, number>();
  for (const item of items) {
    if (!item.selected || item.id === exceptItemId || !item.settles || item.settles.type === 'expense') continue;
    const key = item.settles.type === 'claim' ? item.settles.receivableId : item.settles.itemId;
    totals.set(key, Math.round(((totals.get(key) ?? 0) + item.amount) * 100) / 100);
  }
  return totals;
}

const similarityKey = (item: ReviewItem) => personKey(item.counterparty);

/**
 * Other rows that look like the same payee in the same direction — the ones
 * "apply to similar" would change. Only rows with a known payee qualify, and
 * duplicates are left alone.
 */
export function similarItems(items: readonly ReviewItem[], item: ReviewItem): ReviewItem[] {
  const key = similarityKey(item);
  if (!key) return [];
  return items.filter(
    (other) =>
      other.id !== item.id &&
      other.transactionType === item.transactionType &&
      !isBlockingDuplicate(other.duplicate) &&
      similarityKey(other) === key,
  );
}

// ---------------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------------

export type ReviewSummary = {
  total: number;
  income: { count: number; amount: number };
  expense: { count: number; amount: number };
  refunds: number;
  transfers: number;
  /** Money lent, repayments and reimbursements. */
  loans: number;
  duplicates: number;
  nearby: number;
  uncategorized: number;
  needsAttention: number;
  /** Rows whose treatment is missing a detail (who, which account, which loan). */
  needsDetail: number;
  selected: number;
};

/** An expense whose category the rules could not work out and the user has not chosen. */
export const isUncategorized = (item: ReviewItem) =>
  item.kind === 'expense' && (item.categoryId == null || item.categorySource === 'fallback' || item.categorySource === 'none');

export const needsAttention = (item: ReviewItem) => item.confidence < AUTO_SELECT_CONFIDENCE || item.issues.length > 0;

export function summarize(items: readonly ReviewItem[]): ReviewSummary {
  const summary: ReviewSummary = {
    total: items.length,
    income: { count: 0, amount: 0 },
    expense: { count: 0, amount: 0 },
    refunds: 0,
    transfers: 0,
    loans: 0,
    duplicates: 0,
    nearby: 0,
    uncategorized: 0,
    needsAttention: 0,
    needsDetail: 0,
    selected: 0,
  };
  for (const item of items) {
    if (item.selected) summary.selected += 1;
    // Everything below describes the unique transactions; duplicates are counted on their own.
    if (isBlockingDuplicate(item.duplicate)) {
      summary.duplicates += 1;
      continue;
    }
    if (item.duplicate?.type === 'nearby') summary.nearby += 1;
    if (item.kind === 'income') {
      summary.income.count += 1;
      summary.income.amount += item.amount;
    } else if (item.kind === 'expense') {
      summary.expense.count += 1;
      summary.expense.amount += item.amount;
    } else if (item.kind === 'refund') summary.refunds += 1;
    else if (item.kind === 'transfer') summary.transfers += 1;
    else summary.loans += 1;
    if (isUncategorized(item)) summary.uncategorized += 1;
    if (needsAttention(item)) summary.needsAttention += 1;
    if (detailProblem(item)) summary.needsDetail += 1;
  }
  summary.income.amount = Math.round(summary.income.amount * 100) / 100;
  summary.expense.amount = Math.round(summary.expense.amount * 100) / 100;
  return summary;
}
