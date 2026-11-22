/**
 * Credit card accounting in the assistant (migration 022):
 *   * spending figures leave out exactly what the apps leave out;
 *   * a card bill is never recorded as an expense, and is recorded once;
 *   * a card purchase is an expense on the card, with no bank movement.
 */
import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";

import { createHandler, type HandlerDeps } from "../core/handler.ts";
import { RateLimiter } from "../core/limits.ts";
import { OwnSpendingDb } from "../db/own_spending.ts";
import { looksLikeCardBillPayment, type ToolContext } from "../tools/common.ts";
import { executeTool } from "../tools/registry.ts";
import { executeWrite } from "../tools/write_tools.ts";
import { ACC_HDFC, ACC_SBI, call, CARD_AXIS, CARD_B, CARD_HDFC, FakeDb, FakeProvider, seedTags, text, USER_A, USER_B } from "./fakes.ts";

function ctxFor(db: FakeDb, userId = USER_A): ToolContext {
  // As the handler builds it: the port wrapped so spending reads leave out what is not the user's.
  return { userId, db: new OwnSpendingDb(db), today: "2026-11-22", currency: "INR" };
}

async function run(db: FakeDb, tool: string, args: Record<string, unknown>) {
  const outcome = await executeTool(ctxFor(db), tool, args);
  if (!outcome.ok) throw new Error(`tool failed: ${outcome.error}`);
  return { data: outcome.data as Record<string, unknown>, pendingAction: outcome.pendingAction };
}

// ---------------------------------------------------------------------------
// Bill-payment wording
// ---------------------------------------------------------------------------

Deno.test("wording: card bills, CRED and card bills via payment apps read as bill payments", () => {
  for (
    const textOf of [
      "HDFC credit card payment",
      "Paid my credit card bill",
      "CC bill",
      "card bill for October",
      "Rs.5000 debited towards HDFC Credit Card XX1234",
      "CRED payment",
      "paid card dues on CRED",
      "BillDesk credit card",
      "Amazon Pay credit card bill",
      "BBPS HDFC card",
      "PhonePe credit card payment",
    ]
  ) {
    assert(looksLikeCardBillPayment(textOf), textOf);
  }
});

Deno.test("wording: purchases, other bills and cashback are not bill payments", () => {
  for (
    const textOf of [
      "Lunch at Truffles",
      "Electricity bill",
      "BillDesk insurance premium",
      "BBPS electricity",
      "Rent paid via CRED",
      "Credit card cashback",
      "Spent on HDFC Bank Credit Card XX1234 at AMAZON",
      "",
    ]
  ) {
    assert(!looksLikeCardBillPayment(textOf), textOf);
  }
});

// ---------------------------------------------------------------------------
// Spending: the same exclusions as the apps
// ---------------------------------------------------------------------------

/** September plus a paid-for purchase (e5), an instalment of a friend's EMI (e6) and a converted purchase (e7). */
function seededWithExclusions(): FakeDb {
  const db = new FakeDb().seedSeptember();
  db.expenses.push(
    { owner: USER_A, id: "e5", amount: 999, expense_date: "2026-09-18", category_id: null, payment_method_id: null, bank_account_id: null, description: "Bought for Arun", merchant: null },
    { owner: USER_A, id: "e6", amount: 2000, expense_date: "2026-09-20", category_id: null, payment_method_id: null, bank_account_id: null, description: "Arun's phone EMI", merchant: null },
    { owner: USER_A, id: "e7", amount: 60000, expense_date: "2026-09-21", category_id: null, payment_method_id: null, bank_account_id: null, description: "Laptop (converted to EMI)", merchant: null },
  );
  db.excludedExpenseIds.set(USER_A, ["e5", "e6", "e7"]);
  return db;
}

Deno.test("spending: totals leave out paid-for, someone else's EMI and converted purchases", async () => {
  const db = seededWithExclusions();
  const { data } = await run(db, "get_monthly_expenses", { month: "2026-09" });
  // e1 450 + e2 1200 + e3 2350: exactly what the app's dashboard counts.
  assertEquals(data.total_expenses, 4000);
  assertEquals(data.transaction_count, 3);
});

Deno.test("spending: categories, summaries, recent rows and tags use the same rule", async () => {
  const db = seedTags(seededWithExclusions());
  db.tagLinkRows.push({ owner: USER_A, kind: "expense", tag_id: "t1", row_id: "e7" });

  const categories = await run(db, "get_category_spending", { month: "2026-09" });
  assertEquals(categories.data.total, 4000);
  const summary = await run(db, "get_expense_summary", { month: "2026-09" });
  assertEquals(summary.data.total, 4000);
  assertEquals((summary.data.largest_expense as { amount: number }).amount, 2350);

  const recent = await run(db, "get_recent_transactions", { type: "expenses", limit: 10 });
  const listed = JSON.stringify(recent.data);
  assert(!listed.includes("Laptop (converted to EMI)"));
  assert(!listed.includes("Bought for Arun"));

  const tagged = await run(db, "get_tag_spending", { tag: "myownspendings", month: "2026-09" });
  assert(!JSON.stringify(tagged.data).includes("60000"), "a converted purchase never counts under a tag either");
});

Deno.test("spending: the excluded list is read once per request and only for the caller", async () => {
  const db = seededWithExclusions();
  const ctx = ctxFor(db);
  await executeTool(ctx, "get_monthly_expenses", { month: "2026-09" });
  await executeTool(ctx, "get_category_spending", { month: "2026-09" });
  const reads = db.calls.filter((c) => c.method === "spendingExcludedExpenseIds");
  assertEquals(reads.length, 1);
  assert(reads.every((c) => c.userId === USER_A));
});

Deno.test("spending: the chat handler applies the same exclusions", async () => {
  const db = seededWithExclusions();
  const provider = new FakeProvider("gemini", [call("get_monthly_expenses", { month: "2026-09" }), text("done")]);
  const deps: HandlerDeps = {
    openSession: () => Promise.resolve({ userId: USER_A, db }),
    providers: () => [provider],
    rateLimiter: new RateLimiter(100, 60_000),
    now: () => new Date("2026-09-22T10:00:00Z"),
    log: () => {},
  };
  const response = await createHandler(deps)(
    new Request("https://functions.example/ai-chat", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: "Bearer token-0123456789" },
      body: JSON.stringify({ action: "chat", message: "spend?", client_context: { today: "2026-09-22" } }),
    }),
  );
  assertEquals(response.status, 200);
  const toolResult = provider.requests[1].messages.at(-1);
  assert(toolResult && toolResult.role === "tool");
  assertEquals(JSON.parse(toolResult.content).total_expenses, 4000);
});

// ---------------------------------------------------------------------------
// A bill is never an expense
// ---------------------------------------------------------------------------

Deno.test("expense: a card bill is refused and pointed at the bill payment", async () => {
  const db = new FakeDb().seedSeptember();
  for (
    const args of [
      { amount: 25000, category: "Bills", description: "HDFC credit card bill" },
      { amount: 25000, category: "Bills", merchant: "CRED", description: "card payment" },
    ]
  ) {
    const outcome = await executeTool(ctxFor(db), "create_expense", args);
    assert(!outcome.ok);
    assertStringIncludes(outcome.error, "record_card_bill_payment");
  }
  db.categories.push({ owner: USER_A, id: "11111111-0000-4000-8000-000000000009", name: "Credit Card Bill" });
  const byCategory = await executeTool(ctxFor(db), "create_expense", { amount: 25000, category: "Credit Card Bill" });
  assert(!byCategory.ok);
  assertEquals(db.inserted.expenses.length, 0);
});

Deno.test("expense: a purchase on a card is an expense on the card with no bank movement", async () => {
  const db = new FakeDb().seedSeptember();
  const prepared = await run(db, "create_expense", { amount: 1500, category: "Shopping", card: "Regalia", date: "2026-11-05" });
  assert(prepared.pendingAction);
  assertEquals(prepared.pendingAction.args.card_id, CARD_HDFC);
  assertEquals(prepared.pendingAction.summary, "Add ₹1,500 expense under Shopping on Regalia •••• 1234 on 5 Nov 2026?");
  assertEquals(db.inserted.expenses.length, 0);

  const ledgerBefore = db.ledger.length;
  const result = await executeWrite(ctxFor(db), "create_expense", prepared.pendingAction.args);
  assert(result.ok);
  assertEquals(db.inserted.expenses.length, 1);
  assertEquals(db.inserted.expenses[0].credit_card_id, CARD_HDFC);
  assertEquals(db.inserted.expenses[0].bank_account_id, null);
  assertEquals(db.ledger.length, ledgerBefore, "a card purchase never touches a bank balance");
});

Deno.test("expense: an account and a card together are refused; another user's card is unknown", async () => {
  const db = new FakeDb().seedSeptember();
  const both = await executeTool(ctxFor(db), "create_expense", { amount: 100, category: "Food", account: "Savings", card: "Regalia" });
  assert(!both.ok);
  const other = await executeTool(ctxFor(db), "create_expense", { amount: 100, category: "Food", card: "B card" });
  assert(!other.ok);
  // A card id from another user, smuggled into a confirm, is caught too.
  const smuggled = await executeWrite(ctxFor(db), "create_expense", {
    amount: 100,
    date: "2026-11-05",
    category_id: "11111111-0000-4000-8000-000000000001",
    category_name: "Food",
    card_id: CARD_B,
  });
  assert(!smuggled.ok);
  assertEquals(db.inserted.expenses.length, 0);
});

// ---------------------------------------------------------------------------
// record_card_bill_payment
// ---------------------------------------------------------------------------

/** A bill payment recorded on the card alone (cash / not tracked): ids are UUIDs, as in the database. */
const CARD_SIDE_PAYMENT = "55555555-0000-4000-8000-000000000001";

/** A December payment of November's bill: the bank account has enough for it. */
function withMoney(): FakeDb {
  const db = new FakeDb().seedSeptember();
  db.accounts[0].opening_balance = 100_000;
  return db;
}

Deno.test("bill: prepares one bank payment, never an expense", async () => {
  const db = withMoney();
  const prepared = await run(db, "record_card_bill_payment", { card: "1234", account: "Salary", amount: 18500, date: "2026-12-05" });
  assert(prepared.pendingAction);
  assertEquals(prepared.pendingAction.tool, "record_card_bill_payment");
  assertEquals(prepared.pendingAction.summary, "Record ₹18,500 bill payment for Regalia •••• 1234 from Salary Account on 5 Dec 2026?");
  assertEquals(db.recordedCardPayments.length, 0, "chat only prepares");

  const result = await executeWrite(ctxFor(db), "record_card_bill_payment", prepared.pendingAction.args);
  assert(result.ok);
  assertStringIncludes(result.reply, "not counted as spending");
  assertEquals(db.recordedCardPayments.length, 1);
  assertEquals(db.recordedCardPayments[0].account_id, ACC_HDFC);
  assertEquals(db.recordedCardPayments[0].card_id, CARD_HDFC);
  assertEquals(db.recordedCardPayments[0].replaces, null);
  assertEquals(db.inserted.expenses.length, 0);

  // The month's spending is unchanged by it.
  const spend = await run(db, "get_monthly_expenses", { month: "2026-12" });
  assertEquals(spend.data.total_expenses, 0);
});

Deno.test("bill: a partial payment is fine; more than the account holds is refused", async () => {
  const db = withMoney();
  const partial = await run(db, "record_card_bill_payment", { card: "Regalia", account: "Salary", amount: 5000, date: "2026-12-05" });
  assert(partial.pendingAction);
  const tooMuch = await executeTool(ctxFor(db), "record_card_bill_payment", { card: "Regalia", account: "Savings", amount: 9000 });
  assert(!tooMuch.ok);
  assertStringIncludes(tooMuch.error, "only has");
});

Deno.test("bill: an already-recorded bank payment asks first, and 'same' adds nothing", async () => {
  const db = withMoney();
  db.cardPayments.push({ owner: USER_A, id: "bp1", card_id: CARD_HDFC, source: "bank", account_id: ACC_HDFC, amount: 18500, txn_date: "2026-12-03" });

  const first = await run(db, "record_card_bill_payment", { card: "Regalia", account: "Salary", amount: 18500, date: "2026-12-05" });
  assertEquals(first.data.status, "possible_duplicate");
  assertEquals(first.pendingAction, undefined);
  assertStringIncludes(JSON.stringify(first.data), "paid from Salary Account");

  const same = await run(db, "record_card_bill_payment", {
    card: "Regalia",
    account: "Salary",
    amount: 18500,
    date: "2026-12-05",
    existing_payment: "same_payment",
  });
  assertEquals(same.data.status, "already_recorded");
  assertEquals(same.pendingAction, undefined);
  assertEquals(db.recordedCardPayments.length, 0);

  const separate = await run(db, "record_card_bill_payment", {
    card: "Regalia",
    account: "Salary",
    amount: 18500,
    date: "2026-12-05",
    existing_payment: "separate_payment",
  });
  assert(separate.pendingAction);
  const written = await executeWrite(ctxFor(db), "record_card_bill_payment", separate.pendingAction.args);
  assert(written.ok);
  assertEquals(db.recordedCardPayments.length, 1);
});

Deno.test("bill: the same payment recorded on the card alone is replaced, in one write", async () => {
  const db = withMoney();
  db.cardPayments.push({ owner: USER_A, id: CARD_SIDE_PAYMENT, card_id: CARD_HDFC, source: "card", account_id: null, amount: 18500, txn_date: "2026-12-01" });

  const first = await run(db, "record_card_bill_payment", { card: "Regalia", account: "Salary", amount: 18500, date: "2026-12-05" });
  assertEquals(first.data.status, "possible_duplicate");
  assertStringIncludes(JSON.stringify(first.data), "recorded on the card only");

  const same = await run(db, "record_card_bill_payment", {
    card: "Regalia",
    account: "Salary",
    amount: 18500,
    date: "2026-12-05",
    existing_payment: "same_payment",
  });
  assert(same.pendingAction);
  assertEquals(same.pendingAction.args.replaces_id, CARD_SIDE_PAYMENT);
  assertStringIncludes(same.pendingAction.summary, "in place of the card-only record from 1 Dec 2026");

  const written = await executeWrite(ctxFor(db), "record_card_bill_payment", same.pendingAction.args);
  assert(written.ok);
  assertEquals(db.recordedCardPayments[0].replaces, CARD_SIDE_PAYMENT);
  // The card now has exactly one payment for that bill.
  const left = db.cardPayments.filter((p) => p.card_id === CARD_HDFC && p.amount === 18500);
  assertEquals(left.length, 1);
  assertEquals(left[0].source, "bank");
});

Deno.test("bill: other amounts, other cards and payments outside 10 days are not duplicates", async () => {
  const db = withMoney();
  db.cardPayments.push(
    { owner: USER_A, id: "x1", card_id: CARD_HDFC, source: "bank", account_id: ACC_HDFC, amount: 18000, txn_date: "2026-12-04" },
    { owner: USER_A, id: "x2", card_id: CARD_AXIS, source: "card", account_id: null, amount: 18500, txn_date: "2026-12-04" },
    { owner: USER_A, id: "x3", card_id: CARD_HDFC, source: "card", account_id: null, amount: 18500, txn_date: "2026-11-20" },
  );
  const prepared = await run(db, "record_card_bill_payment", { card: "Regalia", account: "Salary", amount: 18500, date: "2026-12-05" });
  assert(prepared.pendingAction, "nothing close enough to be the same payment");
});

Deno.test("bill: a payment recorded meanwhile stops the confirm from writing it twice", async () => {
  const db = withMoney();
  const prepared = await run(db, "record_card_bill_payment", { card: "Regalia", account: "Salary", amount: 18500, date: "2026-12-05" });
  assert(prepared.pendingAction);
  // The bank statement import records the same debit before the user taps Confirm.
  db.cardPayments.push({ owner: USER_A, id: "bp9", card_id: CARD_HDFC, source: "bank", account_id: ACC_HDFC, amount: 18500, txn_date: "2026-12-05" });
  const result = await executeWrite(ctxFor(db), "record_card_bill_payment", prepared.pendingAction.args);
  assert(!result.ok);
  assertStringIncludes(result.error, "already recorded");
  assertEquals(db.recordedCardPayments.length, 0);
});

Deno.test("bill: another user's card or account can never be paid", async () => {
  const db = withMoney();
  const outcome = await executeTool(ctxFor(db), "record_card_bill_payment", { card: "B card", account: "Salary", amount: 100 });
  assert(!outcome.ok);
  const confirm = await executeWrite(ctxFor(db), "record_card_bill_payment", {
    amount: 100,
    date: "2026-12-05",
    card_id: CARD_B,
    account_id: ACC_HDFC,
  });
  assert(!confirm.ok);
  const asB = await executeWrite(ctxFor(db, USER_B), "record_card_bill_payment", {
    amount: 100,
    date: "2026-12-05",
    card_id: CARD_HDFC,
    account_id: ACC_SBI,
  });
  assert(!asB.ok);
  assertEquals(db.recordedCardPayments.length, 0);
});

Deno.test("bill: without credit cards set up it says so", async () => {
  const db = withMoney();
  db.caps = { ...db.caps, creditCards: false };
  const outcome = await executeTool(ctxFor(db), "record_card_bill_payment", { card: "Regalia", account: "Salary", amount: 100 });
  assert(!outcome.ok);
  assertStringIncludes(outcome.error, "not set up");
});
