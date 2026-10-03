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
  /** Set for a credit-card purchase: it raises that card's outstanding and never touches a bank balance. */
  creditCardId: string | null;
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
  /** Set when this debit paid a credit-card bill: the same row lowers the card's outstanding. */
  creditCardId: string | null;
  /** Set when this credit repays a loan or reimburses a purchase (migration 005). */
  receivableId: string | null;
  /** The claim this movement belongs to, filled in from `receivables` when the statement is read. */
  claim: LedgerClaim | null;
  createdAt: string | null;
  category: ExpenseCategory | null;
  /** What an imported statement printed about it (migration 007): its reference, the UPI ID, the time. */
  reference?: string | null;
  upiId?: string | null;
  txnTime?: string | null;
};

/** Money someone owes the user: money lent, or a purchase paid on their behalf. */
export type ReceivableKind = 'loan' | 'reimbursable';

/**
 * How a ledger row relates to a claim: it is the money that went out ('source':
 * the lent debit, or the debit of a reimbursable bank expense), or money that
 * came back against it ('settles').
 */
export type LedgerClaim = { receivableId: string; kind: ReceivableKind; person: string; role: 'source' | 'settles' };

/** Shown wherever a real category would be. Intentionally not a database category. */
export const MONEY_TRANSFER_LABEL = 'Money Transfer';

/** The label of a bank debit that paid a card bill — like a transfer, it is not spending. */
export const CARD_PAYMENT_LABEL = 'Card bill payment';

/** Labels for the receivable treatments — none of them is income or spending. */
export const MONEY_LENT_LABEL = 'Money lent';
export const LOAN_REPAYMENT_LABEL = 'Loan repayment';
export const REIMBURSEMENT_LABEL = 'Reimbursement';

export type CardNetwork = 'visa' | 'mastercard' | 'rupay' | 'amex' | 'diners' | 'discover' | 'jcb' | 'other';

export const CARD_NETWORKS: ReadonlyArray<{ value: CardNetwork; label: string }> = [
  { value: 'visa', label: 'Visa' },
  { value: 'mastercard', label: 'Mastercard' },
  { value: 'rupay', label: 'RuPay' },
  { value: 'amex', label: 'American Express' },
  { value: 'diners', label: 'Diners Club' },
  { value: 'discover', label: 'Discover' },
  { value: 'jcb', label: 'JCB' },
  { value: 'other', label: 'Other' },
];

export type CreditCard = {
  id: string;
  userId: string;
  cardName: string;
  issuer: string;
  network: CardNetwork | null;
  last4: string | null;
  creditLimit: number;
  /** What was owed when tracking began; the live outstanding is always derived. */
  openingOutstanding: number;
  /** Day of the month the billing cycle closes (29–31 clamp to the month's last day). */
  statementDay: number;
  /** Day of the month the bill is due: the first such day after the statement date. */
  paymentDueDay: number;
  /** The account the bill is usually paid from. A purchase never debits it. */
  paymentAccountId: string | null;
  isActive: boolean;
  notes: string | null;
  createdAt: string | null;
};

/** Card movements that are neither a purchase (an expense) nor a payment from a tracked account. */
export type CardTransactionKind = 'refund' | 'cashback' | 'payment' | 'fee' | 'interest' | 'adjustment';

export type CardTransaction = {
  id: string;
  userId: string;
  cardId: string;
  kind: CardTransactionKind;
  /** 'debit' raises the outstanding, 'credit' lowers it. */
  direction: LedgerDirection;
  amount: number;
  txnDate: string;
  description: string | null;
  reference: string | null;
  /** The purchase a refund reverses, when known. */
  originalExpenseId: string | null;
  createdAt: string | null;
};

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
    creditCardId: optStr(row, 'credit_card_id'),
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
    creditCardId: optStr(row, 'credit_card_id'),
    receivableId: optStr(row, 'receivable_id'),
    claim: null,
    createdAt: optStr(row, 'created_at'),
    category: category ? categoryFromRow(category) : null,
    reference: optStr(row, 'reference'),
    upiId: optStr(row, 'upi_id'),
    txnTime: optStr(row, 'txn_time'),
  };
}

const NETWORK_VALUES = new Set<string>(CARD_NETWORKS.map((n) => n.value));
const CARD_KINDS = new Set<string>(['refund', 'cashback', 'payment', 'fee', 'interest', 'adjustment']);

/** A day of the month, or [fallback] when the stored value is out of range. */
function dayOfMonth(row: Row, key: string, fallback: number): number {
  const value = Math.trunc(num(row, key));
  return value >= 1 && value <= 31 ? value : fallback;
}

export function creditCardFromRow(row: Row): CreditCard {
  const network = optStr(row, 'network');
  return {
    id: str(row, 'id'),
    userId: str(row, 'user_id'),
    cardName: optStr(row, 'card_name') ?? 'Card',
    issuer: optStr(row, 'issuer') ?? 'Card issuer',
    network: network && NETWORK_VALUES.has(network) ? (network as CardNetwork) : null,
    last4: optStr(row, 'last4'),
    creditLimit: num(row, 'credit_limit'),
    openingOutstanding: num(row, 'opening_outstanding'),
    statementDay: dayOfMonth(row, 'statement_day', 1),
    paymentDueDay: dayOfMonth(row, 'payment_due_day', 1),
    paymentAccountId: optStr(row, 'payment_account_id'),
    isActive: bool(row, 'is_active', true),
    notes: optStr(row, 'notes'),
    createdAt: optStr(row, 'created_at'),
  };
}

export function cardTransactionFromRow(row: Row): CardTransaction {
  const kind = optStr(row, 'kind');
  return {
    id: str(row, 'id'),
    userId: str(row, 'user_id'),
    cardId: str(row, 'card_id'),
    kind: kind && CARD_KINDS.has(kind) ? (kind as CardTransactionKind) : 'adjustment',
    direction: row.direction === 'debit' ? 'debit' : 'credit',
    amount: num(row, 'amount'),
    txnDate: dateOnly(str(row, 'txn_date')),
    description: optStr(row, 'description'),
    reference: optStr(row, 'reference'),
    originalExpenseId: optStr(row, 'original_expense_id'),
    createdAt: optStr(row, 'created_at'),
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

/** "Regalia •••• 4821" — what pickers and statement headers show. */
export function cardLabel(card: CreditCard): string {
  const digits = clean(card.last4);
  return digits ? `${card.cardName} •••• ${digits}` : card.cardName;
}

export function cardNetworkLabel(network: CardNetwork | null): string | null {
  return network ? (CARD_NETWORKS.find((n) => n.value === network)?.label ?? null) : null;
}

/** "HDFC Bank · Visa •••• 4821" — the card's issuer line. */
export function cardIssuerLine(card: CreditCard): string {
  const digits = clean(card.last4);
  const tail = [cardNetworkLabel(card.network), digits ? `•••• ${digits}` : null].filter(Boolean).join(' ');
  return tail ? `${card.issuer} · ${tail}` : card.issuer;
}

export function accountInitial(account: BankAccount): string {
  const name = account.bankName.trim();
  return name ? (name[0] ?? '?').toUpperCase() : '?';
}

export function currentBalance(balance: BankAccountBalance): number {
  return balance.account.openingBalance + balance.totalCredits - balance.totalDebits;
}

/**
 * What is available across every bank and cash account — the total the
 * Accounts screen shows. Credit cards are not accounts, so their outstanding
 * is never counted as money available.
 */
export function totalBalance(balances: readonly BankAccountBalance[]): number {
  return balances.reduce((sum, b) => sum + currentBalance(b), 0);
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

export function isCardPayment(entry: LedgerEntry): boolean {
  return entry.creditCardId != null;
}

/** A debit recorded as money lent: the balance went down, but it is owed back — not spending. */
export function isMoneyLent(entry: LedgerEntry): boolean {
  return entry.claim?.role === 'source' && entry.claim.kind === 'loan';
}

/** A credit that repays a loan or reimburses a purchase — not income. */
export function isSettlement(entry: LedgerEntry): boolean {
  return entry.receivableId != null || entry.claim?.role === 'settles';
}

/** "Money lent", "Loan repayment" or "Reimbursement"; null for anything else. */
export function claimLabel(entry: LedgerEntry): string | null {
  const claim = entry.claim;
  if (!claim) return entry.receivableId != null ? REIMBURSEMENT_LABEL : null;
  if (claim.role === 'source') return claim.kind === 'loan' ? MONEY_LENT_LABEL : null;
  return claim.kind === 'loan' ? LOAN_REPAYMENT_LABEL : REIMBURSEMENT_LABEL;
}

/** "to Arun", "from Arun", "for Arun" — who the claim is with. */
export function claimPersonText(entry: LedgerEntry): string | null {
  const claim = entry.claim;
  if (!claim) return null;
  if (claim.role === 'settles') return `from ${claim.person}`;
  return claim.kind === 'loan' ? `to ${claim.person}` : `paid for ${claim.person}`;
}

/** A movement produced by an expense or income row — edited there, not on the statement. */
export function isDocumentBacked(entry: LedgerEntry): boolean {
  return entry.expenseId != null || entry.incomeId != null;
}

export function signedAmount(entry: LedgerEntry): number {
  return entry.direction === 'debit' ? -entry.amount : entry.amount;
}

export function ledgerCategoryLabel(entry: LedgerEntry): string | null {
  if (isTransfer(entry)) return MONEY_TRANSFER_LABEL;
  if (isCardPayment(entry)) return CARD_PAYMENT_LABEL;
  return claimLabel(entry) ?? entry.category?.name ?? null;
}

export function ledgerTitle(entry: LedgerEntry): string {
  const text = clean(entry.description);
  if (text) return text;
  if (isTransfer(entry)) return MONEY_TRANSFER_LABEL;
  if (isCardPayment(entry)) return CARD_PAYMENT_LABEL;
  const claim = claimLabel(entry);
  if (claim) return claim;
  if (entry.expenseId != null) return 'Expense';
  if (entry.incomeId != null) return 'Income';
  return entry.direction === 'credit' ? 'Deposit' : 'Withdrawal';
}
