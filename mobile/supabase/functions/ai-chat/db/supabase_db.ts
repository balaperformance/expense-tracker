import type { SupabaseClient } from "npm:@supabase/supabase-js@2";

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
} from "./port.ts";
import { DbError } from "./port.ts";

/**
 * DbPort over a Supabase client that carries the *user's* JWT.
 *
 * The client is built with the publishable key plus the caller's
 * Authorization header, so PostgREST evaluates every policy as that user.
 * The explicit `user_id` filters here are the same belt-and-braces the Flutter
 * repositories use: RLS is the guarantee, the filter makes the intent visible
 * and keeps result sets small.
 */
export class SupabaseDb implements DbPort {
  private static capabilityCache: { at: number; value: Capabilities } | null = null;
  private static readonly capabilityTtlMs = 5 * 60_000;

  constructor(private readonly client: SupabaseClient) {}

  async capabilities(): Promise<Capabilities> {
    const cached = SupabaseDb.capabilityCache;
    if (cached && Date.now() - cached.at < SupabaseDb.capabilityTtlMs) {
      return cached.value;
    }
    const [merchant, bankAccounts, expenseBankLink, incomeBankLink, transfers] =
      await Promise.all([
        this.probe("expenses", "merchant"),
        this.probe("bank_accounts", "id"),
        this.probe("expenses", "bank_account_id"),
        this.probe("income", "bank_account_id"),
        this.probe("account_transactions", "counterparty_account_id"),
      ]);
    const value = { merchant, bankAccounts, expenseBankLink, incomeBankLink, transfers };
    SupabaseDb.capabilityCache = { at: Date.now(), value };
    return value;
  }

  /** PostgREST validates the column list before reading, so an empty result
   * still proves the shape exists. Only "missing" codes mean absent. */
  private async probe(table: string, column: string): Promise<boolean> {
    const { error } = await this.client.from(table).select(column).limit(1);
    if (!error) return true;
    if (error.code === "42703" || error.code === "PGRST205") return false;
    throw new DbError(error.code ?? null);
  }

  async profileCurrency(userId: string): Promise<string | null> {
    const { data, error } = await this.client
      .from("profiles")
      .select("currency")
      .eq("id", userId)
      .maybeSingle();
    if (error) throw new DbError(error.code ?? null);
    const currency = (data as { currency?: string } | null)?.currency;
    return typeof currency === "string" && currency.length === 3 ? currency : null;
  }

  async listCategories(userId: string): Promise<CategoryRow[]> {
    const { data, error } = await this.client
      .from("categories")
      .select("id, name")
      .eq("user_id", userId)
      .order("name", { ascending: true });
    if (error) throw new DbError(error.code ?? null);
    return rows(data) as unknown as CategoryRow[];
  }

  async listPaymentMethods(userId: string): Promise<PaymentMethodRow[]> {
    const { data, error } = await this.client
      .from("payment_methods")
      .select("id, name")
      .eq("user_id", userId)
      .order("name", { ascending: true });
    if (error) throw new DbError(error.code ?? null);
    return rows(data) as unknown as PaymentMethodRow[];
  }

  async listAccounts(userId: string): Promise<AccountRow[]> {
    const { data, error } = await this.client
      .from("bank_accounts")
      .select("id, bank_name, nickname, last4, opening_balance, is_active")
      .eq("user_id", userId)
      .order("created_at", { ascending: true });
    if (error) {
      if (error.code === "PGRST205") return [];
      throw new DbError(error.code ?? null);
    }
    return rows(data).map((row) => ({
      id: String(row.id),
      bank_name: String(row.bank_name ?? "Bank"),
      nickname: String(row.nickname ?? "Account"),
      last4: (row.last4 as string | null) ?? null,
      opening_balance: Number(row.opening_balance ?? 0),
      is_active: row.is_active !== false,
    }));
  }

  async ledgerTotals(userId: string): Promise<LedgerTotalRow[]> {
    const { data, error } = await this.client
      .from("account_transactions")
      .select("account_id, direction, amount")
      .eq("user_id", userId);
    if (error) {
      if (error.code === "PGRST205") return [];
      throw new DbError(error.code ?? null);
    }
    return rows(data).map((row) => ({
      account_id: String(row.account_id),
      direction: row.direction === "credit" ? "credit" : "debit",
      amount: Number(row.amount ?? 0),
    }));
  }

  async expensesInRange(
    userId: string,
    fromInclusive: string,
    toExclusive: string,
    limit: number,
  ): Promise<ExpenseRow[]> {
    const caps = await this.capabilities();
    const { data, error } = await this.client
      .from("expenses")
      .select(expenseColumns(caps))
      .eq("user_id", userId)
      .gte("expense_date", fromInclusive)
      .lt("expense_date", toExclusive)
      .order("expense_date", { ascending: false })
      .limit(limit);
    if (error) throw new DbError(error.code ?? null);
    return rows(data).map(mapExpense);
  }

  async recentExpenses(userId: string, limit: number): Promise<ExpenseRow[]> {
    const caps = await this.capabilities();
    const { data, error } = await this.client
      .from("expenses")
      .select(expenseColumns(caps))
      .eq("user_id", userId)
      .order("expense_date", { ascending: false })
      .order("created_at", { ascending: false })
      .limit(limit);
    if (error) throw new DbError(error.code ?? null);
    return rows(data).map(mapExpense);
  }

  async incomeInRange(
    userId: string,
    fromInclusive: string,
    toExclusive: string,
    limit: number,
  ): Promise<IncomeRow[]> {
    const caps = await this.capabilities();
    const { data, error } = await this.client
      .from("income")
      .select(incomeColumns(caps))
      .eq("user_id", userId)
      .gte("income_date", fromInclusive)
      .lt("income_date", toExclusive)
      .order("income_date", { ascending: false })
      .limit(limit);
    if (error) throw new DbError(error.code ?? null);
    return rows(data).map(mapIncome);
  }

  async recentIncome(userId: string, limit: number): Promise<IncomeRow[]> {
    const caps = await this.capabilities();
    const { data, error } = await this.client
      .from("income")
      .select(incomeColumns(caps))
      .eq("user_id", userId)
      .order("income_date", { ascending: false })
      .order("created_at", { ascending: false })
      .limit(limit);
    if (error) throw new DbError(error.code ?? null);
    return rows(data).map(mapIncome);
  }

  async ledgerForAccount(
    userId: string,
    accountId: string,
    fromInclusive: string | null,
    toExclusive: string | null,
    limit: number,
  ): Promise<LedgerRow[]> {
    const caps = await this.capabilities();
    const columns = "id, account_id, direction, amount, txn_date, description, " +
      "transfer_group_id, created_at" +
      (caps.transfers ? ", counterparty_account_id" : "");

    let query = this.client
      .from("account_transactions")
      .select(columns)
      .eq("user_id", userId)
      .eq("account_id", accountId);
    if (fromInclusive) query = query.gte("txn_date", fromInclusive);
    if (toExclusive) query = query.lt("txn_date", toExclusive);

    const { data, error } = await query.order("txn_date", { ascending: false }).limit(limit);
    if (error) throw new DbError(error.code ?? null);

    return rows(data).map((row) => ({
      id: String(row.id),
      account_id: String(row.account_id),
      direction: row.direction === "credit" ? "credit" : "debit",
      amount: Number(row.amount ?? 0),
      txn_date: String(row.txn_date),
      description: (row.description as string | null) ?? null,
      transfer_group_id: (row.transfer_group_id as string | null) ?? null,
      counterparty_account_id: (row.counterparty_account_id as string | null) ?? null,
      created_at: (row.created_at as string | null) ?? null,
    }));
  }

  async ledgerNet(userId: string, accountId: string, before: string | null): Promise<number> {
    let query = this.client
      .from("account_transactions")
      .select("direction, amount")
      .eq("user_id", userId)
      .eq("account_id", accountId);
    if (before) query = query.lt("txn_date", before);

    const { data, error } = await query;
    if (error) throw new DbError(error.code ?? null);

    let net = 0;
    for (const row of rows(data)) {
      const amount = Number(row.amount ?? 0);
      net += row.direction === "credit" ? amount : -amount;
    }
    return net;
  }

  async budgetsForMonth(userId: string, monthFirstDay: string): Promise<BudgetRow[]> {
    const { data, error } = await this.client
      .from("budgets")
      .select("id, amount, category_id")
      .eq("user_id", userId)
      .eq("month", monthFirstDay);
    if (error) throw new DbError(error.code ?? null);
    return rows(data).map((row) => ({
      id: String(row.id),
      amount: Number(row.amount ?? 0),
      category_id: (row.category_id as string | null) ?? null,
    }));
  }

  async insertExpense(userId: string, row: NewExpense): Promise<{ id: string }> {
    const caps = await this.capabilities();
    // user_id comes from the verified JWT via the parameter, never from the
    // row, which has no such field to begin with.
    const payload: Record<string, unknown> = {
      user_id: userId,
      amount: row.amount,
      expense_date: row.expense_date,
      category_id: row.category_id,
      payment_method_id: row.payment_method_id,
      description: row.description,
    };
    if (caps.merchant) payload.merchant = row.merchant;
    if (caps.expenseBankLink) payload.bank_account_id = row.bank_account_id;

    const { data, error } = await this.client
      .from("expenses")
      .insert(payload)
      .select("id")
      .single();
    if (error) throw new DbError(error.code ?? null);
    return { id: String((data as { id: unknown }).id) };
  }

  async insertIncome(userId: string, row: NewIncome): Promise<{ id: string }> {
    const caps = await this.capabilities();
    const payload: Record<string, unknown> = {
      user_id: userId,
      amount: row.amount,
      income_date: row.income_date,
      source: row.source,
      description: row.description,
    };
    if (caps.incomeBankLink) payload.bank_account_id = row.bank_account_id;

    const { data, error } = await this.client
      .from("income")
      .insert(payload)
      .select("id")
      .single();
    if (error) throw new DbError(error.code ?? null);
    return { id: String((data as { id: unknown }).id) };
  }

  async insertLedgerRows(userId: string, rows: NewLedgerRow[]): Promise<void> {
    if (rows.length === 0) return;
    const payload = rows.map((row) => ({ ...row, user_id: userId }));
    const { error } = await this.client.from("account_transactions").insert(payload);
    if (error) throw new DbError(error.code ?? null);
  }
}

function expenseColumns(caps: Capabilities): string {
  return "id, amount, expense_date, category_id, payment_method_id, description" +
    (caps.merchant ? ", merchant" : "") +
    (caps.expenseBankLink ? ", bank_account_id" : "");
}

function incomeColumns(caps: Capabilities): string {
  return "id, amount, income_date, source, description" +
    (caps.incomeBankLink ? ", bank_account_id" : "");
}

function mapExpense(raw: unknown): ExpenseRow {
  const row = raw as Record<string, unknown>;
  return {
    id: String(row.id),
    amount: Number(row.amount ?? 0),
    expense_date: String(row.expense_date),
    category_id: (row.category_id as string | null) ?? null,
    payment_method_id: (row.payment_method_id as string | null) ?? null,
    bank_account_id: (row.bank_account_id as string | null) ?? null,
    description: (row.description as string | null) ?? null,
    merchant: (row.merchant as string | null) ?? null,
  };
}

function mapIncome(raw: unknown): IncomeRow {
  const row = raw as Record<string, unknown>;
  return {
    id: String(row.id),
    amount: Number(row.amount ?? 0),
    income_date: String(row.income_date),
    source: (row.source as string | null) ?? null,
    description: (row.description as string | null) ?? null,
    bank_account_id: (row.bank_account_id as string | null) ?? null,
  };
}

/** PostgREST rows as plain records. The select strings here are built at
 * runtime, so supabase-js cannot type them; this is the one place that cast
 * lives. */
function rows(data: unknown): Array<Record<string, unknown>> {
  return Array.isArray(data) ? (data as Array<Record<string, unknown>>) : [];
}
