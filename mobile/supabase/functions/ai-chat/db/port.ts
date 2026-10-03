/**
 * The whole of what the assistant may do to the database.
 *
 * This interface is the security boundary between the AI and the data. There
 * is no method that takes a table name, a column name, a filter expression or
 * SQL. Every method takes the authenticated `userId` from the verified JWT
 * and every implementation must scope by it — on top of the RLS that the
 * user-scoped client already enforces. A tool that needs something not on
 * this list has to add a method here, in review, rather than reach around it.
 */

export type CategoryRow = { id: string; name: string };

export type PaymentMethodRow = { id: string; name: string };

export type AccountRow = {
  id: string;
  bank_name: string;
  nickname: string;
  last4: string | null;
  opening_balance: number;
  is_active: boolean;
};

export type LedgerTotalRow = {
  account_id: string;
  direction: "debit" | "credit";
  amount: number;
};

export type ExpenseRow = {
  id: string;
  amount: number;
  expense_date: string;
  category_id: string | null;
  payment_method_id: string | null;
  bank_account_id: string | null;
  description: string | null;
  merchant: string | null;
};

export type IncomeRow = {
  id: string;
  amount: number;
  income_date: string;
  source: string | null;
  description: string | null;
  bank_account_id: string | null;
};

export type LedgerRow = {
  id: string;
  account_id: string;
  direction: "debit" | "credit";
  amount: number;
  txn_date: string;
  description: string | null;
  transfer_group_id: string | null;
  counterparty_account_id: string | null;
  created_at: string | null;
};

export type BudgetRow = {
  id: string;
  amount: number;
  category_id: string | null;
};

/** Which optional migrations the database has. Mirrors SchemaCapabilities. */
export type Capabilities = {
  merchant: boolean;
  bankAccounts: boolean;
  expenseBankLink: boolean;
  incomeBankLink: boolean;
  transfers: boolean;
};

export type NewExpense = {
  amount: number;
  expense_date: string;
  category_id: string | null;
  payment_method_id: string | null;
  bank_account_id: string | null;
  merchant: string | null;
  description: string | null;
};

export type NewIncome = {
  amount: number;
  income_date: string;
  source: string | null;
  description: string | null;
  bank_account_id: string | null;
};

export type NewLedgerRow = {
  account_id: string;
  direction: "debit" | "credit";
  amount: number;
  txn_date: string;
  description: string | null;
  category_id?: string | null;
  expense_id?: string;
  income_id?: string;
  transfer_group_id?: string;
  counterparty_account_id?: string;
};

export interface DbPort {
  capabilities(): Promise<Capabilities>;

  profileCurrency(userId: string): Promise<string | null>;
  listCategories(userId: string): Promise<CategoryRow[]>;
  listPaymentMethods(userId: string): Promise<PaymentMethodRow[]>;
  listAccounts(userId: string): Promise<AccountRow[]>;

  /** Every movement's account, direction and amount — for balances. */
  ledgerTotals(userId: string): Promise<LedgerTotalRow[]>;

  expensesInRange(
    userId: string,
    fromInclusive: string,
    toExclusive: string,
    limit: number,
  ): Promise<ExpenseRow[]>;

  incomeInRange(
    userId: string,
    fromInclusive: string,
    toExclusive: string,
    limit: number,
  ): Promise<IncomeRow[]>;

  recentExpenses(userId: string, limit: number): Promise<ExpenseRow[]>;
  recentIncome(userId: string, limit: number): Promise<IncomeRow[]>;

  ledgerForAccount(
    userId: string,
    accountId: string,
    fromInclusive: string | null,
    toExclusive: string | null,
    limit: number,
  ): Promise<LedgerRow[]>;

  /** Credits minus debits, optionally only before a date. */
  ledgerNet(userId: string, accountId: string, before: string | null): Promise<number>;

  budgetsForMonth(userId: string, monthFirstDay: string): Promise<BudgetRow[]>;

  insertExpense(userId: string, row: NewExpense): Promise<{ id: string }>;
  insertIncome(userId: string, row: NewIncome): Promise<{ id: string }>;

  /** One statement. Two rows for a transfer commit together or not at all. */
  insertLedgerRows(userId: string, rows: NewLedgerRow[]): Promise<void>;
}

/** Thrown by an adapter when the database refuses; carries no raw message. */
export class DbError extends Error {
  readonly code: string | null;

  constructor(code: string | null) {
    super(`database error ${code ?? "unknown"}`);
    this.name = "DbError";
    this.code = code;
  }
}
