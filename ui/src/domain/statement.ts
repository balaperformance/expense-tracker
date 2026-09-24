/**
 * Account statements with running balances. Port of `buildStatement` in
 * `models/ledger_entry.dart` — pure, so the arithmetic is unit-tested.
 */
import { signedAmount, type LedgerEntry } from './models';

export type StatementTypeFilter = 'all' | 'debits' | 'credits';

export const STATEMENT_FILTERS: ReadonlyArray<{ value: StatementTypeFilter; label: string }> = [
  { value: 'all', label: 'All' },
  { value: 'debits', label: 'Debits' },
  { value: 'credits', label: 'Credits' },
];

function matches(filter: StatementTypeFilter, entry: LedgerEntry): boolean {
  if (filter === 'all') return true;
  return filter === 'debits' ? entry.direction === 'debit' : entry.direction === 'credit';
}

export type StatementRow = {
  entry: LedgerEntry;
  /** Running balance immediately after [entry] was applied. */
  balanceAfter: number;
};

export type AccountStatement = {
  /** Balance carried into the period. */
  openingBalance: number;
  /** Newest first, the way a bank app lists them. */
  rows: StatementRow[];
  totalCredits: number;
  totalDebits: number;
};

export function closingBalance(statement: AccountStatement): number {
  return statement.openingBalance + statement.totalCredits - statement.totalDebits;
}

/**
 * Walks the entries oldest-first to accumulate the balance, then reverses.
 * The type filter is applied after the walk, so hiding credits does not
 * corrupt the balances shown against the remaining debits; the totals
 * describe the rows actually shown so the summary reconciles with the list.
 */
export function buildStatement({
  openingBalance,
  entries,
  typeFilter = 'all',
}: {
  openingBalance: number;
  entries: readonly LedgerEntry[];
  typeFilter?: StatementTypeFilter;
}): AccountStatement {
  const ordered = [...entries].sort((a, b) => {
    if (a.txnDate !== b.txnDate) return a.txnDate < b.txnDate ? -1 : 1;
    // Same-day movements fall back to insertion order so the running
    // balance is stable across reloads.
    const aCreated = a.createdAt ?? '1970-01-01T00:00:00Z';
    const bCreated = b.createdAt ?? '1970-01-01T00:00:00Z';
    const byCreated = Date.parse(aCreated) - Date.parse(bCreated);
    if (byCreated !== 0 && Number.isFinite(byCreated)) return byCreated;
    return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
  });

  let running = openingBalance;
  const rows: StatementRow[] = [];
  for (const entry of ordered) {
    running += signedAmount(entry);
    if (matches(typeFilter, entry)) rows.push({ entry, balanceAfter: running });
  }

  let credits = 0;
  let debits = 0;
  for (const row of rows) {
    if (row.entry.direction === 'credit') credits += row.entry.amount;
    else debits += row.entry.amount;
  }

  return { openingBalance, rows: rows.reverse(), totalCredits: credits, totalDebits: debits };
}
