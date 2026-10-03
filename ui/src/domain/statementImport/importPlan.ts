/**
 * From confirmed review items to the exact writes, decided before any write
 * happens. Each kind goes where the rest of the app already expects it:
 *
 *   expense  → expenses row with bank_account_id (its ledger debit follows)
 *   income   → income row with bank_account_id  (its ledger credit follows)
 *   refund   → ledger credit only — balance right, not counted as income
 *   transfer → to cash / untracked: ledger movement only — not spending
 *              to a card: one debit linked as that card's bill payment
 *              to / from one of your accounts: both legs, as one write
 *   loan, reimbursement, expense paid for someone
 *            → one write each through record_bank_movement (migration 005),
 *              which saves the movement and its claim or link together
 */
import type { IsoDate } from '@/lib/dates';
import { MAX_AMOUNT } from '@/lib/validators';

import type { PaymentMethod } from '../models';
import { transferDescription } from '../transfer';
import type { ResolvedSettlement, TreatmentRequest } from '../treatment';

import { isBlockingDuplicate, markDuplicates } from './duplicates';
import type { ExistingMovement, MovementDetails, TransactionChannel, TransactionType } from './model';
import { detailProblem, pendingKindOf, reviewProblemMessage, type ReviewItem } from './review';

/** Written to expenses.notes so an imported row can always be told apart. */
export const STATEMENT_NOTE = 'Imported from bank statement';

/**
 * Every write carries what the statement printed beyond the figures (its
 * reference, the UPI ID, the time) for the movement's ledger row — set only
 * when migration 007 can store it.
 */
type WithDetails = { details?: MovementDetails };

export type ImportOperation =
  | ({
      type: 'expense';
      itemId: string;
      bankAccountId: string;
      amount: number;
      date: IsoDate;
      categoryId: string;
      /** The payee, shown as the expense title; the full narration stays in description. */
      merchant: string | null;
      paymentMethodId: string | null;
      description: string;
      notes: string | null;
      /** Tag names, found or created for the user when written (migration 006). */
      tags?: string[];
    } & WithDetails)
  | ({
      type: 'income';
      itemId: string;
      bankAccountId: string;
      amount: number;
      date: IsoDate;
      source: string | null;
      description: string;
      tags?: string[];
    } & WithDetails)
  | ({
      type: 'movement';
      itemId: string;
      bankAccountId: string;
      amount: number;
      date: IsoDate;
      direction: TransactionType;
      description: string;
      /** A recognised card bill: written as one bank debit linked to this card, never an expense. */
      creditCardId?: string | null;
    } & WithDetails)
  | ({
      /**
       * Both legs of a transfer to one of your accounts, as one insert — used
       * when migration 005 (which can also link a row already there) is absent.
       */
      type: 'transfer';
      itemId: string;
      bankAccountId: string;
      counterpartyAccountId: string;
      amount: number;
      date: IsoDate;
      direction: TransactionType;
      description: string;
      counterpartDescription: string;
    } & WithDetails)
  | ({
      /** A movement saved together with its treatment, in one transaction. */
      type: 'treatment';
      itemId: string;
      bankAccountId: string;
      amount: number;
      date: IsoDate;
      direction: TransactionType;
      /** The movement's own text on this account's statement. */
      description: string;
      request: TreatmentRequest;
      /** Repays a row of this same import: resolved to that row's saved movement when written. */
      settlesItemId?: string | null;
      /** A transfer to an account with no other leg chosen: link a single exact match if there is one. */
      autoMatch?: boolean;
      /** For an expense paid for someone: its tags. */
      tags?: string[];
    } & WithDetails);

export type SkippedItem = { itemId: string; reason: string };

export type ImportPlan = { operations: ImportOperation[]; skipped: SkippedItem[] };

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

export function statementNote(reference: string | null): string {
  return reference ? `${STATEMENT_NOTE} · ref ${reference}` : STATEMENT_NOTE;
}

/** A channel names the user's own payment method, matched by name — never created. */
const CHANNEL_PAYMENT_METHOD: Partial<Record<TransactionChannel, readonly string[]>> = {
  upi: ['UPI'],
  card: ['Debit Card'],
  neft: ['Net Banking'],
  imps: ['Net Banking'],
  rtgs: ['Net Banking'],
};

function paymentMethodFor(channel: TransactionChannel | null, methods: readonly PaymentMethod[]): string | null {
  const names = channel ? CHANNEL_PAYMENT_METHOD[channel] : undefined;
  if (!names) return null;
  return methods.find((m) => names.some((n) => n.toLowerCase() === m.name.trim().toLowerCase()))?.id ?? null;
}

const clean = (value: string | null | undefined) => (value?.trim() ? value.trim() : null);

/** What the statement printed beyond the figures, or null when it printed none of it. */
function detailsOf(item: ReviewItem): MovementDetails | null {
  const details: MovementDetails = { reference: clean(item.reference), upiId: clean(item.upiId), time: item.transactionTime ?? null };
  return details.reference || details.upiId || details.time ? details : null;
}

/**
 * For a statement with its own notes (Paytm): the note, plus — only while the
 * database cannot keep them elsewhere — the UPI reference and ID, and the tags,
 * so nothing the statement printed is lost.
 */
function statementNotes(item: ReviewItem, { storeDetails, storeTags }: { storeDetails: boolean; storeTags: boolean }): string[] {
  const details = storeDetails ? null : detailsOf(item);
  return [
    clean(item.notes),
    details?.reference ? `UPI ref ${details.reference}` : null,
    details?.upiId ? `UPI ID ${details.upiId}` : null,
    !storeTags && item.tags?.length ? `Tags: ${item.tags.join(', ')}` : null,
  ].filter((part): part is string => part != null);
}

export function buildImportPlan(
  items: readonly ReviewItem[],
  options: {
    fallbackCategoryId: string | null;
    paymentMethods?: readonly PaymentMethod[];
    /** Account nicknames by id, for labelling the other leg of a transfer. */
    accountNames?: ReadonlyMap<string, string>;
    /**
     * Whether a transfer can be written through migration 005, which also links
     * a row already on the other account.
     */
    linkAccounts?: boolean;
    /**
     * Without 005: whether both legs can still be written as a plain pair
     * (migration 003). Without either, a transfer to an account is balance only.
     */
    pairAccounts?: boolean;
    /** Migration 007 is in place: the reference, UPI ID and time go on the movement itself. */
    storeDetails?: boolean;
    /** Migration 006 is in place: tags are written as tags. */
    storeTags?: boolean;
  },
): ImportPlan {
  const operations: ImportOperation[] = [];
  const skipped: SkippedItem[] = [];
  const storeDetails = options.storeDetails === true;
  const storeTags = options.storeTags === true;
  for (const item of items) {
    if (!item.selected) continue;
    const details = storeDetails ? detailsOf(item) : null;
    const base = {
      itemId: item.id,
      bankAccountId: item.bankAccountId,
      amount: Math.round(item.amount * 100) / 100,
      date: item.transactionDate,
      description: item.description.trim(),
      ...(details ? { details } : {}),
    };
    const tags = storeTags && item.tags?.length ? { tags: [...item.tags] } : {};
    // A statement with a Notes column (Paytm) fills Notes with its note; a bank statement keeps its import marker.
    const ownNotes = item.notes !== undefined ? statementNotes(item, { storeDetails, storeTags }) : null;
    if (!(base.amount > 0) || base.amount > MAX_AMOUNT) {
      skipped.push({ itemId: item.id, reason: 'The amount is not valid' });
      continue;
    }
    if (!ISO_DATE.test(base.date)) {
      skipped.push({ itemId: item.id, reason: 'The date is not valid' });
      continue;
    }
    const problem = detailProblem(item);
    // A transfer with no other side still imports, as balance only. A row with no account does not.
    if (problem && problem !== 'transferTarget') {
      skipped.push({ itemId: item.id, reason: reviewProblemMessage(problem, item.transactionType).replace(/\.$/, '') });
      continue;
    }
    if (item.kind === 'expense') {
      if (item.transactionType !== 'debit') {
        skipped.push({ itemId: item.id, reason: 'Money in cannot be an expense' });
        continue;
      }
      const categoryId = item.categoryId ?? options.fallbackCategoryId;
      if (!categoryId) {
        skipped.push({ itemId: item.id, reason: 'Choose a category' });
        continue;
      }
      const merchant = clean(item.counterparty);
      const paymentMethodId = paymentMethodFor(item.channel, options.paymentMethods ?? []);
      const notes = ownNotes ? ownNotes.join('\n') || null : statementNote(item.reference);
      if (item.reimbursable) {
        operations.push({
          type: 'treatment',
          ...base,
          // The ledger row reads like any expense's: its payee, else its narration.
          description: merchant ?? base.description,
          direction: 'debit',
          request: {
            kind: 'expense',
            direction: 'debit',
            categoryId,
            merchant,
            expenseDescription: base.description,
            notes,
            paymentMethodId,
            reimbursablePerson: item.person.trim(),
            dueDate: item.dueDate,
            note: item.note,
          },
          ...tags,
        });
        continue;
      }
      operations.push({ type: 'expense', ...base, categoryId, merchant, paymentMethodId, notes, ...tags });
    } else if (item.kind === 'income') {
      if (item.transactionType !== 'credit') {
        skipped.push({ itemId: item.id, reason: 'Money out cannot be income' });
        continue;
      }
      // A rule-given source (Salary, Interest) wins; otherwise the payer named in the narration.
      const source = item.category?.trim() || item.counterparty?.trim() || null;
      // Income has no Notes: the statement's note follows the description.
      const description = ownNotes?.length ? [base.description, ...ownNotes].join(' · ') : base.description;
      operations.push({ type: 'income', ...base, description, source, ...tags });
    } else if (item.kind === 'transfer') {
      const target = item.transferTarget;
      const toAccount = target?.type === 'account' && target.accountId !== item.bankAccountId ? target.accountId : null;
      const here = options.accountNames?.get(item.bankAccountId);
      // The other account's leg reads from its own side: "Transfer from Salary".
      const counterpartDescription = here
        ? transferDescription({ note: null, isOutgoing: item.transactionType === 'credit', counterpartyLabel: here })
        : base.description;
      if (toAccount && options.linkAccounts === false && options.pairAccounts) {
        operations.push({ type: 'transfer', ...base, counterpartyAccountId: toAccount, direction: item.transactionType, counterpartDescription });
        continue;
      }
      if (target?.type === 'account' && toAccount && options.linkAccounts !== false) {
        const match = item.transferMatch;
        operations.push({
          type: 'treatment',
          ...base,
          direction: item.transactionType,
          request: {
            kind: 'transfer',
            direction: item.transactionType,
            transferTarget: target,
            matchEntryId: match && match !== 'new' ? match.entryId : null,
            counterpartDescription,
          },
          autoMatch: match == null,
        });
        continue;
      }
      const creditCardId = item.transactionType === 'debit' && target?.type === 'card' ? target.cardId : null;
      operations.push({ type: 'movement', ...base, direction: item.transactionType, ...(creditCardId ? { creditCardId } : {}) });
    } else if (item.kind === 'refund') {
      operations.push({ type: 'movement', ...base, direction: item.transactionType });
    } else if (item.kind === 'loan' && item.transactionType === 'debit') {
      operations.push({
        type: 'treatment',
        ...base,
        direction: 'debit',
        request: { kind: 'loan', direction: 'debit', person: item.person.trim(), dueDate: item.dueDate, note: item.note },
      });
    } else {
      // A repayment or a reimbursement: money in that pays back a claim.
      if (item.transactionType !== 'credit') {
        skipped.push({ itemId: item.id, reason: 'Money out cannot repay you' });
        continue;
      }
      const settles = item.settles;
      let resolved: ResolvedSettlement | null = null;
      let settlesItemId: string | null = null;
      if (settles?.type === 'claim') resolved = { receivableId: settles.receivableId };
      else if (settles?.type === 'expense') resolved = { expenseId: settles.expenseId, person: item.person.trim() };
      else if (settles?.type === 'pending') settlesItemId = settles.itemId;
      operations.push({
        type: 'treatment',
        ...base,
        direction: 'credit',
        request: { kind: item.kind, direction: 'credit', settles: resolved },
        settlesItemId,
      });
    }
  }
  return orderForPendingLinks(operations, skipped, items);
}

/**
 * A repayment of a row in the same import is written after that row, and only
 * if that row is itself being written as money lent or a purchase paid for
 * someone; otherwise it is skipped with the reason.
 */
function orderForPendingLinks(operations: ImportOperation[], skipped: SkippedItem[], items: readonly ReviewItem[]): ImportPlan {
  const planned = new Map(operations.map((op) => [op.itemId, op]));
  const kept: ImportOperation[] = [];
  const later: ImportOperation[] = [];
  for (const op of operations) {
    const target = op.type === 'treatment' ? op.settlesItemId : null;
    if (!target) {
      kept.push(op);
      continue;
    }
    const source = items.find((i) => i.id === target);
    if (!planned.has(target) || !source || !pendingKindOf(source)) {
      skipped.push({ itemId: op.itemId, reason: 'What it pays back is not being imported' });
      continue;
    }
    later.push(op);
  }
  return { operations: [...kept, ...later], skipped };
}

/**
 * The last guard before writing: checks the plan against a ledger read *now*.
 * Anything recorded since review started (another tab, a retried import) is
 * dropped. Rows the user deliberately imported despite a duplicate warning
 * are kept — that was their decision.
 */
export function withoutNewlyRecorded(
  plan: ImportPlan,
  items: readonly ReviewItem[],
  freshExisting: readonly ExistingMovement[],
): ImportPlan {
  const planned = new Set(plan.operations.map((op) => op.itemId));
  const candidates = items.filter((item) => planned.has(item.id));
  const checked = markDuplicates(candidates, freshExisting);
  const blocked = new Set(
    checked
      .filter((t) => t.duplicate?.type === 'existing' && isBlockingDuplicate(t.duplicate))
      .map((t) => t.id)
      .filter((id) => !items.find((item) => item.id === id)?.duplicateOverridden),
  );
  return {
    operations: plan.operations.filter((op) => !blocked.has(op.itemId)),
    skipped: [...plan.skipped, ...[...blocked].map((itemId) => ({ itemId, reason: 'Already recorded' }))],
  };
}

/** How many of each the plan writes, for the confirmation and the result screen. Each operation counts once. */
export type PlanCounts = {
  expenses: number;
  /** Expenses paid on someone else's behalf — not personal spending. */
  paidFor: number;
  income: number;
  /** Balance only: refunds, cash, card bills and transfers with no tracked other side. */
  movements: number;
  /** Transfers between two of your accounts. */
  transfers: number;
  /** Money lent. */
  lent: number;
  /** Loan repayments and reimbursements. */
  repaid: number;
};

export function countOperations(operations: readonly ImportOperation[]): PlanCounts {
  const counts: PlanCounts = { expenses: 0, paidFor: 0, income: 0, movements: 0, transfers: 0, lent: 0, repaid: 0 };
  for (const op of operations) {
    if (op.type === 'expense') counts.expenses += 1;
    else if (op.type === 'income') counts.income += 1;
    else if (op.type === 'movement') counts.movements += 1;
    else if (op.type === 'transfer' || op.request.kind === 'transfer') counts.transfers += 1;
    else if (op.request.kind === 'expense') counts.paidFor += 1;
    else if (op.direction === 'debit') counts.lent += 1;
    else counts.repaid += 1;
  }
  return counts;
}
