/**
 * `public.credit_cards` and `public.credit_card_transactions` (migration 004).
 *
 * A card's outstanding is never read from a stored column: it is derived from
 * the opening outstanding and the card's movements, which live in three
 * tables — purchases in `expenses`, bill payments from an account in
 * `account_transactions`, everything else in `credit_card_transactions`.
 * [fetchCardEntries] reads all three and merges them; nothing is copied.
 */
import {
  entryFromCardTransaction,
  entryFromExpense,
  entryFromPayment,
  type CardEntry,
} from '@/domain/creditCards';
import {
  blankToNull,
  cardTransactionFromRow,
  creditCardFromRow,
  type CardNetwork,
  type CardTransactionKind,
  type CreditCard,
  type LedgerDirection,
} from '@/domain/models';

import { toAppError } from '@/lib/errors';

import { capabilities, resolveCapabilities } from './capabilities';
import { allRowsOf, db, ensureOk, nowIso, rowsOf } from './db';
import { fetchForCreditCard } from './expenses';
import { fetchCardPayments } from './ledger';

const CARDS = 'credit_cards';
const TRANSACTIONS = 'credit_card_transactions';
const CARD_SELECT =
  'id, user_id, card_name, issuer, network, last4, credit_limit, opening_outstanding, statement_day, payment_due_day, ' +
  'payment_account_id, is_active, notes, created_at';
const TRANSACTION_SELECT =
  'id, user_id, card_id, kind, direction, amount, txn_date, description, reference, original_expense_id, created_at';

export async function fetchCards(userId: string): Promise<CreditCard[]> {
  const result = await db().from(CARDS).select(CARD_SELECT).eq('user_id', userId).order('created_at', { ascending: true });
  return rowsOf(result).map(creditCardFromRow);
}

/**
 * Every movement on one card — or on all of the user's cards when [cardId] is
 * null — over the whole history, from the three tables at once.
 */
export async function fetchCardEntries(userId: string, cardId: string | null): Promise<CardEntry[]> {
  await resolveCapabilities();
  if (!capabilities().creditCards) return [];
  const [purchases, payments, transactions] = await Promise.all([
    fetchForCreditCard(userId, cardId),
    fetchCardPayments(userId, cardId),
    allRowsOf((from, to, withCount) => {
      const query = db()
        .from(TRANSACTIONS)
        .select(TRANSACTION_SELECT, withCount ? { count: 'exact' } : undefined)
        .eq('user_id', userId);
      return (cardId ? query.eq('card_id', cardId) : query).order('id').range(from, to);
    }),
  ]);
  return [
    ...purchases.map(entryFromExpense),
    ...payments.map(entryFromPayment),
    ...transactions.map((row) => entryFromCardTransaction(cardTransactionFromRow(row))),
  ].filter((entry): entry is CardEntry => entry != null);
}

export type CardDraft = {
  cardName: string;
  issuer: string;
  network: CardNetwork | null;
  last4: string | null;
  creditLimit: number;
  openingOutstanding: number;
  statementDay: number;
  paymentDueDay: number;
  paymentAccountId: string | null;
  notes: string | null;
  /** An inactive card keeps its history and can still be paid off; it is only hidden from new purchases. */
  isActive: boolean;
};

function writable(draft: CardDraft): Record<string, unknown> {
  const last4 = draft.last4?.replace(/\D/g, '') ?? '';
  return {
    card_name: draft.cardName.trim(),
    issuer: draft.issuer.trim(),
    network: draft.network,
    last4: last4.length === 4 ? last4 : null,
    credit_limit: draft.creditLimit,
    opening_outstanding: draft.openingOutstanding,
    statement_day: draft.statementDay,
    payment_due_day: draft.paymentDueDay,
    payment_account_id: draft.paymentAccountId,
    notes: blankToNull(draft.notes),
    is_active: draft.isActive,
  };
}

export async function createCard(userId: string, draft: CardDraft): Promise<void> {
  ensureOk(await db().from(CARDS).insert({ user_id: userId, ...writable(draft) }));
}

export async function updateCard(userId: string, id: string, draft: CardDraft): Promise<void> {
  ensureOk(
    await db()
      .from(CARDS)
      .update({ ...writable(draft), updated_at: nowIso() })
      .eq('id', id)
      .eq('user_id', userId),
  );
}

/**
 * The database removes the card's own transactions, reverts its purchases to
 * Cash expenses and keeps its bill payments as plain bank debits (the money
 * did leave those accounts).
 */
export async function deleteCard(userId: string, id: string): Promise<void> {
  ensureOk(await db().from(CARDS).delete().eq('id', id).eq('user_id', userId));
}

export async function recordCardTransaction({
  userId,
  cardId,
  kind,
  direction,
  amount,
  date,
  description,
  reference = null,
  originalExpenseId = null,
}: {
  userId: string;
  cardId: string;
  kind: CardTransactionKind;
  direction: LedgerDirection;
  amount: number;
  date: string;
  description: string | null;
  reference?: string | null;
  originalExpenseId?: string | null;
}): Promise<void> {
  ensureOk(
    await db()
      .from(TRANSACTIONS)
      .insert({
        user_id: userId,
        card_id: cardId,
        kind,
        direction,
        amount,
        txn_date: date,
        description: blankToNull(description),
        reference: blankToNull(reference),
        original_expense_id: kind === 'refund' ? originalExpenseId : null,
      }),
  );
}

export async function deleteCardTransaction(userId: string, id: string): Promise<void> {
  ensureOk(await db().from(TRANSACTIONS).delete().eq('id', id).eq('user_id', userId));
}

export type CardActivity = { purchases: number; payments: number; others: number };

/** A count, or an error — never a silent 0 that would make a delete warning lie. */
const countOf = async (request: PromiseLike<{ count: number | null; error: unknown }>) => {
  const { count, error } = await request;
  if (error) throw toAppError(error);
  return count ?? 0;
};

/** How much a card holds, so its delete confirmation can say what happens to each part. */
export async function cardActivity(userId: string, cardId: string): Promise<CardActivity> {
  const head = { count: 'exact', head: true } as const;
  const [purchases, payments, others] = await Promise.all([
    countOf(db().from('expenses').select('id', head).eq('user_id', userId).eq('credit_card_id', cardId)),
    countOf(db().from('account_transactions').select('id', head).eq('user_id', userId).eq('credit_card_id', cardId)),
    countOf(db().from(TRANSACTIONS).select('id', head).eq('user_id', userId).eq('card_id', cardId)),
  ]);
  return { purchases, payments, others };
}
