/**
 * The processing pipeline after extraction, as one pure function:
 * ExtractedDocument → choose parser → parse → normalise → (assign accounts) → classify.
 * Duplicate marking needs the ledger, so it runs afterwards over the whole
 * session (see duplicates.ts).
 */
import { accountLabel, type BankAccount, type CreditCard, type ExpenseCategory } from '../models';

import { matchPrintedAccount } from './accountMatch';
import { classifyTransaction, type ClassifyContext } from './classify';
import { fingerprintOf } from './duplicates';
import type { ExtractedDocument, NormalizedTransaction, StatementPeriod, StatementPeriodKind, StatementWarning } from './model';
import { normalizeStatement } from './normalize';
import { selectParser, type StatementParser } from './parser';
import { BANK_PARSERS, FALLBACK_PARSER } from './parsers';

export type ProcessedStatement = {
  id: string;
  fileName: string;
  parserId: string;
  parserLabel: string;
  bankName: string | null;
  accountLast4: string | null;
  period: StatementPeriod | null;
  periodKind: StatementPeriodKind;
  pageCount: number;
  openingBalance: number | null;
  closingBalance: number | null;
  /**
   * The statement covers several accounts (a Paytm UPI statement): each row
   * went to the account it names, not to the account chosen for the upload.
   */
  accountPerRow: boolean;
  transactions: NormalizedTransaction[];
  warnings: StatementWarning[];
};

/**
 * Rows of a statement that covers several accounts go to the account each one
 * names. A row whose account cannot be matched safely gets none ('') — never
 * the upload's account — until the user chooses one in review.
 */
function assignAccounts(transactions: readonly NormalizedTransaction[], accounts: readonly BankAccount[]): NormalizedTransaction[] {
  return transactions.map((t) => {
    const match = matchPrintedAccount(t.sourceAccount, accounts);
    const assigned: NormalizedTransaction = { ...t, bankAccountId: match?.id ?? '', accountStatus: match ? 'matched' : 'unmatched' };
    return { ...assigned, fingerprint: fingerprintOf(assigned) };
  });
}

/** Each row is classified from its own account's point of view: "your other accounts" are the rest. */
function classifyByAccount(
  transactions: readonly NormalizedTransaction[],
  { accounts, categories, cards }: { accounts: readonly BankAccount[]; categories: readonly ExpenseCategory[]; cards: readonly CreditCard[] },
): NormalizedTransaction[] {
  const contexts = new Map<string, ClassifyContext>();
  const contextFor = (accountId: string): ClassifyContext => {
    const known = contexts.get(accountId);
    if (known) return known;
    const ctx: ClassifyContext = {
      categories,
      otherAccountLast4: accounts
        .filter((a) => a.id !== accountId)
        .map((a) => (a.last4 ?? '').replace(/[^0-9]/g, ''))
        .filter((d) => d.length >= 4),
      otherAccounts: accounts.filter((a) => a.id !== accountId && a.isActive).map((a) => ({ id: a.id, last4: a.last4 })),
      cards: cards.filter((c) => c.isActive).map((c) => ({ id: c.id, last4: c.last4 })),
    };
    contexts.set(accountId, ctx);
    return ctx;
  };
  return transactions.map((t) => ({ ...t, ...classifyTransaction(t, contextFor(t.bankAccountId)) }));
}

/**
 * "Self transfer to HDFC Bank - 59": when the account a row names as the other
 * side is safely one of the user's own, it is a transfer to (or from) it —
 * never spending or income. Without such a match nothing is assumed.
 */
function withOwnAccountTransfers(transactions: readonly NormalizedTransaction[], accounts: readonly BankAccount[]): NormalizedTransaction[] {
  return transactions.map((t) => {
    if (!t.counterpartyAccount) return t;
    const other = matchPrintedAccount(t.counterpartyAccount, accounts, { exceptId: t.bankAccountId || undefined });
    if (!other) return t;
    return {
      ...t,
      kind: 'transfer',
      category: null,
      categorySource: 'none',
      categoryReason: `${t.transactionType === 'debit' ? 'to' : 'from'} your account ${accountLabel(other)}`,
      creditCardId: null,
      transferTarget: { type: 'account', accountId: other.id },
    };
  });
}

export function processStatement({
  doc,
  statementId,
  fileName,
  account,
  accounts,
  categories,
  cards = [],
  parsers = BANK_PARSERS,
}: {
  doc: ExtractedDocument;
  statementId: string;
  fileName: string;
  account: BankAccount;
  accounts: readonly BankAccount[];
  categories: readonly ExpenseCategory[];
  /** The user's credit cards; active ones let a card bill be recognised by its digits. */
  cards?: readonly CreditCard[];
  parsers?: readonly StatementParser[];
}): ProcessedStatement {
  const { parser } = selectParser(doc, parsers, FALLBACK_PARSER);
  const parsed = parser.parse(doc);
  const normalized = normalizeStatement(parsed, { bankAccountId: account.id, statementId });
  const accountPerRow = parsed.accountPerRow === true;
  const placed = accountPerRow ? assignAccounts(normalized.transactions, accounts) : normalized.transactions;
  const classified = classifyByAccount(placed, { accounts, categories, cards });
  return {
    id: statementId,
    fileName,
    parserId: parser.id,
    parserLabel: parser.label,
    bankName: parsed.bankName,
    accountLast4: parsed.accountLast4,
    period: normalized.period,
    periodKind: normalized.periodKind,
    pageCount: doc.pageCount,
    openingBalance: parsed.openingBalance,
    closingBalance: parsed.closingBalance,
    accountPerRow,
    transactions: accountPerRow ? withOwnAccountTransfers(classified, accounts) : classified,
    warnings: normalized.warnings,
  };
}

/** Last digits the statement prints that contradict the chosen account — worth a warning, not a block. */
export function accountMismatch(statement: ProcessedStatement, account: BankAccount): boolean {
  const mine = (account.last4 ?? '').replace(/[^0-9]/g, '');
  return statement.accountLast4 != null && mine.length >= 4 && !mine.endsWith(statement.accountLast4);
}
