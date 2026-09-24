/**
 * Parity tests: ported case-for-case from `mobile/test/bank_sms_test.dart`,
 * so the web parser is held to the Flutter parser's behaviour.
 */
import { describe, expect, it } from 'vitest';

import type { BankAccount, ExpenseCategory } from '../models';

import { parseBankSms, smsIsUsable } from './bankSmsParser';
import { applyAssistantCategory, buildSmsDraft, fallbackCategory, matchSmsAccount, shouldAskAssistant } from './smsDraft';

const now = new Date(2026, 8, 22);
const today = '2026-09-22';

const hdfcKeyMakers = 'Sent Rs.2900.00\nFrom HDFC Bank A/C *6459\nTo CHENNAI KEY MAKERS\nOn 19/09/26';
const airtelSmall = 'Rs. 30.00 debited from Airtel Payments Bank a/c Txn ID 663129068661 Bal:183.03';
const hdfcPerson = 'Sent Rs.250.00\nFrom HDFC Bank A/C *6459\nTo Mrs Malathi Ramu\nOn 22/09/26.';

const category = (id: string, name: string): ExpenseCategory => ({
  id,
  userId: 'u1',
  name,
  icon: 'category',
  color: '#78909C',
  isDefault: false,
  createdAt: null,
});

const account = (partial: Partial<BankAccount> & Pick<BankAccount, 'id' | 'bankName' | 'nickname'>): BankAccount => ({
  userId: 'u1',
  last4: null,
  openingBalance: 0,
  isActive: true,
  createdAt: null,
  ...partial,
});

const testCategories = [category('food', 'Food'), category('transport', 'Transport'), category('other', 'Other')];
const testAccounts = [
  account({ id: 'acc-hdfc', bankName: 'HDFC Bank', nickname: 'HDFC Salary', last4: '6459' }),
  account({ id: 'acc-icici', bankName: 'ICICI Bank', nickname: 'ICICI Savings', last4: '1122' }),
];

const read = (text: string) => parseBankSms(text, now);
const draftFor = (text: string, categories = testCategories, accounts = testAccounts) =>
  buildSmsDraft({ sms: read(text), accounts, categories, today });

describe('the provided examples', () => {
  it('HDFC debit to a merchant, every field', () => {
    const sms = read(hdfcKeyMakers);
    expect(smsIsUsable(sms)).toBe(true);
    expect(sms.direction).toBe('debit');
    expect(sms.amount).toBe(2900);
    expect(sms.bankName).toBe('HDFC Bank');
    expect(sms.last4).toBe('6459');
    expect(sms.counterparty).toBe('CHENNAI KEY MAKERS');
    expect(sms.date).toBe('2026-09-19');
    expect(sms.reference).toBeNull();
    expect(sms.availableBalance).toBeNull();
  });

  it('Airtel debit: no payee, no date, but an id and a balance', () => {
    const sms = read(airtelSmall);
    expect(sms.direction).toBe('debit');
    expect(sms.amount).toBe(30);
    expect(sms.bankName).toBe('Airtel Payments Bank');
    expect(sms.reference).toBe('663129068661');
    expect(sms.availableBalance).toBe(183.03);
    expect(sms.counterparty).toBeNull();
    expect(sms.date).toBeNull();
    expect(sms.last4).toBeNull();
  });

  it('HDFC debit to a person, with a trailing full stop', () => {
    const sms = read(hdfcPerson);
    expect(sms.amount).toBe(250);
    expect(sms.counterparty).toBe('Mrs Malathi Ramu');
    expect(sms.date).toBe('2026-09-22');
    expect(sms.last4).toBe('6459');
  });
});

describe('amount', () => {
  it('reads every currency spelling', () => {
    for (const text of [
      'Rs.100 debited from HDFC Bank a/c',
      'Rs 100 debited from HDFC Bank a/c',
      'INR 100 debited from HDFC Bank a/c',
      'INR100 debited from HDFC Bank a/c',
      '₹100 debited from HDFC Bank a/c',
      '100 INR debited from HDFC Bank a/c',
    ]) {
      expect(read(text).amount, text).toBe(100);
    }
  });

  it('handles Indian digit grouping and paise', () => {
    expect(read('Rs.1,23,456.78 debited from a/c').amount).toBe(123456.78);
  });

  it('never mistakes the balance for the amount', () => {
    expect(read(airtelSmall).amount).toBe(30);
    expect(read('Rs 250 spent at SHOP. Avl Bal Rs 9,000.00').amount).toBe(250);
    expect(read('Rs 250 spent at SHOP. Available balance INR 9000').amount).toBe(250);
  });

  it('reads an amount with no currency marker at all', () => {
    expect(read('Your a/c is debited by 500 at SHOP').amount).toBe(500);
  });

  it('rejects a figure that is not money', () => {
    expect(smsIsUsable(read('Rs 0.00 debited from a/c'))).toBe(false);
  });
});

describe('direction', () => {
  it('every debit verb', () => {
    for (const verb of ['debited', 'spent', 'paid', 'sent', 'withdrawn']) {
      expect(read(`Rs 50 ${verb} from a/c`).direction, verb).toBe('debit');
    }
  });

  it('every credit verb', () => {
    for (const verb of ['credited', 'received', 'deposited', 'refunded']) {
      expect(read(`Rs 50 ${verb} to a/c`).direction, verb).toBe('credit');
    }
  });

  it('the leading verb decides, not a later incidental mention', () => {
    expect(read('Rs 500 credited to a/c linked to your debit card').direction).toBe('credit');
  });

  it('a message with no verb is not a transaction', () => {
    expect(smsIsUsable(read('Your balance is Rs 500'))).toBe(false);
  });
});

describe('bank and account digits', () => {
  it('reads the bank out of the clause before a/c', () => {
    expect(read(hdfcKeyMakers).bankName).toBe('HDFC Bank');
    expect(read(airtelSmall).bankName).toBe('Airtel Payments Bank');
    expect(read('Rs 10 debited from State Bank of India a/c XX1234').bankName).toBe('State Bank of India');
  });

  it('reads a bank named without any a/c', () => {
    expect(read('Rs 10 spent using Kotak Bank card').bankName).toBe('Kotak Bank');
  });

  it('reads masked digits in each shape', () => {
    for (const clause of ['A/C *6459', 'a/c XX6459', 'A/c no. XXXXXX6459', 'ac 6459', 'account no: 6459']) {
      expect(read(`Rs 10 debited from HDFC Bank ${clause}`).last4, clause).toBe('6459');
    }
  });

  it('reads a card ending instead', () => {
    expect(read('Rs 10 spent on card ending 4821 at SHOP').last4).toBe('4821');
  });

  it('an "ac" inside a merchant name does not hide the real account', () => {
    const sms = read('Rs 100 spent at AC SERVICE from HDFC Bank a/c *6459 on 19/09/26');
    expect(sms.bankName).toBe('HDFC Bank');
    expect(sms.last4).toBe('6459');
  });

  it('refuses to read a long number as masked digits', () => {
    expect(read(airtelSmall).last4).toBeNull();
    expect(read('Rs 10 debited from a/c 123456789012 at SHOP').last4).toBeNull();
  });
});

describe('payee', () => {
  it('reads a merchant and a person', () => {
    expect(read(hdfcKeyMakers).counterparty).toBe('CHENNAI KEY MAKERS');
    expect(read(hdfcPerson).counterparty).toBe('Mrs Malathi Ramu');
  });

  it('reads an "at MERCHANT" message', () => {
    expect(read('INR 1,250.50 spent at AMAZON RETAIL on 12-Mar-2026').counterparty).toBe('AMAZON RETAIL');
  });

  it('stops at the next field rather than swallowing it', () => {
    expect(read('Rs 10 sent to BLUE DART Ref no 8891 Bal 200').counterparty).toBe('BLUE DART');
  });

  it('does not cut a merchant whose own name contains "on"', () => {
    expect(read('Rs 10 sent to SALON ON WHEELS on 19/09/26').counterparty).toBe('SALON ON WHEELS');
  });

  it('reports nothing when the message names nobody', () => {
    expect(read(airtelSmall).counterparty).toBeNull();
  });
});

describe('date', () => {
  it('reads the common formats', () => {
    const cases: Record<string, string> = {
      '19/09/26': '2026-09-19',
      '19-09-2026': '2026-09-19',
      '19-Sep-26': '2026-09-19',
      '19 Sep 2026': '2026-09-19',
      '2026-09-19': '2026-09-19',
      '19.09.26': '2026-09-19',
    };
    for (const [written, expected] of Object.entries(cases)) {
      expect(read(`Rs 10 sent to SHOP on ${written}`).date, written).toBe(expected);
    }
  });

  it('a two-digit year that cannot be real is reported as no date', () => {
    expect(read('Rs 10 sent to SHOP on 19/09/99').date).toBeNull();
  });

  it('a two-digit year just ahead is still accepted', () => {
    expect(read('Rs 10 sent to SHOP on 19/09/27').date).toBe('2027-09-19');
  });

  it('rejects a date that does not exist', () => {
    expect(read('Rs 10 sent to SHOP on 31/02/26').date).toBeNull();
  });

  it('reports nothing rather than guessing at today', () => {
    expect(read(airtelSmall).date).toBeNull();
  });
});

describe('reference', () => {
  it('reads the labels banks use', () => {
    for (const label of ['Txn ID', 'txn id', 'Ref no', 'Reference No.', 'UTR', 'RRN']) {
      expect(read(`Rs 10 debited from a/c ${label} 663129068661`).reference, label).toBe('663129068661');
    }
  });

  it('reports nothing when there is no id', () => {
    expect(read(hdfcKeyMakers).reference).toBeNull();
  });
});

describe('unreadable input', () => {
  it('ordinary text is not a transaction', () => {
    for (const text of ['', '   ', 'hello mum how are you', 'Your OTP is 123456. Do not share it.']) {
      expect(smsIsUsable(read(text)), text).toBe(false);
    }
  });

  it('capitalisation and spacing do not matter', () => {
    const shouted = read('SENT   RS.2900.00\n\n\nFROM HDFC BANK A/C *6459\nTO CHENNAI KEY MAKERS\nON 19/09/26');
    expect(shouted.amount).toBe(2900);
    expect(shouted.last4).toBe('6459');
    expect(shouted.counterparty).toBe('CHENNAI KEY MAKERS');
    expect(shouted.date).toBe('2026-09-19');
  });

  it('a very long paste is capped rather than rejected outright', () => {
    expect(read(`${hdfcKeyMakers} ${'x'.repeat(5000)}`).amount).toBe(2900);
  });
});

describe('bank account matching', () => {
  it('matches on the last four digits', () => {
    const match = matchSmsAccount(read(hdfcKeyMakers), testAccounts);
    expect(match?.account.id).toBe('acc-hdfc');
    expect(match?.strength).toBe('exact');
    expect(match?.reason).toContain('6459');
  });

  it('does not match when the digits belong to no account', () => {
    expect(matchSmsAccount(read('Rs 10 debited from HDFC Bank A/C *9999'), testAccounts)).toBeNull();
  });

  it('falls back to the bank name when no digits were read', () => {
    const match = matchSmsAccount(read('Rs 10 debited from HDFC Bank'), testAccounts);
    expect(match?.account.id).toBe('acc-hdfc');
    expect(match?.strength).toBe('likely');
  });

  it('refuses to guess between two accounts at the same bank', () => {
    const twoHdfc = [
      account({ id: 'a', bankName: 'HDFC Bank', nickname: 'One' }),
      account({ id: 'b', bankName: 'HDFC Bank', nickname: 'Two' }),
    ];
    expect(matchSmsAccount(read('Rs 10 debited from HDFC Bank'), twoHdfc)).toBeNull();
  });

  it('generic words alone never match', () => {
    expect(matchSmsAccount(read('Rs 10 debited from Yes Bank'), testAccounts)).toBeNull();
  });

  it('an unknown bank produces no match and no account', () => {
    expect(matchSmsAccount(read(airtelSmall), testAccounts)).toBeNull();
    expect(draftFor(airtelSmall).bankAccountId).toBeNull();
  });

  it('ignores closed accounts', () => {
    const closed = [account({ id: 'old', bankName: 'HDFC Bank', nickname: 'Closed', last4: '6459', isActive: false })];
    expect(matchSmsAccount(read(hdfcKeyMakers), closed)).toBeNull();
  });
});

describe('draft', () => {
  it('carries the parsed values and the matched account', () => {
    const draft = draftFor(hdfcKeyMakers);
    expect(draft.amount).toBe(2900);
    expect(draft.merchant).toBe('CHENNAI KEY MAKERS');
    expect(draft.date).toBe('2026-09-19');
    expect(draft.bankAccountId).toBe('acc-hdfc');
    expect(draft.reference).toBeNull();
  });

  it('falls back to today only when the message gave no date', () => {
    expect(draftFor(airtelSmall).date).toBe(today);
    expect(draftFor(hdfcKeyMakers).date).toBe('2026-09-19');
  });

  it('uses a keyword category when the payee is recognisable', () => {
    const draft = draftFor('Rs 800 spent at INDIAN OIL PETROL PUMP');
    expect(draft.categoryId).toBe('transport');
    expect(draft.categorySource).toBe('keyword');
    expect(draft.categoryReason).not.toBeNull();
  });

  it('falls back to Other when nothing is recognisable', () => {
    const draft = draftFor(hdfcKeyMakers);
    expect(draft.categoryId).toBe('other');
    expect(draft.categorySource).toBe('fallback');
    expect(draft.categoryReason).toBeNull();
  });

  it('accepts the other spellings of a catch-all', () => {
    for (const name of ['Other', 'Others', 'Miscellaneous', 'Uncategorised']) {
      expect(fallbackCategory([category('x', name)])?.id, name).toBe('x');
    }
  });

  it('leaves the category empty when the user has no catch-all', () => {
    const draft = draftFor(hdfcKeyMakers, [category('food', 'Food')]);
    expect(draft.categoryId).toBeNull();
    expect(draft.categorySource).toBe('none');
  });

  it('only the payee feeds the category, never the whole message', () => {
    const draft = draftFor('Rs 500 debited from SCHOOL ROAD BRANCH Bank a/c XX1122 to BIG BAZAAR', [
      ...testCategories,
      category('edu', 'Education'),
    ]);
    expect(draft.categoryId).not.toBe('edu');
  });

  it('carries the reference so a repeat can be spotted', () => {
    expect(draftFor(airtelSmall).reference).toBe('663129068661');
  });
});

describe('assistant category suggestion', () => {
  it('is not consulted when the keywords already matched', () => {
    expect(shouldAskAssistant(draftFor('Rs 800 spent at INDIAN OIL PETROL PUMP'), testCategories)).toBe(false);
  });

  it('is consulted for an unrecognised payee', () => {
    expect(shouldAskAssistant(draftFor(hdfcKeyMakers), testCategories)).toBe(true);
  });

  it('only accepts one of the user’s own categories', () => {
    const draft = draftFor(hdfcKeyMakers);
    expect(applyAssistantCategory(draft, testCategories, 'Locksmiths')).toBe(draft);
    const applied = applyAssistantCategory(draft, testCategories, 'transport');
    expect(applied.categoryId).toBe('transport');
    expect(applied.categorySource).toBe('assistant');
  });
});
