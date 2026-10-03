/**
 * The push sender cannot import the app's domain code (it runs in Deno, the
 * app is bundled with path aliases), so its core re-states four rules. These
 * tests hold each of them to the app's own implementation, over many inputs:
 * a notification must never disagree with the screen it is about.
 */
import { describe, expect, it } from 'vitest';

import { accountBalances } from '../../../supabase/functions/push-notify/core/balances.ts';
import { cycleContaining as senderCycle, lastStatement } from '../../../supabase/functions/push-notify/core/cards.ts';
import { addDays as senderAddDays, addMonths as senderAddMonths, dayInMonth as senderDayInMonth } from '../../../supabase/functions/push-notify/core/dates.ts';
import { personalSpendingCents } from '../../../supabase/functions/push-notify/core/spending.ts';
import { addDays, addMonths, fromParts } from '@/lib/dates';

import { personalSpending, sumBy } from '../analytics';
import { cycleContaining as appCycle, dayInMonth as appDayInMonth, entryFromCardTransaction, entryFromExpense, summariseCard, type CardEntry } from '../creditCards';
import { currentBalance, type CreditCard, type Expense } from '../models';

describe('spending', () => {
  const expense = (id: string, amount: number, date: string): Expense =>
    ({ id, userId: 'u', amount, categoryId: null, paymentMethodId: null, expenseDate: date, description: null, notes: null, merchant: null, bankAccountId: null, creditCardId: null, createdAt: null, updatedAt: null, category: null, paymentMethod: null });

  it('matches the Reports page: every expense in the period except those paid for someone else', () => {
    const expenses = [
      expense('a', 120.1, '2026-10-01'),
      expense('b', 0.2, '2026-10-01'),
      expense('c', 999.99, '2026-10-15'),
      expense('d', 5000, '2026-10-20'),
      expense('e', 33.33, '2026-10-31'),
      expense('f', 7, '2026-09-30'),
    ];
    const paidFor = new Set(['d']);
    const inMonth = expenses.filter((e) => e.expenseDate.startsWith('2026-10'));
    const reports = sumBy(personalSpending(inMonth, paidFor), (e) => e.amount);
    const sender = personalSpendingCents(
      expenses.map((e) => ({ id: e.id, amount: e.amount, date: e.expenseDate })),
      paidFor,
      '2026-10-01',
      '2026-10-31',
    );
    expect(sender).toBe(Math.round(reports * 100));
  });
});

describe('bank balance', () => {
  it('matches the Accounts screen: opening balance + credits − debits', () => {
    const ledger = [
      { accountId: 'a', direction: 'credit' as const, amount: 5000.1 },
      { accountId: 'a', direction: 'debit' as const, amount: 1234.56 },
      { accountId: 'a', direction: 'debit' as const, amount: 0.07 },
      { accountId: 'b', direction: 'credit' as const, amount: 10 },
    ];
    const opening = 250.25;
    const [sender] = accountBalances([{ id: 'a', name: 'A', openingBalance: opening, isActive: true }], ledger);
    // The app sums each direction in cents, then combines with the opening balance.
    const cents = (v: number) => Math.round(v * 100);
    const credits = ledger.filter((r) => r.accountId === 'a' && r.direction === 'credit').reduce((s, r) => s + cents(r.amount), 0) / 100;
    const debits = ledger.filter((r) => r.accountId === 'a' && r.direction === 'debit').reduce((s, r) => s + cents(r.amount), 0) / 100;
    const app = currentBalance({
      account: { id: 'a', userId: 'u', bankName: 'A', nickname: 'A', last4: null, openingBalance: opening, isActive: true, createdAt: null },
      totalCredits: credits,
      totalDebits: debits,
    });
    expect(sender?.balanceCents).toBe(Math.round(app * 100));
  });
});

describe('dates', () => {
  const days = ['2026-01-31', '2026-02-28', '2028-02-29', '2026-03-01', '2026-10-05', '2026-12-31'];

  it('add days, add months and clamp a day to the month the way the app does', () => {
    for (const day of days) {
      for (const delta of [-31, -1, 1, 30, 400]) expect(senderAddDays(day, delta)).toBe(addDays(day, delta));
      for (const delta of [-13, -1, 1, 13]) expect(senderAddMonths(day, delta)).toBe(addMonths(day, delta));
      for (const target of [1, 28, 29, 30, 31]) expect(senderDayInMonth(day, target)).toBe(appDayInMonth(day, target));
    }
  });
});

describe('credit card billing', () => {
  const card = (statementDay: number, paymentDueDay: number, openingOutstanding = 0): CreditCard => ({
    id: 'c1',
    userId: 'u',
    cardName: 'Card',
    issuer: 'Bank',
    network: null,
    last4: null,
    creditLimit: 100000,
    openingOutstanding,
    statementDay,
    paymentDueDay,
    paymentAccountId: null,
    isActive: true,
    notes: null,
    createdAt: null,
  });

  it('finds the same billing cycle and due date as the card screen, on every day of a year', () => {
    for (const [statementDay, dueDay] of [[5, 25], [31, 20], [1, 15], [28, 10], [15, 3], [30, 30]] as const) {
      for (let i = 0; i < 366; i += 3) {
        const day = addDays('2026-01-01', i);
        expect(senderCycle(day, statementDay, dueDay)).toEqual(appCycle(day, statementDay, dueDay));
      }
    }
  });

  it('finds the same unpaid bill as the card summary: due date, what remains, and whether it is due', () => {
    const entries = (cardId: string): Array<{ cardId: string; direction: 'debit' | 'credit'; amount: number; date: string }> => [
      { cardId, direction: 'debit', amount: 3200.5, date: '2026-08-12' },
      { cardId, direction: 'debit', amount: 1800, date: '2026-09-03' },
      { cardId, direction: 'credit', amount: 1000, date: '2026-09-18' },
      { cardId, direction: 'debit', amount: 450.25, date: '2026-09-29' },
      { cardId, direction: 'credit', amount: 2000, date: '2026-10-12' },
      { cardId, direction: 'debit', amount: 99, date: '2026-10-20' },
    ];
    const asApp = (rows: ReturnType<typeof entries>): CardEntry[] =>
      rows.map((row, i) =>
        row.direction === 'debit'
          ? (entryFromExpense({
              id: `e${i}`,
              userId: 'u',
              amount: row.amount,
              categoryId: null,
              paymentMethodId: null,
              expenseDate: row.date,
              description: null,
              notes: null,
              merchant: null,
              bankAccountId: null,
              creditCardId: row.cardId,
              createdAt: null,
              updatedAt: null,
              category: null,
              paymentMethod: null,
            }) as CardEntry)
          : entryFromCardTransaction({
              id: `t${i}`,
              userId: 'u',
              cardId: row.cardId,
              kind: 'payment',
              direction: 'credit',
              amount: row.amount,
              txnDate: row.date,
              description: null,
              reference: null,
              originalExpenseId: null,
              createdAt: null,
            }),
      );

    for (const [statementDay, dueDay, opening] of [[5, 25, 0], [20, 8, 1500], [31, 15, 0]] as const) {
      const rows = entries('c1');
      for (let i = 0; i < 120; i += 2) {
        const today = addDays('2026-08-01', i);
        const app = summariseCard(card(statementDay, dueDay, opening), asApp(rows), today).lastStatement;
        const sender = lastStatement(
          { id: 'c1', name: 'Card', statementDay, paymentDueDay: dueDay, openingOutstanding: opening, isActive: true },
          rows,
          today,
        );
        expect(sender.dueDate).toBe(app.cycle.dueDate);
        expect(sender.remainingCents).toBe(Math.round(app.remaining * 100));
        expect(sender.status).toBe(app.status);
      }
    }
  });

  it('knows the day-of-month helper clamps like fromParts', () => {
    expect(senderDayInMonth('2026-02-10', 31)).toBe(fromParts(2026, 2, 28));
  });
});
