import { LIMITS } from "../core/limits.ts";
import type { JsonSchema } from "../core/messages.ts";
import type { AccountRow, NewLedgerRow } from "../db/port.ts";
import {
  accountBalances,
  accountLabel,
  checkWriteDate,
  fail,
  findAccount,
  findCategory,
  findPaymentMethod,
  money,
  type PendingAction,
  type ToolContext,
  type ToolDefinition,
  type ToolOutcome,
} from "./common.ts";
import { cents, checkAmount, MAX_AMOUNT } from "./money.ts";
import { DATE_PATTERN, dateLabel, isValidDate } from "./period.ts";
import { validateArgs } from "./schema.ts";

/**
 * Write tools.
 *
 * During a chat turn a write tool only *prepares*: it resolves names to the
 * user's own rows, validates every rule, and returns a PendingAction plus a
 * confirmation question. Nothing is written. The action is executed only when
 * the client sends it back under `action: "confirm"`, and even then every
 * argument is verified again against the database as it is at that moment —
 * a category deleted in between, or a balance that has since dropped, is
 * caught here and not by hope.
 *
 * The ledger rules are a faithful copy of the Flutter repositories
 * (`ExpenseRepository._syncLedger`, `IncomeRepository._syncLedger`,
 * `LedgerRepository.transfer`) so a row written from chat is
 * indistinguishable from one written on a form.
 */

const DATE_ARG: JsonSchema = {
  type: "string",
  description: "Date YYYY-MM-DD. Defaults to today. Work out relative dates like " +
    "'yesterday' from today's date before calling.",
  pattern: DATE_PATTERN,
  maxLength: 10,
};

const UUID = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$";

function pending(
  tool: PendingAction["tool"],
  args: Record<string, unknown>,
  summary: string,
  now: number = Date.now(),
): ToolOutcome {
  const action: PendingAction = {
    id: crypto.randomUUID(),
    tool,
    args,
    summary,
    expires_at: new Date(now + LIMITS.pendingActionTtlMs).toISOString(),
  };
  return {
    ok: true,
    pendingAction: action,
    data: {
      status: "ready_to_confirm",
      summary,
      instruction: "Nothing has been saved. Reply to the user with this exact question " +
        "and nothing else; the app shows Confirm and Cancel buttons.",
    },
  };
}

function needsInput(missing: string, options: string[]): ToolOutcome {
  return {
    ok: true,
    data: {
      status: "needs_input",
      missing,
      options,
      instruction: `Ask the user for the ${missing} before trying again. Do not guess.`,
    },
  };
}

/** Optional text field: trimmed, or null when empty. */
function text(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length === 0 ? null : trimmed;
}

// ---------------------------------------------------------------------------
// create_expense
// ---------------------------------------------------------------------------

const CREATE_EXPENSE_CONFIRM: JsonSchema = {
  type: "object",
  properties: {
    amount: { type: "number", minimum: 0.01, maximum: MAX_AMOUNT },
    date: { type: "string", pattern: DATE_PATTERN, maxLength: 10 },
    category_id: { type: "string", pattern: UUID, maxLength: 36 },
    category_name: { type: "string", maxLength: 80 },
    payment_method_id: { type: "string", pattern: UUID, maxLength: 36 },
    payment_method_name: { type: "string", maxLength: 80 },
    account_id: { type: "string", pattern: UUID, maxLength: 36 },
    account_name: { type: "string", maxLength: 80 },
    description: { type: "string", maxLength: 200 },
    merchant: { type: "string", maxLength: 120 },
  },
  required: ["amount", "date", "category_id", "category_name"],
};

export const createExpense: ToolDefinition & { confirmSchema: JsonSchema } = {
  name: "create_expense",
  kind: "write",
  confirmSchema: CREATE_EXPENSE_CONFIRM,
  description: "Prepare a new expense for the user to confirm. Requires an amount and a " +
    "category; if the user did not say what the money was for, ask instead of guessing. " +
    "Never tell the user it has been added — the tool only prepares it.",
  parameters: {
    type: "object",
    properties: {
      amount: { type: "number", description: "Amount spent, positive.", minimum: 0.01, maximum: MAX_AMOUNT },
      category: { type: "string", description: "One of the user's category names.", maxLength: 80 },
      description: { type: "string", description: "Short note, optional.", maxLength: 200 },
      merchant: { type: "string", description: "Shop or payee, optional.", maxLength: 120 },
      payment_method: {
        type: "string",
        description: "One of the user's payment method names, optional.",
        maxLength: 80,
      },
      account: {
        type: "string",
        description: "Bank account the money left, by nickname/bank. Omit for cash.",
        maxLength: 60,
      },
      date: DATE_ARG,
    },
    required: ["amount"],
  },
  async run(ctx, args) {
    const amount = checkAmount(args.amount);
    if (!amount.ok) return fail(amount.error);
    const date = checkWriteDate(args.date, ctx.today);
    if (!date.ok) return fail(date.error);

    const [categories, methods, caps] = await Promise.all([
      ctx.db.listCategories(ctx.userId),
      ctx.db.listPaymentMethods(ctx.userId),
      ctx.db.capabilities(),
    ]);

    const categoryQuery = text(args.category);
    if (!categoryQuery) return needsInput("category", categories.map((c) => c.name));
    const category = findCategory(categories, categoryQuery);
    if (!category.ok) return fail(category.error);

    const normalised: Record<string, unknown> = {
      amount: amount.value,
      date: date.value,
      category_id: category.row.id,
      category_name: category.row.name,
    };

    const methodQuery = text(args.payment_method);
    if (methodQuery) {
      const method = findPaymentMethod(methods, methodQuery);
      if (!method.ok) return fail(method.error);
      normalised.payment_method_id = method.row.id;
      normalised.payment_method_name = method.row.name;
    }

    let accountRow: AccountRow | null = null;
    const accountQuery = text(args.account);
    if (accountQuery) {
      if (!caps.bankAccounts || !caps.expenseBankLink) {
        return fail("Bank accounts are not enabled in this app yet; record it as cash instead.");
      }
      const accounts = await ctx.db.listAccounts(ctx.userId);
      const account = findAccount(accounts, accountQuery);
      if (!account.ok) return fail(account.error);
      accountRow = account.row;
      normalised.account_id = accountRow.id;
      normalised.account_name = accountLabel(accountRow);
    }

    const description = text(args.description);
    const merchant = text(args.merchant);
    if (description) normalised.description = description;
    if (merchant) normalised.merchant = merchant;

    const summary = `Add ${money(ctx, amount.value)} expense under ${category.row.name}` +
      (accountRow ? ` from ${accountRow.nickname}` : "") +
      (date.value === ctx.today ? "" : ` on ${dateLabel(date.value)}`) + "?";

    return pending("create_expense", normalised, summary);
  },
};

async function executeCreateExpense(
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<{ ok: true; reply: string } | { ok: false; error: string }> {
  const amount = checkAmount(args.amount);
  if (!amount.ok) return { ok: false, error: amount.error };
  const date = String(args.date);
  if (!isValidDate(date)) return { ok: false, error: "That date is not valid." };

  const [categories, methods, caps] = await Promise.all([
    ctx.db.listCategories(ctx.userId),
    ctx.db.listPaymentMethods(ctx.userId),
    ctx.db.capabilities(),
  ]);

  // Every id is checked against the user's *own* rows as they are now. An
  // id from another user cannot appear in these lists, and a row deleted
  // since the proposal is caught here.
  const category = categories.find((c) => c.id === args.category_id);
  if (!category) return { ok: false, error: "That category no longer exists. Please try again." };

  let paymentMethodId: string | null = null;
  if (typeof args.payment_method_id === "string") {
    const method = methods.find((m) => m.id === args.payment_method_id);
    if (!method) return { ok: false, error: "That payment method no longer exists." };
    paymentMethodId = method.id;
  }

  let account: AccountRow | null = null;
  if (typeof args.account_id === "string") {
    if (!caps.bankAccounts || !caps.expenseBankLink) {
      return { ok: false, error: "Bank accounts are not enabled in this app yet." };
    }
    const accounts = await ctx.db.listAccounts(ctx.userId);
    account = accounts.find((a) => a.id === args.account_id) ?? null;
    if (!account) return { ok: false, error: "That bank account no longer exists." };
  }

  const merchant = text(args.merchant);
  const description = text(args.description);

  const created = await ctx.db.insertExpense(ctx.userId, {
    amount: amount.value,
    expense_date: date,
    category_id: category.id,
    payment_method_id: paymentMethodId,
    bank_account_id: account?.id ?? null,
    merchant,
    description,
  });

  // Mirror of ExpenseRepository._syncLedger: a bank-funded expense debits the
  // account; a cash expense leaves no movement at all.
  if (account && caps.bankAccounts && caps.expenseBankLink) {
    await ctx.db.insertLedgerRows(ctx.userId, [{
      account_id: account.id,
      direction: "debit",
      amount: amount.value,
      txn_date: date,
      description: merchant ?? description ?? category.name,
      category_id: category.id,
      expense_id: created.id,
    }]);
  }

  return {
    ok: true,
    reply: `Done. ${money(ctx, amount.value)} was added to ${category.name}` +
      (account ? ` from ${account.nickname}` : "") + ".",
  };
}

// ---------------------------------------------------------------------------
// create_income
// ---------------------------------------------------------------------------

const CREATE_INCOME_CONFIRM: JsonSchema = {
  type: "object",
  properties: {
    amount: { type: "number", minimum: 0.01, maximum: MAX_AMOUNT },
    date: { type: "string", pattern: DATE_PATTERN, maxLength: 10 },
    source: { type: "string", maxLength: 120 },
    description: { type: "string", maxLength: 200 },
    account_id: { type: "string", pattern: UUID, maxLength: 36 },
    account_name: { type: "string", maxLength: 80 },
  },
  required: ["amount", "date", "source"],
};

export const createIncome: ToolDefinition & { confirmSchema: JsonSchema } = {
  name: "create_income",
  kind: "write",
  confirmSchema: CREATE_INCOME_CONFIRM,
  description: "Prepare a new income entry for the user to confirm. Requires an amount and " +
    "a source such as 'Salary'; ask if the source was not given. Never say it has been " +
    "recorded — the tool only prepares it.",
  parameters: {
    type: "object",
    properties: {
      amount: { type: "number", description: "Amount received, positive.", minimum: 0.01, maximum: MAX_AMOUNT },
      source: { type: "string", description: "Where it came from, e.g. Salary, Freelance.", maxLength: 120 },
      description: { type: "string", description: "Short note, optional.", maxLength: 200 },
      account: {
        type: "string",
        description: "Bank account it was paid into, by nickname/bank. Optional.",
        maxLength: 60,
      },
      date: DATE_ARG,
    },
    required: ["amount"],
  },
  async run(ctx, args) {
    const amount = checkAmount(args.amount);
    if (!amount.ok) return fail(amount.error);
    const date = checkWriteDate(args.date, ctx.today);
    if (!date.ok) return fail(date.error);

    const source = text(args.source);
    if (!source) return needsInput("income source", []);

    const normalised: Record<string, unknown> = {
      amount: amount.value,
      date: date.value,
      source,
    };
    const description = text(args.description);
    if (description) normalised.description = description;

    let accountRow: AccountRow | null = null;
    const accountQuery = text(args.account);
    if (accountQuery) {
      const caps = await ctx.db.capabilities();
      if (!caps.bankAccounts || !caps.incomeBankLink) {
        return fail("Bank accounts are not enabled in this app yet; record it without an account.");
      }
      const accounts = await ctx.db.listAccounts(ctx.userId);
      const account = findAccount(accounts, accountQuery);
      if (!account.ok) return fail(account.error);
      accountRow = account.row;
      normalised.account_id = accountRow.id;
      normalised.account_name = accountLabel(accountRow);
    }

    const summary = `Add ${money(ctx, amount.value)} income from ${source}` +
      (accountRow ? ` into ${accountRow.nickname}` : "") +
      (date.value === ctx.today ? "" : ` on ${dateLabel(date.value)}`) + "?";

    return pending("create_income", normalised, summary);
  },
};

async function executeCreateIncome(
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<{ ok: true; reply: string } | { ok: false; error: string }> {
  const amount = checkAmount(args.amount);
  if (!amount.ok) return { ok: false, error: amount.error };
  const date = String(args.date);
  if (!isValidDate(date)) return { ok: false, error: "That date is not valid." };
  const source = text(args.source);
  if (!source) return { ok: false, error: "The income needs a source." };

  const caps = await ctx.db.capabilities();
  let account: AccountRow | null = null;
  if (typeof args.account_id === "string") {
    if (!caps.bankAccounts || !caps.incomeBankLink) {
      return { ok: false, error: "Bank accounts are not enabled in this app yet." };
    }
    const accounts = await ctx.db.listAccounts(ctx.userId);
    account = accounts.find((a) => a.id === args.account_id) ?? null;
    if (!account) return { ok: false, error: "That bank account no longer exists." };
  }

  const description = text(args.description);
  const created = await ctx.db.insertIncome(ctx.userId, {
    amount: amount.value,
    income_date: date,
    source,
    description,
    bank_account_id: account?.id ?? null,
  });

  // Mirror of IncomeRepository._syncLedger.
  if (account && caps.bankAccounts && caps.incomeBankLink) {
    await ctx.db.insertLedgerRows(ctx.userId, [{
      account_id: account.id,
      direction: "credit",
      amount: amount.value,
      txn_date: date,
      description: source,
      income_id: created.id,
    }]);
  }

  return {
    ok: true,
    reply: `Done. ${money(ctx, amount.value)} income from ${source} was recorded` +
      (account ? ` into ${account.nickname}` : "") + ".",
  };
}

// ---------------------------------------------------------------------------
// transfer_money
// ---------------------------------------------------------------------------

const TRANSFER_CONFIRM: JsonSchema = {
  type: "object",
  properties: {
    amount: { type: "number", minimum: 0.01, maximum: MAX_AMOUNT },
    date: { type: "string", pattern: DATE_PATTERN, maxLength: 10 },
    from_account_id: { type: "string", pattern: UUID, maxLength: 36 },
    from_account_name: { type: "string", maxLength: 80 },
    to_account_id: { type: "string", pattern: UUID, maxLength: 36 },
    to_account_name: { type: "string", maxLength: 80 },
    note: { type: "string", maxLength: 200 },
  },
  required: ["amount", "date", "from_account_id", "to_account_id"],
};

/** Same rules as TransferValidation in the app, in the same order. */
export function checkTransfer(
  fromId: string | null,
  toId: string | null,
  amount: number,
  available: number | null,
): string | null {
  if (!fromId) return "Choose the account to transfer from.";
  if (!toId) return "Choose the account to transfer to.";
  if (fromId === toId) {
    return "Pick two different accounts. Money cannot move to the account it came from.";
  }
  if (!Number.isFinite(amount) || amount <= 0) return "Enter an amount greater than 0.";
  if (amount > MAX_AMOUNT) return "That amount is too large.";
  if (available !== null && Number.isFinite(available) && cents(amount) > cents(available)) {
    return "insufficient";
  }
  return null;
}

export const transferMoney: ToolDefinition & { confirmSchema: JsonSchema } = {
  name: "transfer_money",
  kind: "write",
  confirmSchema: TRANSFER_CONFIRM,
  description: "Prepare a transfer between two of the user's own bank accounts for them " +
    "to confirm. A transfer is not income or an expense. Never say it has been done — the " +
    "tool only prepares it.",
  parameters: {
    type: "object",
    properties: {
      amount: { type: "number", description: "Amount to move, positive.", minimum: 0.01, maximum: MAX_AMOUNT },
      from_account: { type: "string", description: "Sending account by nickname/bank.", maxLength: 60 },
      to_account: { type: "string", description: "Receiving account by nickname/bank.", maxLength: 60 },
      note: { type: "string", description: "Optional remark.", maxLength: 200 },
      date: DATE_ARG,
    },
    required: ["amount", "from_account", "to_account"],
  },
  async run(ctx, args) {
    const caps = await ctx.db.capabilities();
    if (!caps.bankAccounts || !caps.transfers) {
      return fail("Transfers between accounts are not enabled in this app yet.");
    }
    const amount = checkAmount(args.amount);
    if (!amount.ok) return fail(amount.error);
    const date = checkWriteDate(args.date, ctx.today);
    if (!date.ok) return fail(date.error);

    const balances = await accountBalances(ctx);
    const accounts = balances.map((b) => b.account);
    if (accounts.length < 2) return fail("The user needs at least two bank accounts to transfer.");

    const from = findAccount(accounts, String(args.from_account));
    if (!from.ok) return fail(`Sending account: ${from.error}`);
    const to = findAccount(accounts, String(args.to_account));
    if (!to.ok) return fail(`Receiving account: ${to.error}`);

    const available = balances.find((b) => b.account.id === from.row.id)?.balance ?? 0;
    const problem = checkTransfer(from.row.id, to.row.id, amount.value, available);
    if (problem === "insufficient") {
      return fail(`${from.row.nickname} only has ${money(ctx, available)} available.`);
    }
    if (problem) return fail(problem);

    const normalised: Record<string, unknown> = {
      amount: amount.value,
      date: date.value,
      from_account_id: from.row.id,
      from_account_name: from.row.nickname,
      to_account_id: to.row.id,
      to_account_name: to.row.nickname,
    };
    const note = text(args.note);
    if (note) normalised.note = note;

    const summary = `Transfer ${money(ctx, amount.value)} from ${from.row.nickname} to ` +
      `${to.row.nickname}` + (date.value === ctx.today ? "" : ` on ${dateLabel(date.value)}`) + "?";

    return pending("transfer_money", normalised, summary);
  },
};

async function executeTransfer(
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<{ ok: true; reply: string } | { ok: false; error: string }> {
  const caps = await ctx.db.capabilities();
  if (!caps.bankAccounts || !caps.transfers) {
    return { ok: false, error: "Transfers between accounts are not enabled in this app yet." };
  }
  const amount = checkAmount(args.amount);
  if (!amount.ok) return { ok: false, error: amount.error };
  const date = String(args.date);
  if (!isValidDate(date)) return { ok: false, error: "That date is not valid." };

  const accounts = await ctx.db.listAccounts(ctx.userId);
  const from = accounts.find((a) => a.id === args.from_account_id);
  const to = accounts.find((a) => a.id === args.to_account_id);
  if (!from) return { ok: false, error: "The sending account no longer exists." };
  if (!to) return { ok: false, error: "The receiving account no longer exists." };

  // Balance re-derived from the ledger at the moment of writing, exactly as
  // BankAccountProvider.transfer does, so a spend recorded since the
  // proposal cannot let this overdraw.
  const net = await ctx.db.ledgerNet(ctx.userId, from.id, null);
  const available = from.opening_balance + net;
  const problem = checkTransfer(from.id, to.id, amount.value, available);
  if (problem === "insufficient") {
    return { ok: false, error: `${from.nickname} only has ${money(ctx, available)} available.` };
  }
  if (problem) return { ok: false, error: problem };

  const note = text(args.note);
  const groupId = crypto.randomUUID();
  const legs: NewLedgerRow[] = [
    {
      account_id: from.id,
      direction: "debit",
      amount: amount.value,
      txn_date: date,
      description: note ?? `Transfer to ${to.nickname}`,
      transfer_group_id: groupId,
      counterparty_account_id: to.id,
    },
    {
      account_id: to.id,
      direction: "credit",
      amount: amount.value,
      txn_date: date,
      description: note ?? `Transfer from ${from.nickname}`,
      transfer_group_id: groupId,
      counterparty_account_id: from.id,
    },
  ];
  // Single insert: both legs commit together or neither does.
  await ctx.db.insertLedgerRows(ctx.userId, legs);

  return {
    ok: true,
    reply: `Done. ${money(ctx, amount.value)} moved from ${from.nickname} to ${to.nickname}.`,
  };
}

// ---------------------------------------------------------------------------

export const WRITE_TOOLS: readonly (ToolDefinition & { confirmSchema: JsonSchema })[] = [
  createExpense,
  createIncome,
  transferMoney,
];

export type ExecuteResult = { ok: true; reply: string } | { ok: false; error: string };

/**
 * Runs a confirmed write. The only path that writes anything.
 *
 * `rawArgs` comes from the client and is treated as untrusted: it is checked
 * against the tool's strict confirm schema (unknown keys rejected, ids must
 * be UUIDs) before any lookup, and every id is then re-verified against the
 * user's own rows inside the executor.
 */
export async function executeWrite(
  ctx: ToolContext,
  toolName: string,
  rawArgs: unknown,
): Promise<ExecuteResult> {
  const tool = WRITE_TOOLS.find((t) => t.name === toolName);
  if (!tool) return { ok: false, error: "That action is not available." };

  const validated = validateArgs(tool.confirmSchema, rawArgs);
  if (!validated.ok) return { ok: false, error: "That action is no longer valid. Please ask again." };

  switch (tool.name) {
    case "create_expense":
      return executeCreateExpense(ctx, validated.value);
    case "create_income":
      return executeCreateIncome(ctx, validated.value);
    case "transfer_money":
      return executeTransfer(ctx, validated.value);
    default:
      return { ok: false, error: "That action is not available." };
  }
}
