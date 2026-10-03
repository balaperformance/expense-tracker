/**
 * `public.bank_accounts`. Port of `repositories/bank_account_repository.dart`.
 * Balances are never read from a stored column: they are always
 * `opening_balance + credits - debits` over the whole ledger.
 */
import { bankAccountFromRow, type BankAccount, type BankAccountBalance } from '@/domain/models';

import { allRowsOf, db, ensureOk, nowIso, rowsOf } from './db';

const TABLE = 'bank_accounts';
const SELECT = 'id, user_id, bank_name, nickname, last4, opening_balance, is_active, created_at';

export async function fetchAccounts(userId: string): Promise<BankAccount[]> {
  const result = await db().from(TABLE).select(SELECT).eq('user_id', userId).order('created_at', { ascending: true });
  return rowsOf(result).map(bankAccountFromRow);
}

/**
 * Every account balance, derived from the whole ledger. The ledger is read
 * page by page — one response is capped at the project's max-rows, and a
 * balance summed over a truncated list would be silently wrong. Sums are
 * kept in whole cents.
 */
export async function fetchAccountBalances(userId: string): Promise<BankAccountBalance[]> {
  const [accounts, movements] = await Promise.all([
    fetchAccounts(userId),
    allRowsOf((from, to, withCount) =>
      db()
        .from('account_transactions')
        .select('id, account_id, direction, amount', withCount ? { count: 'exact' } : undefined)
        .eq('user_id', userId)
        .order('id')
        .range(from, to),
    ),
  ]);
  const credits = new Map<string, number>();
  const debits = new Map<string, number>();
  for (const row of movements) {
    const accountId = String(row.account_id);
    const cents = Math.round((Number(row.amount) || 0) * 100);
    const bucket = row.direction === 'credit' ? credits : debits;
    bucket.set(accountId, (bucket.get(accountId) ?? 0) + cents);
  }
  return accounts.map((account) => ({
    account,
    totalCredits: (credits.get(account.id) ?? 0) / 100,
    totalDebits: (debits.get(account.id) ?? 0) / 100,
  }));
}

export type AccountDraft = { bankName: string; nickname: string; last4: string | null; openingBalance: number };

const blank = (value: string | null) => (value?.trim() ? value.trim() : null);

export async function createAccount(userId: string, draft: AccountDraft): Promise<void> {
  ensureOk(
    await db().from(TABLE).insert({
      user_id: userId,
      bank_name: draft.bankName.trim(),
      nickname: draft.nickname.trim(),
      last4: blank(draft.last4),
      opening_balance: draft.openingBalance,
      is_active: true,
    }),
  );
}

export async function updateAccount(userId: string, id: string, draft: AccountDraft): Promise<void> {
  ensureOk(
    await db()
      .from(TABLE)
      .update({
        bank_name: draft.bankName.trim(),
        nickname: draft.nickname.trim(),
        last4: blank(draft.last4),
        opening_balance: draft.openingBalance,
        updated_at: nowIso(),
      })
      .eq('id', id)
      .eq('user_id', userId),
  );
}

/**
 * The database cascades the account's ledger rows away and nulls
 * `bank_account_id` on linked expenses/income, which revert to Cash.
 */
export async function deleteAccount(userId: string, id: string): Promise<void> {
  ensureOk(await db().from(TABLE).delete().eq('id', id).eq('user_id', userId));
}

/** How many movements an account holds, so the delete confirmation can say so. */
export async function accountMovementCount(userId: string, accountId: string): Promise<number> {
  const { count, error } = await db()
    .from('account_transactions')
    .select('id', { count: 'exact', head: true })
    .eq('user_id', userId)
    .eq('account_id', accountId);
  return error ? 0 : (count ?? 0);
}
