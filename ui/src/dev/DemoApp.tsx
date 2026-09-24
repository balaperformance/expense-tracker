/**
 * Development-only preview: the real screens over seeded sample data, so the
 * UI can be reviewed on any device without signing in. Loaded from main.tsx
 * only when `import.meta.env.DEV` and the URL carries `?demo`; the branch is
 * compiled out of production builds. Nothing here talks to Supabase — writes
 * made in the preview simply fail.
 */
import type { User } from '@supabase/supabase-js';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { useState } from 'react';
import { BrowserRouter } from 'react-router';

import { AppRoutes } from '@/app/App';
import { DEFAULT_CATEGORIES, DEFAULT_PAYMENT_METHODS } from '@/domain/defaults';
import { EMPTY_EXPENSE_FILTER } from '@/domain/expenseFilter';
import type { BankAccountBalance, Budget, Expense, ExpenseCategory, Income, LedgerEntry, PaymentMethod } from '@/domain/models';
import { buildBudgetProgress, sumBy } from '@/domain/analytics';
import { addDays, addMonths, firstOfMonth, monthRange, today, trailingMonths } from '@/lib/dates';
import { overrideCapabilities } from '@/services/capabilities';
import { AiChatProvider } from '@/state/aiChat';
import { StaticAuthProvider } from '@/state/auth';
import { FeedbackProvider } from '@/state/feedback';
import { keys } from '@/state/queryClient';
import { SettingsProvider } from '@/state/settings';

const USER_ID = 'demo-user';
const user = {
  id: USER_ID,
  email: 'demo@example.com',
  user_metadata: { full_name: 'Aarav Mehta' },
  app_metadata: {},
  aud: 'authenticated',
  created_at: '2026-01-01T00:00:00Z',
} as unknown as User;

const now = today();
const stamp = (date: string, n: number) => `${date}T${String(8 + (n % 12)).padStart(2, '0')}:00:00Z`;

const categories: ExpenseCategory[] = DEFAULT_CATEGORIES.map((c, i) => ({
  id: `cat-${i}`,
  userId: USER_ID,
  name: c.name,
  icon: c.icon,
  color: c.color,
  isDefault: true,
  createdAt: null,
})).sort((a, b) => a.name.localeCompare(b.name));
function cat(name: string): ExpenseCategory {
  const found = categories.find((c) => c.name === name);
  if (!found) throw new Error(`No demo category ${name}`);
  return found;
}

const methods: PaymentMethod[] = DEFAULT_PAYMENT_METHODS.map((name, i) => ({ id: `pm-${i}`, userId: USER_ID, name, createdAt: null }));
const upi = methods.find((m) => m.name === 'UPI') ?? null;

const accounts: BankAccountBalance[] = [
  {
    account: { id: 'acc-1', userId: USER_ID, bankName: 'HDFC Bank', nickname: 'Salary', last4: '6459', openingBalance: 84250, isActive: true, createdAt: '2026-01-01' },
    totalCredits: 0,
    totalDebits: 0,
  },
  {
    account: { id: 'acc-2', userId: USER_ID, bankName: 'ICICI Bank', nickname: 'Savings', last4: '1122', openingBalance: 152000, isActive: true, createdAt: '2026-01-02' },
    totalCredits: 0,
    totalDebits: 0,
  },
];

const SAMPLES: [string, string, number, string | null][] = [
  ['Food', 'Blue Tokai Coffee', 420, 'acc-1'],
  ['Transport', 'Uber', 386, null],
  ['Shopping', 'Myntra', 2499, 'acc-1'],
  ['Bills', 'Airtel Postpaid', 799, 'acc-1'],
  ['Food', 'Nature’s Basket', 1864, 'acc-1'],
  ['Entertainment', 'PVR Cinemas', 960, null],
  ['Health', 'Apollo Pharmacy', 540, 'acc-1'],
  ['Travel', 'IndiGo', 6240, 'acc-2'],
  ['Food', 'Swiggy', 612, null],
  ['Education', 'Kindle Books', 349, 'acc-1'],
  ['Transport', 'Indian Oil', 2100, 'acc-1'],
  ['Other', 'Chennai Key Makers', 2900, 'acc-1'],
];

let n = 0;
const expenses: Expense[] = [];
for (const [mi, month] of trailingMonths(now, 6).entries()) {
  const days = monthRange(month);
  const perMonth = mi === 5 ? SAMPLES.length : 7 + mi;
  for (let i = 0; i < perMonth; i++) {
    const [category, merchant, base, accountId] = SAMPLES[(i + mi) % SAMPLES.length] as (typeof SAMPLES)[number];
    const date = mi === 5 ? addDays(now, -Math.floor(i * 1.6)) : addDays(days.start, (i * 3) % 27);
    if (date > now || date < days.start) continue;
    const c = cat(category);
    expenses.push({
      id: `exp-${n}`,
      userId: USER_ID,
      amount: Math.round(base * (0.8 + ((n * 37) % 40) / 100)),
      expenseDate: date,
      categoryId: c.id,
      paymentMethodId: accountId ? null : (upi?.id ?? null),
      bankAccountId: accountId,
      merchant,
      description: null,
      notes: null,
      createdAt: stamp(date, n),
      updatedAt: null,
      category: c,
      paymentMethod: accountId ? null : upi,
    });
    n++;
  }
}
expenses.sort((a, b) => (a.expenseDate < b.expenseDate ? 1 : -1));

const income: Income[] = trailingMonths(now, 6).flatMap((month, i) => [
  {
    id: `inc-${i}`,
    userId: USER_ID,
    amount: 142000,
    incomeDate: addDays(month, 0),
    source: 'Salary',
    description: 'Monthly salary',
    bankAccountId: 'acc-1',
    createdAt: stamp(month, i),
  },
  ...(i % 2 === 0
    ? [{ id: `inc-f${i}`, userId: USER_ID, amount: 18500, incomeDate: addDays(month, 12), source: 'Freelance', description: 'Design retainer', bankAccountId: 'acc-2', createdAt: stamp(month, i + 3) }]
    : []),
]).filter((i) => i.incomeDate <= now).sort((a, b) => (a.incomeDate < b.incomeDate ? 1 : -1));

const ledger: LedgerEntry[] = [
  ...expenses.filter((e) => e.bankAccountId).map((e): LedgerEntry => ({
    id: `led-${e.id}`, userId: USER_ID, accountId: e.bankAccountId ?? '', direction: 'debit', amount: e.amount, txnDate: e.expenseDate,
    description: e.merchant, categoryId: e.categoryId, expenseId: e.id, incomeId: null, transferGroupId: null, counterpartyAccountId: null,
    createdAt: e.createdAt, category: e.category,
  })),
  ...income.filter((i) => i.bankAccountId).map((i): LedgerEntry => ({
    id: `led-${i.id}`, userId: USER_ID, accountId: i.bankAccountId ?? '', direction: 'credit', amount: i.amount, txnDate: i.incomeDate,
    description: i.source, categoryId: null, expenseId: null, incomeId: i.id, transferGroupId: null, counterpartyAccountId: null,
    createdAt: i.createdAt, category: null,
  })),
  { id: 'tr-1', userId: USER_ID, accountId: 'acc-1', direction: 'debit', amount: 25000, txnDate: addDays(now, -3), description: 'Transfer to Savings', categoryId: null, expenseId: null, incomeId: null, transferGroupId: 'g1', counterpartyAccountId: 'acc-2', createdAt: stamp(addDays(now, -3), 1), category: null },
  { id: 'tr-2', userId: USER_ID, accountId: 'acc-2', direction: 'credit', amount: 25000, txnDate: addDays(now, -3), description: 'Transfer from Salary', categoryId: null, expenseId: null, incomeId: null, transferGroupId: 'g1', counterpartyAccountId: 'acc-1', createdAt: stamp(addDays(now, -3), 1), category: null },
];
for (const balance of accounts) {
  const mine = ledger.filter((l) => l.accountId === balance.account.id);
  balance.totalCredits = sumBy(mine.filter((l) => l.direction === 'credit'), (l) => l.amount);
  balance.totalDebits = sumBy(mine.filter((l) => l.direction === 'debit'), (l) => l.amount);
}

const inMonth = <T,>(items: T[], date: (item: T) => string, month: string) => {
  const range = monthRange(month);
  return items.filter((item) => date(item) >= range.start && date(item) < range.endExclusive);
};

function monthRaw(month: string) {
  const months = trailingMonths(month, 6);
  const monthExpenses = inMonth(expenses, (e) => e.expenseDate, month);
  const monthIncome = inMonth(income, (i) => i.incomeDate, month);
  return {
    month: firstOfMonth(month),
    totalExpense: sumBy(monthExpenses, (e) => e.amount),
    totalIncome: sumBy(monthIncome, (i) => i.amount),
    expenses: monthExpenses,
    trend: months.map((m) => ({
      month: m,
      expense: sumBy(inMonth(expenses, (e) => e.expenseDate, m), (e) => e.amount),
      income: sumBy(inMonth(income, (i) => i.incomeDate, m), (i) => i.amount),
    })),
  };
}

const budgets: Budget[] = [
  { id: 'b-all', userId: USER_ID, amount: 60000, month: firstOfMonth(now), categoryId: null, createdAt: null, category: null },
  { id: 'b-food', userId: USER_ID, amount: 4000, month: firstOfMonth(now), categoryId: cat('Food').id, createdAt: null, category: cat('Food') },
  { id: 'b-shop', userId: USER_ID, amount: 5000, month: firstOfMonth(now), categoryId: cat('Shopping').id, createdAt: null, category: cat('Shopping') },
  { id: 'b-trans', userId: USER_ID, amount: 2600, month: firstOfMonth(now), categoryId: cat('Transport').id, createdAt: null, category: cat('Transport') },
];

function seededClient(): QueryClient {
  const client = new QueryClient({
    defaultOptions: {
      queries: { staleTime: Infinity, gcTime: Infinity, retry: false, refetchOnWindowFocus: false, refetchOnMount: false },
    },
  });
  const caps = { merchant: true, bankAccounts: true, expenseBankLink: true, incomeBankLink: true, transfers: true };
  overrideCapabilities(caps);
  const set = (key: readonly unknown[], data: unknown) => client.setQueryData(key, data);
  set(['bootstrap', USER_ID], true);
  set(keys.capabilities(USER_ID), caps);
  set(keys.profile(USER_ID), { id: USER_ID, fullName: 'Aarav Mehta', currency: 'INR' });
  set(keys.categories(USER_ID), categories);
  set(keys.paymentMethods(USER_ID), methods);
  set([...keys.accounts(USER_ID), true], accounts);
  set(keys.dashboard(USER_ID, firstOfMonth(now)), monthRaw(now));
  for (let i = 0; i < 6; i++) set(keys.reports(USER_ID, addMonths(now, -i)), monthRaw(addMonths(now, -i)));
  set(keys.budgets(USER_ID, firstOfMonth(now)), buildBudgetProgress(budgets, inMonth(expenses, (e) => e.expenseDate, now)));
  set(keys.expenses(USER_ID, EMPTY_EXPENSE_FILTER), { pages: [expenses.slice(0, 20)], pageParams: [0] });
  set(keys.income(USER_ID, ''), { pages: [income.slice(0, 20)], pageParams: [0] });
  for (const e of expenses.slice(0, 20)) set(keys.expense(USER_ID, e.id), e);
  for (const balance of accounts) {
    const id = balance.account.id;
    const range = monthRange(now);
    const entries = ledger.filter((l) => l.accountId === id && l.txnDate >= range.start && l.txnDate < range.endExclusive);
    const before = ledger.filter((l) => l.accountId === id && l.txnDate < range.start);
    const priorNet = sumBy(before, (l) => (l.direction === 'credit' ? l.amount : -l.amount));
    set(keys.statement(USER_ID, id, firstOfMonth(now)), { entries, priorNet });
    set(keys.statement(USER_ID, id, 'all'), { entries: ledger.filter((l) => l.accountId === id), priorNet: 0 });
  }
  return client;
}

export function DemoApp() {
  const [client] = useState(seededClient);
  return (
    <QueryClientProvider client={client}>
      <StaticAuthProvider user={user}>
        <SettingsProvider>
          <AiChatProvider>
            <FeedbackProvider>
              <BrowserRouter>
                <AppRoutes />
              </BrowserRouter>
            </FeedbackProvider>
          </AiChatProvider>
        </SettingsProvider>
      </StaticAuthProvider>
    </QueryClientProvider>
  );
}
