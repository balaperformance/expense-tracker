import { LIMITS } from "../core/limits.ts";
import type { JsonSchema } from "../core/messages.ts";
import type { AccountRow, CategoryRow, DbPort, PaymentMethodRow } from "../db/port.ts";
import { formatMoney } from "./money.ts";
import {
  addDays,
  compareDates,
  DATE_PATTERN,
  dateLabel,
  dayRange,
  isValidDate,
  isValidMonth,
  MONTH_PATTERN,
  monthLabel,
  monthOf,
  monthRange,
} from "./period.ts";
import { type Named, resolveByName, type Resolution } from "./resolve.ts";

/** What every tool receives. Identity is fixed before any tool runs. */
export type ToolContext = {
  /** From the verified JWT. Tools cannot change it. */
  readonly userId: string;
  readonly db: DbPort;
  /** `YYYY-MM-DD` in the user's calendar. */
  readonly today: string;
  readonly currency: string;
};

/** A write the model proposed, validated, and waiting for the user. */
export type PendingAction = {
  id: string;
  tool: "create_expense" | "create_income" | "transfer_money";
  /** Normalised arguments with resolved ids. Re-verified at execution. */
  args: Record<string, unknown>;
  /** The question shown on the confirmation card. */
  summary: string;
  expires_at: string;
};

export type ToolOutcome =
  | { ok: true; data: unknown; pendingAction?: PendingAction }
  | { ok: false; error: string };

export type ToolKind = "read" | "write";

export interface ToolDefinition {
  readonly name: string;
  readonly kind: ToolKind;
  readonly description: string;
  readonly parameters: JsonSchema;
  /** For a read tool, answers. For a write tool, prepares and never writes. */
  run(ctx: ToolContext, args: Record<string, unknown>): Promise<ToolOutcome>;
}

export function fail(error: string): ToolOutcome {
  return { ok: false, error };
}

export function ok(data: unknown): ToolOutcome {
  return { ok: true, data };
}

// ---------------------------------------------------------------------------
// Periods
// ---------------------------------------------------------------------------

export const PERIOD_PROPERTIES: Record<string, JsonSchema> = {
  month: {
    type: "string",
    description: "Calendar month as YYYY-MM. Defaults to the current month.",
    pattern: MONTH_PATTERN,
    maxLength: 7,
  },
  from: {
    type: "string",
    description: "Start date YYYY-MM-DD (inclusive). Use with `to` instead of `month`.",
    pattern: DATE_PATTERN,
    maxLength: 10,
  },
  to: {
    type: "string",
    description: "End date YYYY-MM-DD (inclusive). Use with `from`.",
    pattern: DATE_PATTERN,
    maxLength: 10,
  },
};

export type Period = { from: string; toExclusive: string; label: string; month: string | null };

/** Longest custom range a single tool call may cover. */
const MAX_RANGE_DAYS = 366;

export function resolvePeriod(
  args: Record<string, unknown>,
  today: string,
): { ok: true; period: Period } | { ok: false; error: string } {
  const from = args.from as string | undefined;
  const to = args.to as string | undefined;
  const month = args.month as string | undefined;

  if (from || to) {
    if (!from || !to) return { ok: false, error: "Give both `from` and `to`, or use `month`." };
    if (!isValidDate(from) || !isValidDate(to)) {
      return { ok: false, error: "Dates must be real calendar dates in YYYY-MM-DD form." };
    }
    if (compareDates(from, to) > 0) return { ok: false, error: "`from` must not be after `to`." };
    const span = (Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86_400_000;
    if (span > MAX_RANGE_DAYS) {
      return { ok: false, error: `A range may cover at most ${MAX_RANGE_DAYS} days.` };
    }
    const range = dayRange(from, to);
    return {
      ok: true,
      period: { ...range, label: `${dateLabel(from)} – ${dateLabel(to)}`, month: null },
    };
  }

  const chosen = month ?? monthOf(today);
  if (!isValidMonth(chosen)) return { ok: false, error: "Month must be YYYY-MM." };
  const range = monthRange(chosen);
  return { ok: true, period: { ...range, label: monthLabel(chosen), month: chosen } };
}

/** Dates a write may carry: the same window the app's date picker offers. */
export function checkWriteDate(
  raw: unknown,
  today: string,
): { ok: true; value: string } | { ok: false; error: string } {
  if (raw === undefined || raw === null || raw === "") return { ok: true, value: today };
  if (typeof raw !== "string" || !isValidDate(raw)) {
    return { ok: false, error: "The date must be a real date in YYYY-MM-DD form." };
  }
  const earliest = `${Number(today.slice(0, 4)) - 5}-01-01`;
  const latest = addDays(today, MAX_RANGE_DAYS);
  if (compareDates(raw, earliest) < 0 || compareDates(raw, latest) > 0) {
    return { ok: false, error: "That date is outside the range the app accepts." };
  }
  return { ok: true, value: raw };
}

// ---------------------------------------------------------------------------
// Reference data
// ---------------------------------------------------------------------------

export function accountLabel(account: AccountRow): string {
  const digits = account.last4?.trim();
  return digits ? `${account.nickname} •••• ${digits}` : account.nickname;
}

export function accountNamed(account: AccountRow): Named & { row: AccountRow } {
  const labels = [
    account.nickname,
    account.bank_name,
    `${account.bank_name} ${account.nickname}`,
    `${account.nickname} ${account.bank_name}`,
  ];
  if (account.last4) labels.push(account.last4, `${account.nickname} ${account.last4}`);
  return { id: account.id, labels, row: account };
}

export function categoryNamed(category: CategoryRow): Named & { row: CategoryRow } {
  return { id: category.id, labels: [category.name], row: category };
}

export function methodNamed(method: PaymentMethodRow): Named & { row: PaymentMethodRow } {
  return { id: method.id, labels: [method.name], row: method };
}

/** Turns a resolution into either the row or a message the model can act on. */
export function pickOne<R>(
  resolution: Resolution<Named & { row: R }>,
  what: string,
  available: string[],
): { ok: true; row: R } | { ok: false; error: string } {
  switch (resolution.kind) {
    case "found":
      return { ok: true, row: resolution.item.row };
    case "ambiguous":
      return {
        ok: false,
        error: `More than one ${what} matches: ${
          resolution.candidates.map((c) => c.labels[0]).join(", ")
        }. Ask the user which one they mean.`,
      };
    case "none":
      return {
        ok: false,
        error: available.length === 0
          ? `The user has no ${what}s set up.`
          : `No ${what} matches that name. The user's ${what}s are: ${available.join(", ")}.`,
      };
  }
}

export function findAccount(accounts: AccountRow[], query: string) {
  return pickOne(
    resolveByName(accounts.map(accountNamed), query),
    "bank account",
    accounts.map(accountLabel),
  );
}

export function findCategory(categories: CategoryRow[], query: string) {
  return pickOne(
    resolveByName(categories.map(categoryNamed), query),
    "category",
    categories.map((c) => c.name),
  );
}

export function findPaymentMethod(methods: PaymentMethodRow[], query: string) {
  return pickOne(
    resolveByName(methods.map(methodNamed), query),
    "payment method",
    methods.map((m) => m.name),
  );
}

/** Balances derived exactly as the app derives them: opening + credits − debits. */
export async function accountBalances(
  ctx: ToolContext,
): Promise<Array<{ account: AccountRow; balance: number }>> {
  const [accounts, totals] = await Promise.all([
    ctx.db.listAccounts(ctx.userId),
    ctx.db.ledgerTotals(ctx.userId),
  ]);
  const credits = new Map<string, number>();
  const debits = new Map<string, number>();
  for (const row of totals) {
    const bucket = row.direction === "credit" ? credits : debits;
    bucket.set(row.account_id, (bucket.get(row.account_id) ?? 0) + row.amount);
  }
  return accounts.map((account) => ({
    account,
    balance: Math.round(
      (account.opening_balance + (credits.get(account.id) ?? 0) - (debits.get(account.id) ?? 0)) * 100,
    ) / 100,
  }));
}

export function money(ctx: ToolContext, amount: number): string {
  return formatMoney(amount, ctx.currency);
}

/** Flags a result built from a capped read so the model can say so. */
export function truncatedNote(count: number, cap: number = LIMITS.maxRowsPerAggregate): string | undefined {
  return count >= cap
    ? "Only the most recent rows were counted; the true figure may be higher."
    : undefined;
}
