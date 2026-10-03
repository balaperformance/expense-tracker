import { describe, expect, it } from 'vitest';

import type { BankAccount } from '../models';

import { matchPrintedAccount, parsePrintedAccount } from './accountMatch';
import { parseStatementTime } from './parsing';

const account = (id: string, bankName: string, nickname: string, last4: string | null, isActive = true): BankAccount => ({
  id,
  userId: 'u1',
  bankName,
  nickname,
  last4,
  openingBalance: 0,
  isActive,
  createdAt: null,
});

describe('reading an account a statement names', () => {
  it.each([
    ['Airtel Payments Bank - 14', { bank: 'Airtel Payments Bank', digits: '14' }],
    ['HDFC Bank - 59', { bank: 'HDFC Bank', digits: '59' }],
    ['SBI XX1234', { bank: 'SBI', digits: '1234' }],
    ['ICICI Bank A/c ending 4321', { bank: 'ICICI Bank', digits: '4321' }],
    ['Kotak Mahindra Bank ••5678', { bank: 'Kotak Mahindra Bank', digits: '5678' }],
  ])('%s', (text, expected) => {
    expect(parsePrintedAccount(text)).toEqual(expected);
  });

  it('is nothing without digits or without a name', () => {
    expect(parsePrintedAccount('Paytm Wallet')).toBeNull();
    expect(parsePrintedAccount('1234')).toBeNull();
    expect(parsePrintedAccount('')).toBeNull();
  });
});

describe('matching it to the user’s account', () => {
  const airtel = account('a', 'Airtel Payment Bank', 'Airtel Payment Bank', '9714');
  const hdfc = account('h', 'HDFC Bank', 'HDFC Salary Account', '6459');
  const indian = account('i', 'Indian Bank', 'Indian Bank Savings Account', '4462');
  const sbi = account('s', 'State Bank of India', 'Home', '1234');
  const all = [airtel, hdfc, indian, sbi];

  it('by bank and last digits — two printed digits are the end of the stored number', () => {
    expect(matchPrintedAccount('Airtel Payments Bank - 14', all)?.id).toBe('a');
    expect(matchPrintedAccount('HDFC Bank - 59', all)?.id).toBe('h');
  });

  it('by a bank name made only of common words, when it is the whole name', () => {
    expect(matchPrintedAccount('Indian Bank - 62', all)?.id).toBe('i');
    expect(matchPrintedAccount('Indian Overseas Bank - 62', all)).toBeNull();
  });

  it('by the usual short form of a bank’s name', () => {
    expect(matchPrintedAccount('SBI - 34', all)?.id).toBe('s');
  });

  it('never on digits alone, never on the name alone, never between two', () => {
    expect(matchPrintedAccount('Axis Bank - 59', all)).toBeNull();
    expect(matchPrintedAccount('HDFC Bank - 11', all)).toBeNull();
    expect(matchPrintedAccount('HDFC Bank - 59', [hdfc, account('h2', 'HDFC Bank', 'Joint', '0059')])).toBeNull();
    expect(matchPrintedAccount('HDFC Bank - 59', [account('n', 'HDFC Bank', 'No digits', null)])).toBeNull();
  });

  it('can leave the row’s own account out, to find the other side of a transfer', () => {
    expect(matchPrintedAccount('HDFC Bank - 59', all, { exceptId: 'h' })).toBeNull();
  });
});

describe('a time of day as printed', () => {
  it.each([
    ['10:59 AM', '10:59'],
    ['2:38 AM', '02:38'],
    ['12:49 PM', '12:49'],
    ['12:05 am', '00:05'],
    ['8:57 PM', '20:57'],
    ['14:06', '14:06'],
  ])('%s → %s', (text, expected) => {
    expect(parseStatementTime(text)).toBe(expected);
  });

  it('is nothing for what is not a time', () => {
    expect(parseStatementTime('13:00 PM')).toBeNull();
    expect(parseStatementTime('10:75')).toBeNull();
    expect(parseStatementTime('30 Sep')).toBeNull();
    expect(parseStatementTime(null)).toBeNull();
  });
});
