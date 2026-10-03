import { describe, expect, it } from 'vitest';

import { averagePerExpense, isMonthInProgress, monthStanding } from './analytics';
import { totalBalance, type BankAccountBalance } from './models';

const balance = (id: string, opening: number, credits: number, debits: number, isActive = true): BankAccountBalance => ({
  account: { id, userId: 'u1', bankName: 'Bank', nickname: id, last4: null, openingBalance: opening, isActive, createdAt: null },
  totalCredits: credits,
  totalDebits: debits,
});

describe('a month still running', () => {
  it('is the month today falls in', () => {
    expect(isMonthInProgress('2026-10-01', '2026-10-03')).toBe(true);
    expect(isMonthInProgress('2026-10-31', '2026-10-01')).toBe(true);
  });

  it('is never an earlier month', () => {
    expect(isMonthInProgress('2026-09-01', '2026-10-03')).toBe(false);
    expect(isMonthInProgress('2025-10-01', '2026-10-03')).toBe(false);
  });
});

describe('what the month’s summary leads with', () => {
  it('while the month runs, the balance available now — not income less spending', () => {
    // Salary paid at month-end: nothing received yet, so the month is not "overspent".
    expect(monthStanding({ inProgress: true, available: 42_000, income: 0, expense: 18_500 })).toEqual({
      kind: 'balance',
      available: 42_000,
    });
  });

  it('while the month runs without accounts, the spending so far', () => {
    expect(monthStanding({ inProgress: true, available: null, income: 0, expense: 18_500 })).toEqual({ kind: 'spent', spent: 18_500 });
  });

  it('once the month is over, saved or overspent', () => {
    expect(monthStanding({ inProgress: false, available: null, income: 90_000, expense: 61_000 })).toEqual({
      kind: 'net',
      net: 29_000,
      saved: true,
    });
    expect(monthStanding({ inProgress: false, available: null, income: 10_000, expense: 12_500 })).toEqual({
      kind: 'net',
      net: -2_500,
      saved: false,
    });
  });

  it('never uses today’s balance to judge a month that is over', () => {
    expect(monthStanding({ inProgress: false, available: 42_000, income: 0, expense: 500 })).toEqual({ kind: 'net', net: -500, saved: false });
  });
});

describe('available balance', () => {
  it('adds every account’s ledger balance, as the Accounts screen does', () => {
    expect(totalBalance([balance('a', 1_000, 500, 200), balance('b', 0, 3_000, 3_500), balance('closed', 0, 100, 100, false)])).toBe(800);
  });

  it('is nothing without accounts', () => {
    expect(totalBalance([])).toBe(0);
  });
});

describe('average per expense', () => {
  it('is spending over the number of expenses', () => {
    expect(averagePerExpense(900, 3)).toBe(300);
  });

  it('is nothing when nothing was spent', () => {
    expect(averagePerExpense(0, 0)).toBe(0);
  });
});
