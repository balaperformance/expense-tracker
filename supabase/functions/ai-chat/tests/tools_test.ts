import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";

import type { ToolContext } from "../tools/common.ts";
import { executeTool, findTool, TOOLS } from "../tools/registry.ts";
import { executeWrite } from "../tools/write_tools.ts";
import { ACC_HDFC, ACC_SBI, CAT_SHOPPING, FakeDb, USER_A, USER_B } from "./fakes.ts";

function ctxFor(db: FakeDb, userId = USER_A): ToolContext {
  return { userId, db, today: "2026-09-22", currency: "INR" };
}

async function run(db: FakeDb, tool: string, args: Record<string, unknown>, userId = USER_A) {
  const outcome = await executeTool(ctxFor(db, userId), tool, args);
  if (!outcome.ok) throw new Error(`tool failed: ${outcome.error}`);
  return outcome.data as Record<string, unknown>;
}

// ---------------------------------------------------------------------------
// Allowlist
// ---------------------------------------------------------------------------

Deno.test("registry: exposes exactly the allowlisted tools and nothing generic", () => {
  const names = TOOLS.map((t) => t.name).sort();
  assertEquals(names, [
    "create_expense",
    "create_income",
    "get_account_balance",
    "get_bank_statement",
    "get_budget_status",
    "get_category_spending",
    "get_expense_summary",
    "get_income_summary",
    "get_monthly_cashflow",
    "get_monthly_expenses",
    "get_recent_transactions",
    "transfer_money",
  ]);
  for (const forbidden of ["execute_sql", "query_database", "execute_rpc", "arbitrary_supabase_query", "sql"]) {
    assertEquals(findTool(forbidden), undefined);
  }
});

Deno.test("registry: unknown tool is refused without touching the database", async () => {
  const db = new FakeDb().seedSeptember();
  const outcome = await executeTool(ctxFor(db), "execute_sql", { sql: "select * from auth.users" });
  assert(!outcome.ok);
  assertStringIncludes(outcome.error, "Unknown tool");
  assertEquals(db.calls.length, 0);
});

Deno.test("registry: no tool has a parameter that names a table, column or user", () => {
  for (const tool of TOOLS) {
    for (const key of Object.keys(tool.parameters.properties ?? {})) {
      for (const bad of ["user", "table", "column", "sql", "query", "rpc", "filter"]) {
        assert(!key.toLowerCase().includes(bad), `${tool.name}.${key}`);
      }
    }
  }
});

// ---------------------------------------------------------------------------
// User isolation
// ---------------------------------------------------------------------------

Deno.test("isolation: every database call carries the caller's id and only their rows", async () => {
  const db = new FakeDb().seedSeptember();
  await run(db, "get_monthly_expenses", { month: "2026-09" });
  await run(db, "get_account_balance", {});
  await run(db, "get_income_summary", { month: "2026-09" });
  await run(db, "get_recent_transactions", { type: "all", limit: 10 });
  assert(db.calls.length > 0);
  for (const c of db.calls) assertEquals(c.userId, USER_A, c.method);
});

Deno.test("isolation: user A's totals never include user B's rows", async () => {
  const db = new FakeDb().seedSeptember();
  const a = await run(db, "get_monthly_expenses", { month: "2026-09" });
  assertEquals(a.total_expenses, 4000); // 450 + 1200 + 2350, not B's 99999
  const balances = await run(db, "get_account_balance", {});
  const names = (balances.accounts as Array<{ name: string }>).map((x) => x.name);
  assert(!names.some((n) => n.includes("Secret")));
});

Deno.test("isolation: user B sees only their own data with the same tools", async () => {
  const db = new FakeDb().seedSeptember();
  const b = await run(db, "get_monthly_expenses", { month: "2026-09" }, USER_B);
  assertEquals(b.total_expenses, 99999);
  const balances = await run(db, "get_account_balance", {}, USER_B);
  assertEquals((balances.accounts as unknown[]).length, 1);
});

Deno.test("isolation: user_id in tool arguments is rejected, not honoured", async () => {
  const db = new FakeDb().seedSeptember();
  const outcome = await executeTool(ctxFor(db), "get_monthly_expenses", {
    month: "2026-09",
    user_id: USER_B,
  });
  assert(!outcome.ok);
  assertStringIncludes(outcome.error, "not an accepted argument");
  assertEquals(db.calls.length, 0);
});

Deno.test("isolation: a stray database failure is reported generically, never verbatim", async () => {
  const db = new FakeDb().seedSeptember();
  db.failNext = "expensesInRange";
  const outcome = await executeTool(ctxFor(db), "get_monthly_expenses", {});
  assert(!outcome.ok);
  assert(!outcome.error.includes("relation"));
  assert(!outcome.error.includes("column"));
});

// ---------------------------------------------------------------------------
// Read tools
// ---------------------------------------------------------------------------

Deno.test("read: monthly expenses is an aggregate, not the rows", async () => {
  const db = new FakeDb().seedSeptember();
  const data = await run(db, "get_monthly_expenses", {});
  assertEquals(data.total_expenses, 4000);
  assertEquals(data.transaction_count, 3);
  assertEquals(data.total_expenses_text, "₹4,000");
  assertEquals("expenses" in data, false);
  assertEquals("rows" in data, false);
});

Deno.test("read: previous month resolves by YYYY-MM", async () => {
  const db = new FakeDb().seedSeptember();
  const data = await run(db, "get_monthly_expenses", { month: "2026-08" });
  assertEquals(data.total_expenses, 300);
  assertEquals(data.label, "August 2026");
});

Deno.test("read: category spending is sorted largest first with shares that sum to 100", async () => {
  const db = new FakeDb().seedSeptember();
  const data = await run(db, "get_category_spending", { month: "2026-09" });
  const categories = data.categories as Array<{ category: string; total: number; share_percent: number }>;
  assertEquals(categories.map((c) => c.category), ["Bills", "Shopping", "Food"]);
  assertEquals(categories[0].total, 2350);
  const share = categories.reduce((s, c) => s + c.share_percent, 0);
  assert(Math.abs(share - 100) < 0.2);
});

Deno.test("read: expense summary has average, largest and top category", async () => {
  const db = new FakeDb().seedSeptember();
  const data = await run(db, "get_expense_summary", { from: "2026-09-01", to: "2026-09-30" });
  assertEquals(data.total, 4000);
  assertEquals(data.average_per_expense, 1333.33);
  assertEquals((data.largest_expense as { title: string }).title, "Electricity");
  assertEquals((data.top_category as { name: string }).name, "Bills");
});

Deno.test("read: account balance is opening + credits − debits from the ledger", async () => {
  const db = new FakeDb().seedSeptember();
  const data = await run(db, "get_account_balance", {});
  const accounts = data.accounts as Array<{ name: string; balance: number }>;
  // HDFC: 10000 + 50000 − 450 − 5000 − 2350 = 52200. SBI: 500 + 5000 = 5500.
  assertEquals(accounts.find((a) => a.name.startsWith("Salary"))?.balance, 52200);
  assertEquals(accounts.find((a) => a.name === "Savings")?.balance, 5500);
  assertEquals(data.total_balance, 57700);
});

Deno.test("read: account balance can be narrowed by a fuzzy account name", async () => {
  const db = new FakeDb().seedSeptember();
  const data = await run(db, "get_account_balance", { account: "hdfc" });
  assertEquals((data.accounts as unknown[]).length, 1);
  assertEquals(data.total_balance, 52200);
});

Deno.test("read: bank statement carries opening, closing, running balance and transfer labels", async () => {
  const db = new FakeDb().seedSeptember();
  const data = await run(db, "get_bank_statement", { account: "Salary Account", month: "2026-09" });
  assertEquals(data.opening_balance, 10000);
  assertEquals(data.closing_balance, 52200);
  assertEquals(data.total_credits, 50000);
  assertEquals(data.total_debits, 7800);
  const movements = data.movements as Array<{ description: string; type: string; balance_after: number; date: string }>;
  assertEquals(movements[0].date, "2026-09-15");
  assertEquals(movements[0].balance_after, 52200);
  const transfer = movements.find((m) => m.type === "transfer_out");
  assert(transfer);
  assertEquals(transfer.description, "Money Transfer to Savings");
});

Deno.test("read: statement for a later month brings forward the earlier balance", async () => {
  const db = new FakeDb().seedSeptember();
  const data = await run(db, "get_bank_statement", { account: "Salary", month: "2026-10" });
  assertEquals(data.opening_balance, 52200);
  assertEquals(data.closing_balance, 52200);
  assertEquals(data.movement_count, 0);
});

Deno.test("read: income summary totals and ranks sources", async () => {
  const db = new FakeDb().seedSeptember();
  const data = await run(db, "get_income_summary", { month: "2026-09" });
  assertEquals(data.total_income, 54000);
  assertEquals((data.top_sources as Array<{ source: string }>)[0].source, "Salary");
});

Deno.test("read: budget status mirrors BudgetProgress thresholds", async () => {
  const db = new FakeDb().seedSeptember();
  const data = await run(db, "get_budget_status", { month: "2026-09" });
  const overall = data.overall as { spent: number; remaining: number; status: string };
  assertEquals(overall.spent, 4000);
  assertEquals(overall.remaining, 6000);
  assertEquals(overall.status, "ok");
  const categories = data.categories as Array<{ category: string; status: string; percent_used: number }>;
  assertEquals(categories.find((c) => c.category === "Shopping")?.status, "over"); // 1200 / 1000
  assertEquals(categories.find((c) => c.category === "Bills")?.status, "ok"); // 2350 / 3000 = 78%
});

Deno.test("read: cashflow lists months oldest first and nets income against expenses", async () => {
  const db = new FakeDb().seedSeptember();
  const data = await run(db, "get_monthly_cashflow", { months: 2 });
  const months = data.months as Array<{ month: string; label: string; income: number; expenses: number; net: number }>;
  assertEquals(months.map((m) => m.month), ["2026-08", "2026-09"]);
  assertEquals(months[1], { month: "2026-09", label: "September 2026", income: 54000, expenses: 4000, net: 50000 });
  assertEquals(months[0].expenses, 300);
});

Deno.test("read: recent transactions are capped and say where the money came from", async () => {
  const db = new FakeDb().seedSeptember();
  const data = await run(db, "get_recent_transactions", { type: "expenses", limit: 2 });
  const rows = data.expenses as Array<{ title: string; paid_from: string }>;
  assertEquals(rows.length, 2);
  assertEquals(rows[0].title, "Electricity");
  assertEquals(rows[0].paid_from, "Salary Account");
  assertEquals(rows[1].paid_from, "Cash");
});

Deno.test("read: empty data is an honest zero, not an error", async () => {
  const db = new FakeDb(); // nothing seeded
  const spend = await run(db, "get_monthly_expenses", {});
  assertEquals(spend.total_expenses, 0);
  const budget = await run(db, "get_budget_status", {});
  assertEquals(budget.overall, null);
  const balance = await run(db, "get_account_balance", {});
  assertEquals(balance.total_balance, 10500); // opening balances only
});

// ---------------------------------------------------------------------------
// Transfers stay out of spending
// ---------------------------------------------------------------------------

Deno.test("transfers: the ₹5,000 transfer is in neither income nor expenses nor cashflow", async () => {
  const db = new FakeDb().seedSeptember();
  const spend = await run(db, "get_monthly_expenses", { month: "2026-09" });
  const income = await run(db, "get_income_summary", { month: "2026-09" });
  const flow = await run(db, "get_monthly_cashflow", { months: 1 });
  const categories = await run(db, "get_category_spending", { month: "2026-09" });

  assertEquals(spend.total_expenses, 4000);
  assertEquals(income.total_income, 54000);
  assertEquals((flow.months as Array<{ net: number }>)[0].net, 50000);
  const names = (categories.categories as Array<{ category: string }>).map((c) => c.category);
  assert(!names.includes("Money Transfer"));
});

Deno.test("transfers: but both legs do appear on the statements, with correct balances", async () => {
  const db = new FakeDb().seedSeptember();
  const sbi = await run(db, "get_bank_statement", { account: "SBI", month: "2026-09" });
  const movements = sbi.movements as Array<{ type: string; description: string; balance_after: number }>;
  assertEquals(movements.length, 1);
  assertEquals(movements[0].type, "transfer_in");
  assertEquals(movements[0].description, "Money Transfer from Salary Account");
  assertEquals(movements[0].balance_after, 5500);
});

// ---------------------------------------------------------------------------
// Write tools: preparation never writes
// ---------------------------------------------------------------------------

Deno.test("write: create_expense in chat only prepares — nothing is inserted", async () => {
  const db = new FakeDb().seedSeptember();
  const outcome = await executeTool(ctxFor(db), "create_expense", { amount: 500, category: "shopping" });
  assert(outcome.ok);
  assert(outcome.pendingAction);
  assertEquals(outcome.pendingAction.tool, "create_expense");
  assertEquals(outcome.pendingAction.summary, "Add ₹500 expense under Shopping?");
  assertEquals(outcome.pendingAction.args.category_id, CAT_SHOPPING);
  assertEquals((outcome.data as { status: string }).status, "ready_to_confirm");
  assertEquals(db.inserted.expenses.length, 0);
  assertEquals(db.inserted.ledger.length, 0);
});

Deno.test("write: 'Add 500' with no category asks instead of guessing", async () => {
  const db = new FakeDb().seedSeptember();
  const outcome = await executeTool(ctxFor(db), "create_expense", { amount: 500 });
  assert(outcome.ok);
  assertEquals(outcome.pendingAction, undefined);
  const data = outcome.data as { status: string; missing: string; options: string[] };
  assertEquals(data.status, "needs_input");
  assertEquals(data.missing, "category");
  assertEquals(data.options, ["Food", "Shopping", "Bills"]);
  assertEquals(db.inserted.expenses.length, 0);
});

Deno.test("write: an unknown category is refused with the real options", async () => {
  const db = new FakeDb().seedSeptember();
  const outcome = await executeTool(ctxFor(db), "create_expense", { amount: 500, category: "Gambling" });
  assert(!outcome.ok);
  assertStringIncludes(outcome.error, "Food, Shopping, Bills");
});

Deno.test("write: a missing amount is a validation error, not a default", async () => {
  const db = new FakeDb().seedSeptember();
  const outcome = await executeTool(ctxFor(db), "create_expense", { category: "Food" });
  assert(!outcome.ok);
  assertStringIncludes(outcome.error, '"amount" is required');
});

Deno.test("write: dates outside the picker window and invalid dates are refused", async () => {
  const db = new FakeDb().seedSeptember();
  assert(!(await executeTool(ctxFor(db), "create_expense", { amount: 5, category: "Food", date: "2026-02-30" })).ok);
  assert(!(await executeTool(ctxFor(db), "create_expense", { amount: 5, category: "Food", date: "2010-01-01" })).ok);
  const ok = await executeTool(ctxFor(db), "create_expense", { amount: 5, category: "Food", date: "2026-09-21" });
  assert(ok.ok && ok.pendingAction);
  assertEquals(ok.pendingAction.summary, "Add ₹5 expense under Food on 21 Sep 2026?");
});

Deno.test("write: confirmed expense is inserted for the JWT user with a matching ledger debit", async () => {
  const db = new FakeDb().seedSeptember();
  const prepared = await executeTool(ctxFor(db), "create_expense", {
    amount: 500,
    category: "Shopping",
    account: "HDFC",
    payment_method: "UPI",
    merchant: "Zara",
  });
  assert(prepared.ok && prepared.pendingAction);

  const result = await executeWrite(ctxFor(db), "create_expense", prepared.pendingAction.args);
  assert(result.ok);
  assertEquals(result.reply, "Done. ₹500 was added to Shopping from Salary Account.");

  assertEquals(db.inserted.expenses.length, 1);
  assertEquals(db.inserted.expenses[0].category_id, CAT_SHOPPING);
  assertEquals(db.inserted.expenses[0].bank_account_id, ACC_HDFC);
  assertEquals(db.inserted.ledger.length, 1);
  assertEquals(db.inserted.ledger[0].direction, "debit");
  assertEquals(db.inserted.ledger[0].amount, 500);
  assertEquals(db.inserted.ledger[0].expense_id, "exp-1");
  assertEquals(db.inserted.ledger[0].description, "Zara");
  for (const c of db.calls.filter((c) => c.method.startsWith("insert"))) assertEquals(c.userId, USER_A);
});

Deno.test("write: a cash expense leaves no ledger movement", async () => {
  const db = new FakeDb().seedSeptember();
  const prepared = await executeTool(ctxFor(db), "create_expense", { amount: 120, category: "Food" });
  assert(prepared.ok && prepared.pendingAction);
  const result = await executeWrite(ctxFor(db), "create_expense", prepared.pendingAction.args);
  assert(result.ok);
  assertEquals(db.inserted.expenses.length, 1);
  assertEquals(db.inserted.ledger.length, 0);
});

Deno.test("write: a confirm payload with a foreign or deleted category id is refused", async () => {
  const db = new FakeDb().seedSeptember();
  const result = await executeWrite(ctxFor(db), "create_expense", {
    amount: 500,
    date: "2026-09-22",
    category_id: "11111111-0000-4000-8000-00000000000b", // belongs to user B
    category_name: "Food",
  });
  assert(!result.ok);
  assertEquals(db.inserted.expenses.length, 0);
});

Deno.test("write: a confirm payload cannot smuggle user_id or extra columns", async () => {
  const db = new FakeDb().seedSeptember();
  const result = await executeWrite(ctxFor(db), "create_expense", {
    amount: 500,
    date: "2026-09-22",
    category_id: CAT_SHOPPING,
    category_name: "Shopping",
    user_id: USER_B,
  });
  assert(!result.ok);
  assertEquals(db.inserted.expenses.length, 0);
});

Deno.test("write: create_income prepares, asks for a source, and credits the account on confirm", async () => {
  const db = new FakeDb().seedSeptember();
  const missing = await executeTool(ctxFor(db), "create_income", { amount: 2000 });
  assert(missing.ok);
  assertEquals((missing.data as { status: string }).status, "needs_input");

  const prepared = await executeTool(ctxFor(db), "create_income", {
    amount: 2000,
    source: "Salary",
    account: "sbi",
  });
  assert(prepared.ok && prepared.pendingAction);
  assertEquals(prepared.pendingAction.summary, "Add ₹2,000 income from Salary into Savings?");
  assertEquals(db.inserted.income.length, 0);

  const result = await executeWrite(ctxFor(db), "create_income", prepared.pendingAction.args);
  assert(result.ok);
  assertEquals(result.reply, "Done. ₹2,000 income from Salary was recorded into Savings.");
  assertEquals(db.inserted.income.length, 1);
  assertEquals(db.inserted.ledger.length, 1);
  assertEquals(db.inserted.ledger[0].direction, "credit");
  assertEquals(db.inserted.ledger[0].income_id, "inc-1");
});

Deno.test("write: transfer prepares two legs and writes them in one insert on confirm", async () => {
  const db = new FakeDb().seedSeptember();
  const prepared = await executeTool(ctxFor(db), "transfer_money", {
    amount: 1000,
    from_account: "HDFC",
    to_account: "SBI",
  });
  assert(prepared.ok && prepared.pendingAction);
  assertEquals(prepared.pendingAction.summary, "Transfer ₹1,000 from Salary Account to Savings?");
  assertEquals(db.inserted.ledger.length, 0);

  const before = db.calls.filter((c) => c.method === "insertLedgerRows").length;
  const result = await executeWrite(ctxFor(db), "transfer_money", prepared.pendingAction.args);
  assert(result.ok);
  assertEquals(result.reply, "Done. ₹1,000 moved from Salary Account to Savings.");
  assertEquals(db.calls.filter((c) => c.method === "insertLedgerRows").length, before + 1);
  assertEquals(db.inserted.ledger.length, 2);
  const [debit, credit] = db.inserted.ledger;
  assertEquals(debit.direction, "debit");
  assertEquals(debit.account_id, ACC_HDFC);
  assertEquals(credit.direction, "credit");
  assertEquals(credit.account_id, ACC_SBI);
  assertEquals(debit.transfer_group_id, credit.transfer_group_id);
  assertEquals(debit.counterparty_account_id, ACC_SBI);
  assertEquals(credit.counterparty_account_id, ACC_HDFC);
  assertEquals(debit.expense_id, undefined);
  assertEquals(credit.income_id, undefined);
  assertEquals(db.inserted.expenses.length, 0);
  assertEquals(db.inserted.income.length, 0);
});

Deno.test("write: same-account transfer is rejected", async () => {
  const db = new FakeDb().seedSeptember();
  const outcome = await executeTool(ctxFor(db), "transfer_money", {
    amount: 100,
    from_account: "HDFC",
    to_account: "Salary Account",
  });
  assert(!outcome.ok);
  assertStringIncludes(outcome.error, "two different accounts");
});

Deno.test("write: insufficient balance is rejected at preparation and again at confirm", async () => {
  const db = new FakeDb().seedSeptember();
  const tooMuch = await executeTool(ctxFor(db), "transfer_money", {
    amount: 6000,
    from_account: "SBI",
    to_account: "HDFC",
  });
  assert(!tooMuch.ok);
  assertStringIncludes(tooMuch.error, "only has ₹5,500 available");

  // Prepared while affordable, confirmed after the balance dropped.
  const prepared = await executeTool(ctxFor(db), "transfer_money", {
    amount: 5000,
    from_account: "SBI",
    to_account: "HDFC",
  });
  assert(prepared.ok && prepared.pendingAction);
  db.ledger.push({
    owner: USER_A, id: "l9", account_id: ACC_SBI, direction: "debit", amount: 1000,
    txn_date: "2026-09-22", description: "ATM", transfer_group_id: null,
    counterparty_account_id: null, created_at: "2026-09-22T01:00:00Z",
  });
  const result = await executeWrite(ctxFor(db), "transfer_money", prepared.pendingAction.args);
  assert(!result.ok);
  assertStringIncludes(result.error, "only has ₹4,500 available");
  assertEquals(db.inserted.ledger.length, 0);
});

Deno.test("write: transferring exactly the full balance is allowed", async () => {
  const db = new FakeDb().seedSeptember();
  const prepared = await executeTool(ctxFor(db), "transfer_money", {
    amount: 5500,
    from_account: "SBI",
    to_account: "HDFC",
  });
  assert(prepared.ok && prepared.pendingAction);
});

Deno.test("write: transfers are refused when the 003 migration is absent", async () => {
  const db = new FakeDb().seedSeptember();
  db.caps = { ...db.caps, transfers: false };
  const outcome = await executeTool(ctxFor(db), "transfer_money", {
    amount: 10,
    from_account: "HDFC",
    to_account: "SBI",
  });
  assert(!outcome.ok);
  assertStringIncludes(outcome.error, "not enabled");
});

Deno.test("write: executeWrite refuses read tools and unknown tools", async () => {
  const db = new FakeDb().seedSeptember();
  assert(!(await executeWrite(ctxFor(db), "get_monthly_expenses", {})).ok);
  assert(!(await executeWrite(ctxFor(db), "execute_sql", { sql: "drop table expenses" })).ok);
  assertEquals(db.calls.length, 0);
});
