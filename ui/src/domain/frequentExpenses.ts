/**
 * Quick add: the purchases the user makes again and again (the morning
 * coffee, the weekly groceries, the monthly recharge) offered as one-tap
 * starting points on a new expense. Ported line for line to
 * `mobile/lib/models/frequent_expense.dart`; `frequentExpenses.fixture.json`
 * holds both to the same answers.
 *
 * A suggestion only fills the form. Saving still goes through the normal
 * path, so validation, the ledger debit and the card outstanding stay where
 * they are, and nothing is written until the user says so.
 */
import { addDays, type IsoDate } from '@/lib/dates';

import type { Expense } from './models';

/** How far back the habits are read: long enough to see a monthly bill three times. */
export const FREQUENT_WINDOW_DAYS = 90;
/** Fewer purchases than this are not a habit yet. */
export const FREQUENT_MIN_COUNT = 3;
export const FREQUENT_LIMIT = 6;
/** The newest purchases read for suggestions: enough for months of typical use, bounded for a busy one. */
export const FREQUENT_HISTORY_ROWS = 300;

/** How it was paid last time, while that is still possible. */
export type FrequentSource = { kind: 'cash' } | { kind: 'account'; id: string } | { kind: 'card'; id: string };

export type FrequentExpense = {
  /** The category and the normalised title: stable while the habit lasts. */
  key: string;
  /** The merchant or description as last written; null when neither was, so the category names it. */
  title: string | null;
  categoryId: string;
  /** The usual amount, or null when it varies (no single amount covers half of the purchases). */
  amount: number | null;
  description: string | null;
  merchant: string | null;
  /** Null when none was set last time or the method has since been deleted. */
  paymentMethodId: string | null;
  /** Null when the account or card it was last paid from is closed or gone; the form then starts from cash. */
  source: FrequentSource | null;
  count: number;
  lastDate: IsoDate;
};

export type FrequentExpenseInput = Pick<
  Expense,
  'id' | 'amount' | 'expenseDate' | 'createdAt' | 'categoryId' | 'paymentMethodId' | 'bankAccountId' | 'creditCardId' | 'merchant' | 'description'
>;

export type FrequentExpenseContext = {
  today: IsoDate;
  /** Purchases paid on someone else's behalf: owed back, so not the user's own habits. */
  excludeIds: ReadonlySet<string>;
  /** What the form can offer now, so a suggestion never points at a deleted category or a closed account. */
  categoryIds: ReadonlySet<string>;
  paymentMethodIds: ReadonlySet<string>;
  accountIds: ReadonlySet<string>;
  cardIds: ReadonlySet<string>;
};

const clean = (text: string | null | undefined): string | null => {
  const trimmed = (text ?? '').trim();
  return trimmed === '' ? null : trimmed;
};

/** "Uber", " uber " and "UBER" are one habit. */
const normalise = (title: string) => title.toLowerCase().replace(/\s+/g, ' ');

const cents = (amount: number) => Math.round(amount * 100);

/** Negative when [a] happened before [b]: by date, then entry time, then id. */
function chronological(a: FrequentExpenseInput, b: FrequentExpenseInput): number {
  const byDate = compareText(a.expenseDate, b.expenseDate);
  if (byDate !== 0) return byDate;
  const byCreated = compareText(a.createdAt ?? '', b.createdAt ?? '');
  return byCreated !== 0 ? byCreated : compareText(a.id, b.id);
}

const compareText = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);

/** The amount that covers at least half of the purchases (and more than one), most recent on a tie. */
function usualAmount(group: readonly FrequentExpenseInput[]): number | null {
  const tally = new Map<number, { count: number; last: FrequentExpenseInput }>();
  for (const expense of group) {
    const key = cents(expense.amount);
    const seen = tally.get(key);
    if (!seen) tally.set(key, { count: 1, last: expense });
    else {
      seen.count += 1;
      if (chronological(expense, seen.last) > 0) seen.last = expense;
    }
  }
  let best: { cents: number; count: number; last: FrequentExpenseInput } | null = null;
  for (const [amountCents, { count, last }] of tally) {
    if (!best || count > best.count || (count === best.count && chronological(last, best.last) > 0)) best = { cents: amountCents, count, last };
  }
  return best && best.count >= 2 && best.count * 2 >= group.length ? best.cents / 100 : null;
}

function sourceOf(expense: FrequentExpenseInput, context: FrequentExpenseContext): FrequentSource | null {
  if (expense.creditCardId != null) return context.cardIds.has(expense.creditCardId) ? { kind: 'card', id: expense.creditCardId } : null;
  if (expense.bankAccountId != null) return context.accountIds.has(expense.bankAccountId) ? { kind: 'account', id: expense.bankAccountId } : null;
  return { kind: 'cash' };
}

/**
 * The user's most frequent purchases over the last [FREQUENT_WINDOW_DAYS]
 * days, most frequent first: grouped by category and title (merchant, else
 * description), each bought at least [FREQUENT_MIN_COUNT] times. Each one is
 * filled from its latest purchase, with the usual amount when there is one.
 */
export function frequentExpenses(
  expenses: readonly FrequentExpenseInput[],
  context: FrequentExpenseContext,
  limit: number = FREQUENT_LIMIT,
): FrequentExpense[] {
  const from = addDays(context.today, -(FREQUENT_WINDOW_DAYS - 1));
  const groups = new Map<string, { categoryId: string; expenses: FrequentExpenseInput[] }>();
  for (const expense of expenses) {
    const categoryId = expense.categoryId;
    if (categoryId == null || !context.categoryIds.has(categoryId) || context.excludeIds.has(expense.id)) continue;
    if (!(expense.amount > 0) || expense.expenseDate < from || expense.expenseDate > context.today) continue;
    const title = clean(expense.merchant) ?? clean(expense.description);
    const key = `${categoryId}|${title == null ? '' : normalise(title)}`;
    const group = groups.get(key);
    if (group) group.expenses.push(expense);
    else groups.set(key, { categoryId, expenses: [expense] });
  }

  const found: Array<{ suggestion: FrequentExpense; latest: FrequentExpenseInput }> = [];
  for (const [key, group] of groups) {
    if (group.expenses.length < FREQUENT_MIN_COUNT) continue;
    const latest = group.expenses.reduce((a, b) => (chronological(b, a) > 0 ? b : a));
    const methodId = latest.paymentMethodId;
    found.push({
      latest,
      suggestion: {
        key,
        title: clean(latest.merchant) ?? clean(latest.description),
        categoryId: group.categoryId,
        amount: usualAmount(group.expenses),
        description: clean(latest.description),
        merchant: clean(latest.merchant),
        paymentMethodId: methodId != null && context.paymentMethodIds.has(methodId) ? methodId : null,
        source: sourceOf(latest, context),
        count: group.expenses.length,
        lastDate: latest.expenseDate,
      },
    });
  }

  return found
    .sort((a, b) => b.suggestion.count - a.suggestion.count || chronological(b.latest, a.latest) || compareText(a.suggestion.key, b.suggestion.key))
    .slice(0, Math.max(0, limit))
    .map((f) => f.suggestion);
}
