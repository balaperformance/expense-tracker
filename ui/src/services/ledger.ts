/**
 * `public.account_transactions` — the ledger, the single source of truth for
 * every bank movement. Port of `repositories/ledger_repository.dart`.
 *
 * Deleting a source expense/income is handled by `ON DELETE CASCADE`, so no
 * code here cleans up after one.
 */
import { AppError } from '@/lib/errors';
import { uuidV4 } from '@/lib/id';
import { ledgerEntryFromRow, type LedgerEntry } from '@/domain/models';
import type { MovementDetails } from '@/domain/statementImport/model';
import { transferDescription } from '@/domain/transfer';

import { capabilities } from './capabilities';
import { allRowsOf, db, ensureOk, rowOf, rowsOf } from './db';
import { fetchClaimLinks } from './receivables';

const TABLE = 'account_transactions';

/** Optional columns are only requested once the probe confirmed they exist. */
const select = () =>
  'id, user_id, account_id, direction, amount, txn_date, description, category_id, expense_id, income_id, ' +
  `transfer_group_id, ${capabilities().transfers ? 'counterparty_account_id, ' : ''}` +
  `${capabilities().creditCards ? 'credit_card_id, ' : ''}${capabilities().treatments ? 'receivable_id, ' : ''}` +
  `${capabilities().statementDetails ? 'reference, upi_id, txn_time, ' : ''}created_at, categories(*)`;

/**
 * The ledger columns for what an imported statement printed about a movement
 * (migration 007) — nothing before that migration, or when there is nothing to keep.
 */
function detailsColumns(details: MovementDetails | null | undefined): Record<string, unknown> {
  if (!details || !capabilities().statementDetails) return {};
  const reference = details.reference?.trim() ? details.reference.trim().slice(0, 64) : null;
  const upiId = details.upiId?.trim() && details.upiId.trim().length >= 3 ? details.upiId.trim().slice(0, 255) : null;
  return { reference, upi_id: upiId, txn_time: details.time };
}

/** Records what the statement printed on a movement saved by a database function (which knows nothing of it). */
export async function setMovementDetails(userId: string, entryId: string, details: MovementDetails): Promise<void> {
  const columns = detailsColumns(details);
  if (!Object.keys(columns).length) return;
  ensureOk(await db().from(TABLE).update(columns).eq('id', entryId).eq('user_id', userId));
}

/**
 * Fills in each movement's claim — money lent, a purchase paid for someone,
 * or a repayment — from the user's claims (migration 005). One small read
 * covers any number of movements.
 */
async function withClaims(userId: string, entries: LedgerEntry[]): Promise<LedgerEntry[]> {
  if (!capabilities().treatments || !entries.length) return entries;
  const claims = await fetchClaimLinks(userId);
  if (!claims.length) return entries;
  const byEntry = new Map(claims.filter((c) => c.ledgerEntryId).map((c) => [c.ledgerEntryId, c]));
  const byExpense = new Map(claims.filter((c) => c.expenseId).map((c) => [c.expenseId, c]));
  const byId = new Map(claims.map((c) => [c.id, c]));
  return entries.map((entry): LedgerEntry => {
    const settled = entry.receivableId ? byId.get(entry.receivableId) : undefined;
    if (settled) return { ...entry, claim: { receivableId: settled.id, kind: settled.kind, person: settled.person, role: 'settles' } };
    const source = byEntry.get(entry.id) ?? (entry.expenseId ? byExpense.get(entry.expenseId) : undefined);
    return source ? { ...entry, claim: { receivableId: source.id, kind: source.kind, person: source.person, role: 'source' } } : entry;
  });
}

export async function fetchForAccount({
  userId,
  accountId,
  from,
  toExclusive,
}: {
  userId: string;
  accountId: string;
  from?: string | null;
  toExclusive?: string | null;
}): Promise<LedgerEntry[]> {
  // Every row, page by page: a running balance built from a truncated list would be wrong.
  const rows = await allRowsOf((first, last, withCount) => {
    let query = db()
      .from(TABLE)
      .select(select(), withCount ? { count: 'exact' } : undefined)
      .eq('user_id', userId)
      .eq('account_id', accountId);
    if (from) query = query.gte('txn_date', from);
    if (toExclusive) query = query.lt('txn_date', toExclusive);
    return query.order('txn_date', { ascending: false }).order('id').range(first, last);
  });
  return withClaims(userId, rows.map(ledgerEntryFromRow));
}

/** Signed sum in whole cents, so thousands of rows cannot drift by a paisa. */
export function netOfRows(rows: readonly { direction?: unknown; amount?: unknown }[]): number {
  const cents = rows.reduce<number>((sum, row) => {
    const amount = Math.round((Number(row.amount) || 0) * 100);
    return sum + (row.direction === 'credit' ? amount : -amount);
  }, 0);
  return cents / 100;
}

async function net(userId: string, accountId: string, before: string | null): Promise<number> {
  const rows = await allRowsOf((first, last, withCount) => {
    let query = db()
      .from(TABLE)
      .select('id, direction, amount', withCount ? { count: 'exact' } : undefined)
      .eq('user_id', userId)
      .eq('account_id', accountId);
    if (before) query = query.lt('txn_date', before);
    return query.order('id').range(first, last);
  });
  return netOfRows(rows);
}

/** Net movement strictly before [before]: the brought-forward figure for a period. */
export const netBefore = (userId: string, accountId: string, before: string) => net(userId, accountId, before);

/** Net movement over the whole history — re-derived right before a transfer. */
export const netFor = (userId: string, accountId: string) => net(userId, accountId, null);

/**
 * Moves money between two of the user's accounts as ONE multi-row insert:
 * PostgREST runs it as a single statement, so both legs commit or neither
 * does — money can never vanish from one balance without arriving in the other.
 */
export async function transfer({
  userId,
  fromAccountId,
  toAccountId,
  fromLabel,
  toLabel,
  amount,
  date,
  note,
}: {
  userId: string;
  fromAccountId: string;
  toAccountId: string;
  fromLabel: string;
  toLabel: string;
  amount: number;
  date: string;
  note: string | null;
}): Promise<string> {
  const groupId = uuidV4();
  const legs = [
    {
      user_id: userId,
      account_id: fromAccountId,
      direction: 'debit',
      amount,
      txn_date: date,
      description: transferDescription({ note, isOutgoing: true, counterpartyLabel: toLabel }),
      transfer_group_id: groupId,
      counterparty_account_id: toAccountId,
    },
    {
      user_id: userId,
      account_id: toAccountId,
      direction: 'credit',
      amount,
      txn_date: date,
      description: transferDescription({ note, isOutgoing: false, counterpartyLabel: fromLabel }),
      transfer_group_id: groupId,
      counterparty_account_id: fromAccountId,
    },
  ];
  ensureOk(await db().from(TABLE).insert(legs));
  return groupId;
}

/**
 * An imported movement that was a transfer to or from another of the user's
 * accounts: this account's row plus the other account's opposite leg, as ONE
 * multi-row insert, so both commit or neither does. [description] is this
 * account's text (the statement narration); the other leg gets [counterpartDescription].
 */
export async function recordTransferPair({
  userId,
  accountId,
  counterpartyAccountId,
  direction,
  amount,
  date,
  description,
  counterpartDescription,
  details,
}: {
  userId: string;
  accountId: string;
  counterpartyAccountId: string;
  direction: 'debit' | 'credit';
  amount: number;
  date: string;
  description: string;
  counterpartDescription: string;
  /** What this account's statement printed about its own leg. */
  details?: MovementDetails | null;
}): Promise<void> {
  const groupId = uuidV4();
  const leg = (account: string, other: string, legDirection: 'debit' | 'credit', text: string) => ({
    user_id: userId,
    account_id: account,
    direction: legDirection,
    amount,
    txn_date: date,
    description: text.trim() ? text.trim() : null,
    transfer_group_id: groupId,
    counterparty_account_id: other,
  });
  // Both rows of one insert must carry the same columns: the other leg's details are left empty.
  const blank = Object.fromEntries(Object.keys(detailsColumns(details)).map((key) => [key, null]));
  ensureOk(
    await db()
      .from(TABLE)
      .insert([
        { ...leg(accountId, counterpartyAccountId, direction, description), ...detailsColumns(details) },
        { ...leg(counterpartyAccountId, accountId, direction === 'debit' ? 'credit' : 'debit', counterpartDescription), ...blank },
      ]),
  );
}

/** Both legs, in one statement — one side alone would create or destroy money. */
export async function deleteTransfer(userId: string, transferGroupId: string): Promise<void> {
  ensureOk(await db().from(TABLE).delete().eq('user_id', userId).eq('transfer_group_id', transferGroupId));
}

/** A standalone credit (deposit, refund) or debit (bank charge, ATM) not tied to a document. */
export async function recordMovement({
  userId,
  accountId,
  direction,
  amount,
  date,
  description,
  details,
}: {
  userId: string;
  accountId: string;
  direction: 'debit' | 'credit';
  amount: number;
  date: string;
  description: string | null;
  /** What an imported statement printed about it. */
  details?: MovementDetails | null;
}): Promise<LedgerEntry> {
  const row = rowOf(
    await db()
      .from(TABLE)
      .insert({
        user_id: userId,
        account_id: accountId,
        direction,
        amount,
        txn_date: date,
        description: description?.trim() ? description.trim() : null,
        category_id: null,
        expense_id: null,
        income_id: null,
        transfer_group_id: null,
        ...detailsColumns(details),
      })
      .select(select())
      .single(),
  );
  return ledgerEntryFromRow(row);
}

export async function deleteEntry(userId: string, id: string): Promise<void> {
  ensureOk(await db().from(TABLE).delete().eq('id', id).eq('user_id', userId));
}

// ---- Credit-card bill payments ----------------------------------------------
//
// A bill paid from an account is ONE debit on that account carrying the card's
// id: the same row lowers the bank balance and the card's outstanding, so the
// two sides can never disagree, and it is not an expense.

/** Pays a card bill from a bank account. */
export async function recordCardPayment({
  userId,
  accountId,
  cardId,
  amount,
  date,
  description,
  details,
}: {
  userId: string;
  accountId: string;
  cardId: string;
  amount: number;
  date: string;
  description: string;
  /** What an imported statement printed about it. */
  details?: MovementDetails | null;
}): Promise<void> {
  ensureOk(
    await db()
      .from(TABLE)
      .insert({
        user_id: userId,
        account_id: accountId,
        direction: 'debit',
        amount,
        txn_date: date,
        description,
        category_id: null,
        expense_id: null,
        income_id: null,
        transfer_group_id: null,
        credit_card_id: cardId,
        ...detailsColumns(details),
      }),
  );
}

/**
 * Marks an existing debit — typed in or imported from a bank statement — as the
 * payment of [cardId] (or clears that with null). No row is added, so the
 * account is never debited twice. Only a plain debit qualifies; the filters
 * make anything else a no-op, which is reported as an error.
 */
export async function linkToCard(userId: string, entryId: string, cardId: string | null): Promise<void> {
  const query = db()
    .from(TABLE)
    .update({ credit_card_id: cardId })
    .eq('id', entryId)
    .eq('user_id', userId)
    .eq('direction', 'debit')
    .is('expense_id', null)
    .is('income_id', null)
    .is('transfer_group_id', null);
  // Linking only claims an unlinked debit — it never moves another card's
  // payment, even from a screen that went stale. Unlinking only touches a
  // linked one.
  const guarded = cardId ? query.is('credit_card_id', null) : query.not('credit_card_id', 'is', null);
  const rows = rowsOf(await guarded.select('id'));
  if (!rows.length) {
    throw new AppError(
      cardId
        ? 'That debit is no longer available to link — it may already be linked to a card, or changed. Refresh and try again.'
        : 'That payment is no longer linked to a card. Refresh and try again.',
    );
  }
}

/** Every bill payment drawn from an account — for one card, or for all cards when [cardId] is null. */
export async function fetchCardPayments(userId: string, cardId: string | null): Promise<LedgerEntry[]> {
  if (!capabilities().creditCards) return [];
  const rows = await allRowsOf((from, to, withCount) => {
    const query = db()
      .from(TABLE)
      .select(select(), withCount ? { count: 'exact' } : undefined)
      .eq('user_id', userId);
    return (cardId ? query.eq('credit_card_id', cardId) : query.not('credit_card_id', 'is', null)).order('id').range(from, to);
  });
  return rows.map(ledgerEntryFromRow);
}

/** How many bill payments an account holds, so its delete confirmation can say so. */
export async function cardPaymentCountForAccount(userId: string, accountId: string): Promise<number> {
  if (!capabilities().creditCards) return 0;
  const { count, error } = await db()
    .from(TABLE)
    .select('id', { count: 'exact', head: true })
    .eq('user_id', userId)
    .eq('account_id', accountId)
    .not('credit_card_id', 'is', null);
  return error ? 0 : (count ?? 0);
}

type DocumentSync = {
  userId: string;
  documentId: string;
  accountId: string | null;
  amount: number;
  date: string;
  description: string | null;
  categoryId?: string | null;
  /**
   * What an imported statement printed about the movement. Written when given;
   * left as it is when not — so editing the expense later never clears it.
   */
  details?: MovementDetails | null;
};

/**
 * Makes the ledger agree with an expense (debit) or income (credit) row.
 * No account means no movement at all, so a switch to Cash removes the row
 * an earlier edit created. A unique index guarantees at most one row per
 * document, so a retried insert cannot double-count.
 */
async function syncDocument(kind: 'expense_id' | 'income_id', direction: 'debit' | 'credit', sync: DocumentSync) {
  const existing = rowsOf(
    await db().from(TABLE).select('id').eq('user_id', sync.userId).eq(kind, sync.documentId),
  );

  if (sync.accountId == null) {
    if (existing.length) {
      ensureOk(await db().from(TABLE).delete().eq(kind, sync.documentId).eq('user_id', sync.userId));
    }
    return;
  }

  const payload: Record<string, unknown> = {
    account_id: sync.accountId,
    direction,
    amount: sync.amount,
    txn_date: sync.date,
    description: sync.description,
  };
  if (kind === 'expense_id') payload.category_id = sync.categoryId ?? null;
  if (sync.details) Object.assign(payload, detailsColumns(sync.details));

  if (!existing.length) {
    ensureOk(await db().from(TABLE).insert({ user_id: sync.userId, [kind]: sync.documentId, ...payload }));
  } else {
    ensureOk(await db().from(TABLE).update(payload).eq(kind, sync.documentId).eq('user_id', sync.userId));
  }
}

export const syncForExpense = (sync: DocumentSync) => syncDocument('expense_id', 'debit', sync);
export const syncForIncome = (sync: DocumentSync) => syncDocument('income_id', 'credit', sync);
