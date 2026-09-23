import type { Completion, CompletionRequest } from "../core/messages.ts";
import type {
  AccountRow,
  BudgetRow,
  Capabilities,
  CategoryRow,
  DbPort,
  ExpenseRow,
  IncomeRow,
  LedgerRow,
  LedgerTotalRow,
  NewExpense,
  NewIncome,
  NewLedgerRow,
  PaymentMethodRow,
} from "../db/port.ts";
import type { AIProvider } from "../providers/provider.ts";
import { ProviderError } from "../providers/provider.ts";

export const USER_A = "aaaaaaaa-0000-4000-8000-00000000000a";
export const USER_B = "bbbbbbbb-0000-4000-8000-00000000000b";

export const CAT_FOOD = "11111111-0000-4000-8000-000000000001";
export const CAT_SHOPPING = "11111111-0000-4000-8000-000000000002";
export const CAT_BILLS = "11111111-0000-4000-8000-000000000003";
export const PM_CASH = "22222222-0000-4000-8000-000000000001";
export const PM_UPI = "22222222-0000-4000-8000-000000000002";
export const ACC_HDFC = "33333333-0000-4000-8000-000000000001";
export const ACC_SBI = "33333333-0000-4000-8000-000000000002";
export const ACC_B = "33333333-0000-4000-8000-00000000000b";

type Owned<T> = T & { owner: string };

/**
 * In-memory DbPort that behaves like RLS: every row has an owner and every
 * method returns only the caller's rows. It also records the userId passed
 * to each call so tests can prove the tools never query as anyone else.
 */
export class FakeDb implements DbPort {
  caps: Capabilities = {
    merchant: true,
    bankAccounts: true,
    expenseBankLink: true,
    incomeBankLink: true,
    transfers: true,
  };
  currencyByUser = new Map<string, string>([[USER_A, "INR"], [USER_B, "USD"]]);

  categories: Owned<CategoryRow>[] = [
    { owner: USER_A, id: CAT_FOOD, name: "Food" },
    { owner: USER_A, id: CAT_SHOPPING, name: "Shopping" },
    { owner: USER_A, id: CAT_BILLS, name: "Bills" },
    { owner: USER_B, id: "11111111-0000-4000-8000-00000000000b", name: "Food" },
  ];
  methods: Owned<PaymentMethodRow>[] = [
    { owner: USER_A, id: PM_CASH, name: "Cash" },
    { owner: USER_A, id: PM_UPI, name: "UPI" },
  ];
  accounts: Owned<AccountRow>[] = [
    { owner: USER_A, id: ACC_HDFC, bank_name: "HDFC Bank", nickname: "Salary Account", last4: "4821", opening_balance: 10000, is_active: true },
    { owner: USER_A, id: ACC_SBI, bank_name: "SBI", nickname: "Savings", last4: null, opening_balance: 500, is_active: true },
    { owner: USER_B, id: ACC_B, bank_name: "ICICI", nickname: "Secret", last4: "9999", opening_balance: 1_000_000, is_active: true },
  ];
  expenses: Owned<ExpenseRow>[] = [];
  income: Owned<IncomeRow>[] = [];
  ledger: Owned<LedgerRow>[] = [];
  budgets: Array<Owned<BudgetRow> & { month: string }> = [];

  calls: Array<{ method: string; userId: string }> = [];
  inserted = { expenses: [] as NewExpense[], income: [] as NewIncome[], ledger: [] as NewLedgerRow[] };
  failNext: string | null = null;

  private record(method: string, userId: string) {
    this.calls.push({ method, userId });
    if (this.failNext === method) {
      this.failNext = null;
      throw new Error("simulated database failure: relation \"expenses\" column x");
    }
  }

  private mine<T extends { owner: string }>(rows: T[], userId: string): T[] {
    return rows.filter((r) => r.owner === userId).map((r) => {
      const { owner: _owner, ...rest } = r;
      return rest as unknown as T;
    });
  }

  capabilities(): Promise<Capabilities> {
    return Promise.resolve(this.caps);
  }
  profileCurrency(userId: string): Promise<string | null> {
    this.record("profileCurrency", userId);
    return Promise.resolve(this.currencyByUser.get(userId) ?? null);
  }
  listCategories(userId: string): Promise<CategoryRow[]> {
    this.record("listCategories", userId);
    return Promise.resolve(this.mine(this.categories, userId));
  }
  listPaymentMethods(userId: string): Promise<PaymentMethodRow[]> {
    this.record("listPaymentMethods", userId);
    return Promise.resolve(this.mine(this.methods, userId));
  }
  listAccounts(userId: string): Promise<AccountRow[]> {
    this.record("listAccounts", userId);
    return Promise.resolve(this.mine(this.accounts, userId));
  }
  ledgerTotals(userId: string): Promise<LedgerTotalRow[]> {
    this.record("ledgerTotals", userId);
    return Promise.resolve(
      this.mine(this.ledger, userId).map((l) => ({
        account_id: l.account_id,
        direction: l.direction,
        amount: l.amount,
      })),
    );
  }
  expensesInRange(userId: string, from: string, toExclusive: string, limit: number): Promise<ExpenseRow[]> {
    this.record("expensesInRange", userId);
    return Promise.resolve(
      this.mine(this.expenses, userId)
        .filter((e) => e.expense_date >= from && e.expense_date < toExclusive)
        .sort((a, b) => (a.expense_date < b.expense_date ? 1 : -1))
        .slice(0, limit),
    );
  }
  incomeInRange(userId: string, from: string, toExclusive: string, limit: number): Promise<IncomeRow[]> {
    this.record("incomeInRange", userId);
    return Promise.resolve(
      this.mine(this.income, userId)
        .filter((i) => i.income_date >= from && i.income_date < toExclusive)
        .slice(0, limit),
    );
  }
  recentExpenses(userId: string, limit: number): Promise<ExpenseRow[]> {
    this.record("recentExpenses", userId);
    return Promise.resolve(
      this.mine(this.expenses, userId)
        .sort((a, b) => (a.expense_date < b.expense_date ? 1 : -1))
        .slice(0, limit),
    );
  }
  recentIncome(userId: string, limit: number): Promise<IncomeRow[]> {
    this.record("recentIncome", userId);
    return Promise.resolve(this.mine(this.income, userId).slice(0, limit));
  }
  ledgerForAccount(userId: string, accountId: string, from: string | null, toExclusive: string | null, limit: number): Promise<LedgerRow[]> {
    this.record("ledgerForAccount", userId);
    return Promise.resolve(
      this.mine(this.ledger, userId)
        .filter((l) => l.account_id === accountId)
        .filter((l) => (from ? l.txn_date >= from : true) && (toExclusive ? l.txn_date < toExclusive : true))
        .slice(0, limit),
    );
  }
  ledgerNet(userId: string, accountId: string, before: string | null): Promise<number> {
    this.record("ledgerNet", userId);
    let net = 0;
    for (const l of this.mine(this.ledger, userId)) {
      if (l.account_id !== accountId) continue;
      if (before && !(l.txn_date < before)) continue;
      net += l.direction === "credit" ? l.amount : -l.amount;
    }
    return Promise.resolve(net);
  }
  budgetsForMonth(userId: string, monthFirstDay: string): Promise<BudgetRow[]> {
    this.record("budgetsForMonth", userId);
    return Promise.resolve(
      this.mine(this.budgets, userId)
        .filter((b) => b.month === monthFirstDay)
        .map(({ id, amount, category_id }) => ({ id, amount, category_id })),
    );
  }
  insertExpense(userId: string, row: NewExpense): Promise<{ id: string }> {
    this.record("insertExpense", userId);
    this.inserted.expenses.push(row);
    const id = `exp-${this.inserted.expenses.length}`;
    this.expenses.push({ owner: userId, id, ...row });
    return Promise.resolve({ id });
  }
  insertIncome(userId: string, row: NewIncome): Promise<{ id: string }> {
    this.record("insertIncome", userId);
    this.inserted.income.push(row);
    const id = `inc-${this.inserted.income.length}`;
    this.income.push({ owner: userId, id, ...row });
    return Promise.resolve({ id });
  }
  insertLedgerRows(userId: string, rows: NewLedgerRow[]): Promise<void> {
    this.record("insertLedgerRows", userId);
    for (const row of rows) {
      this.inserted.ledger.push(row);
      this.ledger.push({
        owner: userId,
        id: `led-${this.ledger.length + 1}`,
        account_id: row.account_id,
        direction: row.direction,
        amount: row.amount,
        txn_date: row.txn_date,
        description: row.description,
        transfer_group_id: row.transfer_group_id ?? null,
        counterparty_account_id: row.counterparty_account_id ?? null,
        created_at: `2026-09-22T00:00:${String(this.ledger.length).padStart(2, "0")}Z`,
      });
    }
    return Promise.resolve();
  }

  /** Seeds a September-2026 month of realistic data for USER_A and a
   * poisoned copy for USER_B. */
  seedSeptember(): FakeDb {
    const a = USER_A;
    this.expenses.push(
      { owner: a, id: "e1", amount: 450, expense_date: "2026-09-03", category_id: CAT_FOOD, payment_method_id: PM_UPI, bank_account_id: ACC_HDFC, description: "Groceries", merchant: "Green Leaf" },
      { owner: a, id: "e2", amount: 1200, expense_date: "2026-09-10", category_id: CAT_SHOPPING, payment_method_id: PM_CASH, bank_account_id: null, description: null, merchant: "Zara" },
      { owner: a, id: "e3", amount: 2350, expense_date: "2026-09-15", category_id: CAT_BILLS, payment_method_id: null, bank_account_id: ACC_HDFC, description: "Electricity", merchant: null },
      { owner: a, id: "e4", amount: 300, expense_date: "2026-08-28", category_id: CAT_FOOD, payment_method_id: null, bank_account_id: null, description: "August lunch", merchant: null },
      { owner: USER_B, id: "eb", amount: 99999, expense_date: "2026-09-05", category_id: null, payment_method_id: null, bank_account_id: null, description: "B's secret", merchant: null },
    );
    this.income.push(
      { owner: a, id: "i1", amount: 50000, income_date: "2026-09-01", source: "Salary", description: null, bank_account_id: ACC_HDFC },
      { owner: a, id: "i2", amount: 4000, income_date: "2026-09-12", source: "Freelance", description: null, bank_account_id: null },
      { owner: USER_B, id: "ib", amount: 777777, income_date: "2026-09-02", source: "B salary", description: null, bank_account_id: ACC_B },
    );
    this.ledger.push(
      { owner: a, id: "l1", account_id: ACC_HDFC, direction: "credit", amount: 50000, txn_date: "2026-09-01", description: "Salary", transfer_group_id: null, counterparty_account_id: null, created_at: "2026-09-01T09:00:00Z" },
      { owner: a, id: "l2", account_id: ACC_HDFC, direction: "debit", amount: 450, txn_date: "2026-09-03", description: "Green Leaf", transfer_group_id: null, counterparty_account_id: null, created_at: "2026-09-03T09:00:00Z" },
      // A transfer: two legs, one group, no expense/income row anywhere.
      { owner: a, id: "l3", account_id: ACC_HDFC, direction: "debit", amount: 5000, txn_date: "2026-09-08", description: "Transfer to Savings", transfer_group_id: "g1", counterparty_account_id: ACC_SBI, created_at: "2026-09-08T09:00:00Z" },
      { owner: a, id: "l4", account_id: ACC_SBI, direction: "credit", amount: 5000, txn_date: "2026-09-08", description: "Transfer from Salary Account", transfer_group_id: "g1", counterparty_account_id: ACC_HDFC, created_at: "2026-09-08T09:00:01Z" },
      { owner: a, id: "l5", account_id: ACC_HDFC, direction: "debit", amount: 2350, txn_date: "2026-09-15", description: "Electricity", transfer_group_id: null, counterparty_account_id: null, created_at: "2026-09-15T09:00:00Z" },
      { owner: USER_B, id: "lb", account_id: ACC_B, direction: "credit", amount: 777777, txn_date: "2026-09-02", description: "B salary", transfer_group_id: null, counterparty_account_id: null, created_at: "2026-09-02T09:00:00Z" },
    );
    this.budgets.push(
      { owner: a, id: "b1", amount: 10000, category_id: null, month: "2026-09-01" },
      { owner: a, id: "b2", amount: 1000, category_id: CAT_SHOPPING, month: "2026-09-01" },
      { owner: a, id: "b3", amount: 3000, category_id: CAT_BILLS, month: "2026-09-01" },
    );
    return this;
  }
}

/** Provider whose answers are scripted. Each call consumes the next entry. */
export class FakeProvider implements AIProvider {
  readonly requests: CompletionRequest[] = [];
  readonly model = "fake-model";

  constructor(
    readonly name: string,
    private readonly script: Array<Completion | ProviderError | ((req: CompletionRequest) => Completion)>,
  ) {}

  complete(request: CompletionRequest): Promise<Completion> {
    this.requests.push(request);
    const next = this.script.shift();
    if (next === undefined) {
      return Promise.resolve({ text: "(script exhausted)", toolCalls: [] });
    }
    if (next instanceof ProviderError) return Promise.reject(next);
    if (typeof next === "function") return Promise.resolve(next(request));
    return Promise.resolve(next);
  }
}

export function text(content: string): Completion {
  return { text: content, toolCalls: [] };
}

export function call(name: string, args: Record<string, unknown>, id = `call-${name}`): Completion {
  return { text: "", toolCalls: [{ id, name, args }] };
}

export function rateLimited(provider: string): ProviderError {
  return new ProviderError(provider, "rate_limited", "429", 429);
}
