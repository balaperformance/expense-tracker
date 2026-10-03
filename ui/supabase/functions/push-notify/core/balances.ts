/**
 * A bank account's balance — src/services/accounts.ts `fetchAccountBalances`
 * with src/domain/models.ts `currentBalance`: the opening balance plus every
 * ledger credit minus every ledger debit, summed in whole cents. Credit cards
 * are not bank accounts and never enter here.
 */
import { toCents } from './money.ts';

export type AccountRow = { id: string; name: string; openingBalance: number; isActive: boolean };
export type LedgerRow = { accountId: string; direction: 'debit' | 'credit'; amount: number };
export type AccountBalance = { id: string; name: string; isActive: boolean; balanceCents: number };

export function accountBalances(accounts: readonly AccountRow[], ledger: readonly LedgerRow[]): AccountBalance[] {
  const net = new Map<string, number>();
  for (const row of ledger) {
    const cents = toCents(row.amount);
    net.set(row.accountId, (net.get(row.accountId) ?? 0) + (row.direction === 'credit' ? cents : -cents));
  }
  return accounts.map((account) => ({
    id: account.id,
    name: account.name,
    isActive: account.isActive,
    balanceCents: toCents(account.openingBalance) + (net.get(account.id) ?? 0),
  }));
}
