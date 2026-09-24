/**
 * `public.account_transactions` — the ledger, the single source of truth for
 * every bank movement. Port of `repositories/ledger_repository.dart`.
 *
 * Deleting a source expense/income is handled by `ON DELETE CASCADE`, so no
 * code here cleans up after one.
 */
import { uuidV4 } from '@/lib/id';
import { ledgerEntryFromRow, type LedgerEntry } from '@/domain/models';
import { transferDescription } from '@/domain/transfer';

import { capabilities } from './capabilities';
import { db, ensureOk, rowOf, rowsOf } from './db';

const TABLE = 'account_transactions';

/** The counterparty column is only requested once the probe confirmed it exists. */
const select = () =>
  'id, user_id, account_id, direction, amount, txn_date, description, category_id, expense_id, income_id, ' +
  `transfer_group_id, ${capabilities().transfers ? 'counterparty_account_id, ' : ''}created_at, categories(*)`;

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
  let query = db().from(TABLE).select(select()).eq('user_id', userId).eq('account_id', accountId);
  if (from) query = query.gte('txn_date', from);
  if (toExclusive) query = query.lt('txn_date', toExclusive);
  return rowsOf(await query.order('txn_date', { ascending: false }).limit(2000)).map(ledgerEntryFromRow);
}

async function net(userId: string, accountId: string, before: string | null): Promise<number> {
  let query = db().from(TABLE).select('direction, amount').eq('user_id', userId).eq('account_id', accountId);
  if (before) query = query.lt('txn_date', before);
  return rowsOf(await query).reduce((sum, row) => {
    const amount = Number(row.amount) || 0;
    return sum + (row.direction === 'credit' ? amount : -amount);
  }, 0);
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
}: {
  userId: string;
  accountId: string;
  direction: 'debit' | 'credit';
  amount: number;
  date: string;
  description: string | null;
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
      })
      .select(select())
      .single(),
  );
  return ledgerEntryFromRow(row);
}

export async function deleteEntry(userId: string, id: string): Promise<void> {
  ensureOk(await db().from(TABLE).delete().eq('id', id).eq('user_id', userId));
}

type DocumentSync = {
  userId: string;
  documentId: string;
  accountId: string | null;
  amount: number;
  date: string;
  description: string | null;
  categoryId?: string | null;
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

  if (!existing.length) {
    ensureOk(await db().from(TABLE).insert({ user_id: sync.userId, [kind]: sync.documentId, ...payload }));
  } else {
    ensureOk(await db().from(TABLE).update(payload).eq(kind, sync.documentId).eq('user_id', sync.userId));
  }
}

export const syncForExpense = (sync: DocumentSync) => syncDocument('expense_id', 'debit', sync);
export const syncForIncome = (sync: DocumentSync) => syncDocument('income_id', 'credit', sync);
