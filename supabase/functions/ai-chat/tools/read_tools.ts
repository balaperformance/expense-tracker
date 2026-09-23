import { LIMITS } from "../core/limits.ts";
import type { ExpenseRow, IncomeRow, LedgerRow } from "../db/port.ts";
import {
  accountBalances,
  accountLabel,
  fail,
  findAccount,
  money,
  ok,
  PERIOD_PROPERTIES,
  resolvePeriod,
  type ToolContext,
  type ToolDefinition,
  truncatedNote,
} from "./common.ts";
import { round2, sum } from "./money.ts";
import { addMonths, monthLabel, monthOf, monthRange } from "./period.ts";

/**
 * Read tools. Each one queries through the port, aggregates in code, and
 * hands the model a small summary — never the rows the summary came from,
 * except the two "show me" tools, which are capped.
 *
 * The arithmetic deliberately reproduces the app's own (DashboardProvider,
 * BudgetProgress, buildStatement, buildCategoryBreakdown) so a figure the
 * assistant quotes is the figure the screen shows.
 */

const MONEY_TRANSFER = "Money Transfer";

function expenseTitle(e: ExpenseRow, categoryName: string | undefined): string {
  return e.merchant?.trim() || e.description?.trim() || categoryName || "Uncategorised";
}

function incomeTitle(i: IncomeRow): string {
  return i.source?.trim() || i.description?.trim() || "Income";
}

// ---------------------------------------------------------------------------

export const getMonthlyExpenses: ToolDefinition = {
  name: "get_monthly_expenses",
  kind: "read",
  description: "Total amount spent in one calendar month, with the number of expenses. " +
    "Use for 'how much did I spend this/last month'.",
  parameters: {
    type: "object",
    properties: { month: PERIOD_PROPERTIES.month },
  },
  async run(ctx, args) {
    const period = resolvePeriod({ month: args.month }, ctx.today);
    if (!period.ok) return fail(period.error);
    const rows = await ctx.db.expensesInRange(
      ctx.userId,
      period.period.from,
      period.period.toExclusive,
      LIMITS.maxRowsPerAggregate,
    );
    const total = sum(rows.map((r) => r.amount));
    return ok({
      month: period.period.month,
      label: period.period.label,
      total_expenses: total,
      total_expenses_text: money(ctx, total),
      transaction_count: rows.length,
      currency: ctx.currency,
      note: truncatedNote(rows.length),
    });
  },
};

export const getExpenseSummary: ToolDefinition = {
  name: "get_expense_summary",
  kind: "read",
  description: "Spending summary for a month or a custom date range: total, count, average, " +
    "largest single expense and top category.",
  parameters: { type: "object", properties: PERIOD_PROPERTIES },
  async run(ctx, args) {
    const period = resolvePeriod(args, ctx.today);
    if (!period.ok) return fail(period.error);
    const [rows, categories] = await Promise.all([
      ctx.db.expensesInRange(
        ctx.userId,
        period.period.from,
        period.period.toExclusive,
        LIMITS.maxRowsPerAggregate,
      ),
      ctx.db.listCategories(ctx.userId),
    ]);
    const names = new Map(categories.map((c) => [c.id, c.name]));
    const total = sum(rows.map((r) => r.amount));
    const breakdown = categoryBreakdown(rows, names);
    const largest = rows.reduce<ExpenseRow | null>(
      (best, r) => (best === null || r.amount > best.amount ? r : best),
      null,
    );
    return ok({
      period: period.period.label,
      total,
      total_text: money(ctx, total),
      transaction_count: rows.length,
      average_per_expense: rows.length === 0 ? 0 : round2(total / rows.length),
      largest_expense: largest
        ? {
          amount: largest.amount,
          title: expenseTitle(largest, names.get(largest.category_id ?? "")),
          date: largest.expense_date,
        }
        : null,
      top_category: breakdown[0]
        ? { name: breakdown[0].category, total: breakdown[0].total }
        : null,
      currency: ctx.currency,
      note: truncatedNote(rows.length),
    });
  },
};

export const getCategorySpending: ToolDefinition = {
  name: "get_category_spending",
  kind: "read",
  description: "Spending grouped by category for a month or date range, largest first, " +
    "with each category's share of the total. Use for 'where am I spending the most'.",
  parameters: {
    type: "object",
    properties: {
      ...PERIOD_PROPERTIES,
      limit: {
        type: "integer",
        description: "How many categories to return. Default 8.",
        minimum: 1,
        maximum: LIMITS.maxListedRows,
      },
    },
  },
  async run(ctx, args) {
    const period = resolvePeriod(args, ctx.today);
    if (!period.ok) return fail(period.error);
    const limit = typeof args.limit === "number" ? args.limit : 8;
    const [rows, categories] = await Promise.all([
      ctx.db.expensesInRange(
        ctx.userId,
        period.period.from,
        period.period.toExclusive,
        LIMITS.maxRowsPerAggregate,
      ),
      ctx.db.listCategories(ctx.userId),
    ]);
    const names = new Map(categories.map((c) => [c.id, c.name]));
    const total = sum(rows.map((r) => r.amount));
    const breakdown = categoryBreakdown(rows, names);
    return ok({
      period: period.period.label,
      total,
      total_text: money(ctx, total),
      categories: breakdown.slice(0, limit).map((b) => ({
        category: b.category,
        total: b.total,
        total_text: money(ctx, b.total),
        transaction_count: b.count,
        share_percent: total <= 0 ? 0 : Math.round((b.total / total) * 1000) / 10,
      })),
      category_count: breakdown.length,
      currency: ctx.currency,
      note: truncatedNote(rows.length),
    });
  },
};

export const getAccountBalance: ToolDefinition = {
  name: "get_account_balance",
  kind: "read",
  description: "Current balance of the user's bank accounts, derived from the ledger. " +
    "Optionally narrow to one account by name.",
  parameters: {
    type: "object",
    properties: {
      account: {
        type: "string",
        description: "Account nickname, bank name or last 4 digits. Omit for all accounts.",
        maxLength: 60,
      },
    },
  },
  async run(ctx, args) {
    const caps = await ctx.db.capabilities();
    if (!caps.bankAccounts) {
      return ok({ accounts: [], message: "Bank accounts are not enabled in this app yet." });
    }
    let balances = await accountBalances(ctx);
    if (balances.length === 0) {
      return ok({ accounts: [], message: "The user has not added any bank accounts." });
    }
    if (typeof args.account === "string") {
      const found = findAccount(balances.map((b) => b.account), args.account);
      if (!found.ok) return fail(found.error);
      balances = balances.filter((b) => b.account.id === found.row.id);
    }
    const total = sum(balances.map((b) => b.balance));
    return ok({
      accounts: balances.map((b) => ({
        name: accountLabel(b.account),
        bank: b.account.bank_name,
        balance: b.balance,
        balance_text: money(ctx, b.balance),
        overdrawn: b.balance < 0,
      })),
      total_balance: total,
      total_balance_text: money(ctx, total),
      currency: ctx.currency,
    });
  },
};

export const getBankStatement: ToolDefinition = {
  name: "get_bank_statement",
  kind: "read",
  description: "Statement for one bank account over a month or date range: opening and " +
    "closing balance, totals, and the most recent movements with running balance. " +
    "Transfers between the user's own accounts appear as 'Money Transfer'.",
  parameters: {
    type: "object",
    properties: {
      account: {
        type: "string",
        description: "Account nickname, bank name or last 4 digits.",
        maxLength: 60,
      },
      ...PERIOD_PROPERTIES,
      limit: {
        type: "integer",
        description: "Movements to list, newest first. Default 10.",
        minimum: 1,
        maximum: LIMITS.maxListedRows,
      },
    },
    required: ["account"],
  },
  async run(ctx, args) {
    const caps = await ctx.db.capabilities();
    if (!caps.bankAccounts) return fail("Bank accounts are not enabled in this app yet.");
    const period = resolvePeriod(args, ctx.today);
    if (!period.ok) return fail(period.error);
    const limit = typeof args.limit === "number" ? args.limit : 10;

    const accounts = await ctx.db.listAccounts(ctx.userId);
    const found = findAccount(accounts, String(args.account));
    if (!found.ok) return fail(found.error);
    const account = found.row;
    const others = new Map(accounts.map((a) => [a.id, a.nickname]));

    const [entries, priorNet] = await Promise.all([
      ctx.db.ledgerForAccount(
        ctx.userId,
        account.id,
        period.period.from,
        period.period.toExclusive,
        LIMITS.maxRowsPerAggregate,
      ),
      ctx.db.ledgerNet(ctx.userId, account.id, period.period.from),
    ]);

    const statement = buildStatement(round2(account.opening_balance + priorNet), entries);
    return ok({
      account: accountLabel(account),
      period: period.period.label,
      opening_balance: statement.opening,
      opening_balance_text: money(ctx, statement.opening),
      closing_balance: statement.closing,
      closing_balance_text: money(ctx, statement.closing),
      total_credits: statement.credits,
      total_debits: statement.debits,
      movement_count: statement.rows.length,
      showing: Math.min(limit, statement.rows.length),
      movements: statement.rows.slice(0, limit).map((row) => ({
        date: row.entry.txn_date,
        description: describeLedger(row.entry, others),
        type: row.entry.transfer_group_id
          ? (row.entry.direction === "credit" ? "transfer_in" : "transfer_out")
          : row.entry.direction,
        amount: row.entry.amount,
        balance_after: row.balanceAfter,
      })),
      currency: ctx.currency,
      note: truncatedNote(entries.length),
    });
  },
};

export const getIncomeSummary: ToolDefinition = {
  name: "get_income_summary",
  kind: "read",
  description: "Total income for a month or date range, with the top sources.",
  parameters: { type: "object", properties: PERIOD_PROPERTIES },
  async run(ctx, args) {
    const period = resolvePeriod(args, ctx.today);
    if (!period.ok) return fail(period.error);
    const rows = await ctx.db.incomeInRange(
      ctx.userId,
      period.period.from,
      period.period.toExclusive,
      LIMITS.maxRowsPerAggregate,
    );
    const total = sum(rows.map((r) => r.amount));
    const bySource = new Map<string, number>();
    for (const row of rows) {
      const key = incomeTitle(row);
      bySource.set(key, round2((bySource.get(key) ?? 0) + row.amount));
    }
    const sources = [...bySource.entries()]
      .sort((a, b) => b[1] - a[1])
      .slice(0, 5)
      .map(([source, amount]) => ({ source, total: amount, total_text: money(ctx, amount) }));
    return ok({
      period: period.period.label,
      total_income: total,
      total_income_text: money(ctx, total),
      entry_count: rows.length,
      top_sources: sources,
      currency: ctx.currency,
      note: truncatedNote(rows.length),
    });
  },
};

export const getRecentTransactions: ToolDefinition = {
  name: "get_recent_transactions",
  kind: "read",
  description: "The most recent expenses and/or income entries. Use only when the user asks " +
    "to see or list transactions; for totals use a summary tool instead.",
  parameters: {
    type: "object",
    properties: {
      type: {
        type: "string",
        description: "Which entries to list. Default 'expenses'.",
        enum: ["expenses", "income", "all"],
      },
      limit: {
        type: "integer",
        description: "How many to return. Default 5, at most 10.",
        minimum: 1,
        maximum: 10,
      },
    },
  },
  async run(ctx, args) {
    const type = (args.type as string | undefined) ?? "expenses";
    const limit = typeof args.limit === "number" ? args.limit : 5;
    const [categories, accounts] = await Promise.all([
      ctx.db.listCategories(ctx.userId),
      ctx.db.listAccounts(ctx.userId).catch(() => []),
    ]);
    const names = new Map(categories.map((c) => [c.id, c.name]));
    const accountNames = new Map(accounts.map((a) => [a.id, a.nickname]));

    const result: Record<string, unknown> = { currency: ctx.currency };
    if (type === "expenses" || type === "all") {
      const rows = await ctx.db.recentExpenses(ctx.userId, limit);
      result.expenses = rows.map((e) => ({
        date: e.expense_date,
        title: expenseTitle(e, names.get(e.category_id ?? "")),
        category: names.get(e.category_id ?? "") ?? "Uncategorised",
        amount: e.amount,
        amount_text: money(ctx, e.amount),
        paid_from: e.bank_account_id ? accountNames.get(e.bank_account_id) ?? "Bank" : "Cash",
      }));
    }
    if (type === "income" || type === "all") {
      const rows = await ctx.db.recentIncome(ctx.userId, limit);
      result.income = rows.map((i) => ({
        date: i.income_date,
        title: incomeTitle(i),
        amount: i.amount,
        amount_text: money(ctx, i.amount),
        paid_into: i.bank_account_id ? accountNames.get(i.bank_account_id) ?? "Bank" : null,
      }));
    }
    return ok(result);
  },
};

export const getBudgetStatus: ToolDefinition = {
  name: "get_budget_status",
  kind: "read",
  description: "Budgets for a month with the amount spent, remaining and percentage used, " +
    "for the overall budget and each category budget.",
  parameters: { type: "object", properties: { month: PERIOD_PROPERTIES.month } },
  async run(ctx, args) {
    const period = resolvePeriod({ month: args.month }, ctx.today);
    if (!period.ok) return fail(period.error);
    const month = period.period.month as string;
    const [budgets, expenses, categories] = await Promise.all([
      ctx.db.budgetsForMonth(ctx.userId, `${month}-01`),
      ctx.db.expensesInRange(
        ctx.userId,
        period.period.from,
        period.period.toExclusive,
        LIMITS.maxRowsPerAggregate,
      ),
      ctx.db.listCategories(ctx.userId),
    ]);
    if (budgets.length === 0) {
      return ok({ month, label: period.period.label, overall: null, categories: [],
        message: "No budgets are set for this month." });
    }
    const names = new Map(categories.map((c) => [c.id, c.name]));
    const spentByCategory = new Map<string | null, number>();
    let totalSpent = 0;
    for (const e of expenses) {
      spentByCategory.set(e.category_id, (spentByCategory.get(e.category_id) ?? 0) + e.amount);
      totalSpent += e.amount;
    }
    totalSpent = round2(totalSpent);

    const progress = (limit: number, spent: number) => {
      const remaining = round2(limit - spent);
      const ratio = limit <= 0 ? 0 : spent / limit;
      return {
        limit,
        limit_text: money(ctx, limit),
        spent: round2(spent),
        spent_text: money(ctx, round2(spent)),
        remaining,
        remaining_text: money(ctx, remaining),
        percent_used: Math.round(ratio * 1000) / 10,
        // Same thresholds as BudgetProgress in the app.
        status: spent > limit ? "over" : ratio >= 0.8 ? "approaching" : "ok",
      };
    };

    const overall = budgets.find((b) => b.category_id === null);
    return ok({
      month,
      label: period.period.label,
      overall: overall ? progress(overall.amount, totalSpent) : null,
      categories: budgets
        .filter((b) => b.category_id !== null)
        .map((b) => ({
          category: names.get(b.category_id as string) ?? "Category",
          ...progress(b.amount, spentByCategory.get(b.category_id) ?? 0),
        }))
        .sort((a, b) => b.percent_used - a.percent_used),
      currency: ctx.currency,
      note: truncatedNote(expenses.length),
    });
  },
};

export const getMonthlyCashflow: ToolDefinition = {
  name: "get_monthly_cashflow",
  kind: "read",
  description: "Income, expenses and net for each of the last few months, ending with the " +
    "current one. Transfers between the user's own accounts are not included.",
  parameters: {
    type: "object",
    properties: {
      months: {
        type: "integer",
        description: "How many months, including the current one. Default 3, at most 6.",
        minimum: 1,
        maximum: 6,
      },
    },
  },
  async run(ctx, args) {
    const count = typeof args.months === "number" ? args.months : 3;
    const current = monthOf(ctx.today);
    const first = addMonths(current, -(count - 1));
    const from = monthRange(first).from;
    const toExclusive = monthRange(current).toExclusive;
    const cap = LIMITS.maxRowsPerAggregate * count;

    const [expenses, income] = await Promise.all([
      ctx.db.expensesInRange(ctx.userId, from, toExclusive, cap),
      ctx.db.incomeInRange(ctx.userId, from, toExclusive, cap),
    ]);

    const expenseByMonth = new Map<string, number>();
    for (const e of expenses) {
      const key = monthOf(e.expense_date);
      expenseByMonth.set(key, (expenseByMonth.get(key) ?? 0) + e.amount);
    }
    const incomeByMonth = new Map<string, number>();
    for (const i of income) {
      const key = monthOf(i.income_date);
      incomeByMonth.set(key, (incomeByMonth.get(key) ?? 0) + i.amount);
    }

    const months = [];
    for (let i = 0; i < count; i++) {
      const key = addMonths(first, i);
      const spent = round2(expenseByMonth.get(key) ?? 0);
      const earned = round2(incomeByMonth.get(key) ?? 0);
      months.push({
        month: key,
        label: monthLabel(key),
        income: earned,
        expenses: spent,
        net: round2(earned - spent),
      });
    }
    const totalIncome = sum(months.map((m) => m.income));
    const totalExpenses = sum(months.map((m) => m.expenses));
    return ok({
      months,
      total_income: totalIncome,
      total_expenses: totalExpenses,
      net: round2(totalIncome - totalExpenses),
      net_text: money(ctx, round2(totalIncome - totalExpenses)),
      currency: ctx.currency,
      note: truncatedNote(Math.max(expenses.length, income.length), cap),
    });
  },
};

export const READ_TOOLS: readonly ToolDefinition[] = [
  getMonthlyExpenses,
  getExpenseSummary,
  getCategorySpending,
  getAccountBalance,
  getBankStatement,
  getIncomeSummary,
  getRecentTransactions,
  getBudgetStatus,
  getMonthlyCashflow,
];

// ---------------------------------------------------------------------------
// Pure helpers (exported for tests)
// ---------------------------------------------------------------------------

export function categoryBreakdown(
  rows: ExpenseRow[],
  names: Map<string, string>,
): Array<{ category: string; total: number; count: number }> {
  const totals = new Map<string | null, { total: number; count: number }>();
  for (const row of rows) {
    const entry = totals.get(row.category_id) ?? { total: 0, count: 0 };
    entry.total += row.amount;
    entry.count += 1;
    totals.set(row.category_id, entry);
  }
  return [...totals.entries()]
    .map(([id, v]) => ({
      category: id === null ? "Uncategorised" : names.get(id) ?? "Uncategorised",
      total: round2(v.total),
      count: v.count,
    }))
    .sort((a, b) => b.total - a.total);
}

export type StatementRow = { entry: LedgerRow; balanceAfter: number };

/** Same walk as the app's `buildStatement`: oldest-first, then reversed. */
export function buildStatement(
  opening: number,
  entries: LedgerRow[],
): { opening: number; closing: number; credits: number; debits: number; rows: StatementRow[] } {
  const ordered = [...entries].sort((a, b) => {
    if (a.txn_date !== b.txn_date) return a.txn_date < b.txn_date ? -1 : 1;
    const ac = a.created_at ?? "";
    const bc = b.created_at ?? "";
    if (ac !== bc) return ac < bc ? -1 : 1;
    return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
  });
  let running = opening;
  let credits = 0;
  let debits = 0;
  const rows: StatementRow[] = [];
  for (const entry of ordered) {
    running = round2(running + (entry.direction === "credit" ? entry.amount : -entry.amount));
    if (entry.direction === "credit") credits += entry.amount;
    else debits += entry.amount;
    rows.push({ entry, balanceAfter: running });
  }
  return {
    opening,
    closing: round2(opening + credits - debits),
    credits: round2(credits),
    debits: round2(debits),
    rows: rows.reverse(),
  };
}

function describeLedger(entry: LedgerRow, nicknames: Map<string, string>): string {
  if (entry.transfer_group_id) {
    const other = entry.counterparty_account_id
      ? nicknames.get(entry.counterparty_account_id)
      : undefined;
    const direction = entry.direction === "credit" ? "from" : "to";
    return other ? `${MONEY_TRANSFER} ${direction} ${other}` : MONEY_TRANSFER;
  }
  return entry.description?.trim() || (entry.direction === "credit" ? "Deposit" : "Withdrawal");
}
