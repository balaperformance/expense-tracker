/**
 * Row types for the existing schema, and their defensive mappers.
 * Ports of `lib/models/*.dart` — field names, fallbacks and derived labels
 * match the Flutter app so both render the same data identically.
 */
import { FALLBACK_CATEGORY_COLOR } from '@/lib/color';
import { DEFAULT_CURRENCY } from '@/lib/format';
import { bool, nested, num, optStr, str, type Row } from '@/lib/row';

import { FALLBACK_CATEGORY_ICON } from './defaults';

export type ExpenseCategory = {
  id: string;
  userId: string;
  name: string;
  icon: string;
  color: string;
  isDefault: boolean;
  createdAt: string | null;
};

export type PaymentMethod = {
  id: string;
  userId: string;
  name: string;
  createdAt: string | null;
};

export type Expense = {
  id: string;
  userId: string;
  amount: number;
  expenseDate: string;
  categoryId: string | null;
  paymentMethodId: string | null;
  /** Null means Cash: no ledger movement, so cash can never move a bank balance. */
  bankAccountId: string | null;
  merchant: string | null;
  description: string | null;
  notes: string | null;
  createdAt: string | null;
  updatedAt: string | null;
  category: ExpenseCategory | null;
  paymentMethod: PaymentMethod | null;
};

export type Income = {
  id: string;
  userId: string;
  amount: number;
  incomeDate: string;
  source: string | null;
  description: string | null;
  /** Null means recorded as income but not credited to a tracked account. */
  bankAccountId: string | null;
  createdAt: string | null;
};

export type Budget = {
  id: string;
  userId: string;
  amount: number;
  /** Always the first day of the month. */
  month: string;
  /** Null is the overall budget for the month. */
  categoryId: string | null;
  createdAt: string | null;
  category: ExpenseCategory | null;
};

export type Profile = {
  id: string;
  fullName: string | null;
  currency: string;
};

export type BankAccount = {
  id: string;
  userId: string;
  bankName: string;
  nickname: string;
  last4: string | null;
  /** The only stored money figure; the live balance is always derived from the ledger. */
  openingBalance: number;
  isActive: boolean;
  createdAt: string | null;
};

export type BankAccountBalance = {
  account: BankAccount;
  totalCredits: number;
  totalDebits: number;
};

export type LedgerDirection = 'debit' | 'credit';

export type LedgerEntry = {
  id: string;
  userId: string;
  accountId: string;
  direction: LedgerDirection;
  /** Always positive; direction carries the sign. */
  amount: number;
  txnDate: string;
  description: string | null;
  categoryId: string | null;
  expenseId: string | null;
  incomeId: string | null;
  transferGroupId: string | null;
  counterpartyAccountId: string | null;
  createdAt: string | null;
  category: ExpenseCategory | null;
};

/** Shown wherever a real category would be. Intentionally not a database category. */
export const MONEY_TRANSFER_LABEL = 'Money Transfer';

// ---------------------------------------------------------------------------
// Mappers
// ---------------------------------------------------------------------------

const dateOnly = (value: string) => value.slice(0, 10);

export function categoryFromRow(row: Row): ExpenseCategory {
  return {
    id: str(row, 'id'),
    userId: str(row, 'user_id'),
    name: optStr(row, 'name') ?? 'Untitled',
    icon: optStr(row, 'icon') ?? FALLBACK_CATEGORY_ICON,
    color: optStr(row, 'color') ?? FALLBACK_CATEGORY_COLOR,
    isDefault: bool(row, 'is_default', false),
    createdAt: optStr(row, 'created_at'),
  };
}

export function paymentMethodFromRow(row: Row): PaymentMethod {
  return {
    id: str(row, 'id'),
    userId: str(row, 'user_id'),
    name: optStr(row, 'name') ?? 'Unknown',
    createdAt: optStr(row, 'created_at'),
  };
}

export function expenseFromRow(row: Row): Expense {
  const category = nested(row, 'categories');
  const method = nested(row, 'payment_methods');
  return {
    id: str(row, 'id'),
    userId: str(row, 'user_id'),
    amount: num(row, 'amount'),
    expenseDate: dateOnly(str(row, 'expense_date')),
    categoryId: optStr(row, 'category_id'),
    paymentMethodId: optStr(row, 'payment_method_id'),
    bankAccountId: optStr(row, 'bank_account_id'),
    merchant: optStr(row, 'merchant'),
    description: optStr(row, 'description'),
    notes: optStr(row, 'notes'),
    createdAt: optStr(row, 'created_at'),
    updatedAt: optStr(row, 'updated_at'),
    category: category ? categoryFromRow(category) : null,
    paymentMethod: method ? paymentMethodFromRow(method) : null,
  };
}

export function incomeFromRow(row: Row): Income {
  return {
    id: str(row, 'id'),
    userId: str(row, 'user_id'),
    amount: num(row, 'amount'),
    incomeDate: dateOnly(str(row, 'income_date')),
    source: optStr(row, 'source'),
    description: optStr(row, 'description'),
    bankAccountId: optStr(row, 'bank_account_id'),
    createdAt: optStr(row, 'created_at'),
  };
}

export function budgetFromRow(row: Row): Budget {
  const category = nested(row, 'categories');
  return {
    id: str(row, 'id'),
    userId: str(row, 'user_id'),
    amount: num(row, 'amount'),
    month: dateOnly(str(row, 'month')),
    categoryId: optStr(row, 'category_id'),
    createdAt: optStr(row, 'created_at'),
    category: category ? categoryFromRow(category) : null,
  };
}

export function profileFromRow(row: Row): Profile {
  return {
    id: str(row, 'id'),
    fullName: optStr(row, 'full_name'),
    currency: optStr(row, 'currency') ?? DEFAULT_CURRENCY,
  };
}

export function bankAccountFromRow(row: Row): BankAccount {
  return {
    id: str(row, 'id'),
    userId: str(row, 'user_id'),
    bankName: optStr(row, 'bank_name') ?? 'Bank',
    nickname: optStr(row, 'nickname') ?? 'Account',
    last4: optStr(row, 'last4'),
    openingBalance: num(row, 'opening_balance'),
    isActive: bool(row, 'is_active', true),
    createdAt: optStr(row, 'created_at'),
  };
}

export function ledgerEntryFromRow(row: Row): LedgerEntry {
  const category = nested(row, 'categories');
  return {
    id: str(row, 'id'),
    userId: str(row, 'user_id'),
    accountId: str(row, 'account_id'),
    direction: row.direction === 'credit' ? 'credit' : 'debit',
    amount: num(row, 'amount'),
    txnDate: dateOnly(str(row, 'txn_date')),
    description: optStr(row, 'description'),
    categoryId: optStr(row, 'category_id'),
    expenseId: optStr(row, 'expense_id'),
    incomeId: optStr(row, 'income_id'),
    transferGroupId: optStr(row, 'transfer_group_id'),
    counterpartyAccountId: optStr(row, 'counterparty_account_id'),
    createdAt: optStr(row, 'created_at'),
    category: category ? categoryFromRow(category) : null,
  };
}

// ---------------------------------------------------------------------------
// Derived labels
// ---------------------------------------------------------------------------

const clean = (value: string | null | undefined) => {
  const trimmed = value?.trim();
  return trimmed ? trimmed : null;
};

export const blankToNull = clean;

export function expenseCategoryName(expense: Expense): string {
  return expense.category?.name ?? 'Uncategorised';
}

/** Primary line in a row: merchant, else description, else category. */
export function expenseTitle(expense: Expense): string {
  return clean(expense.merchant) ?? clean(expense.description) ?? expenseCategoryName(expense);
}

export function incomeTitle(income: Income): string {
  return clean(income.source) ?? clean(income.description) ?? 'Income';
}

export function incomeSubtitle(income: Income): string | null {
  const description = clean(income.description);
  return description && description !== incomeTitle(income) ? description : null;
}

export function budgetLabel(budget: Budget): string {
  return budget.categoryId == null ? 'Overall budget' : (budget.category?.name ?? 'Category');
}

/** "HDFC •••• 4821" — what pickers and statement headers show. */
export function accountLabel(account: BankAccount): string {
  const digits = clean(account.last4);
  return digits ? `${account.nickname} •••• ${digits}` : account.nickname;
}

/** "HDFC Bank •••• 4821" — the account's bank line. */
export function accountBankLine(account: BankAccount): string {
  const digits = clean(account.last4);
  return digits ? `${account.bankName} •••• ${digits}` : account.bankName;
}

export function accountInitial(account: BankAccount): string {
  const name = account.bankName.trim();
  return name ? (name[0] ?? '?').toUpperCase() : '?';
}

export function currentBalance(balance: BankAccountBalance): number {
  return balance.account.openingBalance + balance.totalCredits - balance.totalDebits;
}

export function profileDisplayName(profile: Profile | null): string {
  return clean(profile?.fullName) ?? 'there';
}

export function profileInitial(profile: Profile | null): string {
  const name = clean(profile?.fullName);
  return name ? (name[0] ?? '?').toUpperCase() : '?';
}

export function isTransfer(entry: LedgerEntry): boolean {
  return entry.transferGroupId != null;
}

/** A movement produced by an expense or income row — edited there, not on the statement. */
export function isDocumentBacked(entry: LedgerEntry): boolean {
  return entry.expenseId != null || entry.incomeId != null;
}

export function signedAmount(entry: LedgerEntry): number {
  return entry.direction === 'debit' ? -entry.amount : entry.amount;
}

export function ledgerCategoryLabel(entry: LedgerEntry): string | null {
  return isTransfer(entry) ? MONEY_TRANSFER_LABEL : (entry.category?.name ?? null);
}

export function ledgerTitle(entry: LedgerEntry): string {
  const text = clean(entry.description);
  if (text) return text;
  if (isTransfer(entry)) return MONEY_TRANSFER_LABEL;
  if (entry.expenseId != null) return 'Expense';
  if (entry.incomeId != null) return 'Income';
  return entry.direction === 'credit' ? 'Deposit' : 'Withdrawal';
}
