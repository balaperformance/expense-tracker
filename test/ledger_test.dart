// Phase 2 ledger tests.
//
// buildStatement is a pure function, so the running-balance and summary
// arithmetic — the part most likely to be wrong and most expensive to get
// wrong — is verified here without a database.

import 'package:expense_tracker/core/errors/retry.dart';
import 'package:expense_tracker/models/bank_account.dart';
import 'package:expense_tracker/models/ledger_entry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

LedgerEntry _entry({
  required String id,
  required LedgerDirection direction,
  required double amount,
  required DateTime date,
  DateTime? created,
  String? description,
}) {
  return LedgerEntry(
    id: id,
    userId: 'u1',
    accountId: 'a1',
    direction: direction,
    amount: amount,
    txnDate: date,
    createdAt: created,
    description: description,
  );
}

LedgerEntry _credit(String id, double amount, DateTime date,
        {DateTime? created}) =>
    _entry(
      id: id,
      direction: LedgerDirection.credit,
      amount: amount,
      date: date,
      created: created,
    );

LedgerEntry _debit(String id, double amount, DateTime date,
        {DateTime? created}) =>
    _entry(
      id: id,
      direction: LedgerDirection.debit,
      amount: amount,
      date: date,
      created: created,
    );

void main() {
  _retryTests();

  group('LedgerEntry', () {
    test('signed amount carries the direction', () {
      expect(_credit('1', 100, DateTime(2025, 3, 1)).signedAmount, 100);
      expect(_debit('2', 100, DateTime(2025, 3, 1)).signedAmount, -100);
    });

    test('wire format round-trips', () {
      expect(LedgerDirection.debit.wire, 'debit');
      expect(LedgerDirection.credit.wire, 'credit');
      expect(LedgerDirectionWire.parse('credit'), LedgerDirection.credit);
      expect(LedgerDirectionWire.parse('debit'), LedgerDirection.debit);
      // Anything unexpected must not silently become a credit.
      expect(LedgerDirectionWire.parse(null), LedgerDirection.debit);
      expect(LedgerDirectionWire.parse('nonsense'), LedgerDirection.debit);
    });

    test('parses a row including the joined category', () {
      final LedgerEntry entry = LedgerEntry.fromMap(<String, dynamic>{
        'id': 'l1',
        'user_id': 'u1',
        'account_id': 'a1',
        'direction': 'debit',
        'amount': 250.5,
        'txn_date': '2025-03-14',
        'description': 'Groceries',
        'category_id': 'c1',
        'expense_id': 'e1',
        'categories': <String, dynamic>{
          'id': 'c1',
          'user_id': 'u1',
          'name': 'Food',
        },
      });

      expect(entry.amount, 250.5);
      expect(entry.txnDate, DateTime(2025, 3, 14));
      expect(entry.isDebit, isTrue);
      expect(entry.category?.name, 'Food');
      expect(entry.expenseId, 'e1');
    });
  });

  group('buildStatement running balance', () {
    test('walks oldest-first and returns newest-first', () {
      final AccountStatement statement = buildStatement(
        openingBalance: 1000,
        entries: <LedgerEntry>[
          _debit('d1', 200, DateTime(2025, 3, 5)),
          _credit('c1', 500, DateTime(2025, 3, 10)),
          _debit('d2', 100, DateTime(2025, 3, 15)),
        ],
      );

      // Newest first in the output.
      expect(statement.rows.first.entry.id, 'd2');
      expect(statement.rows.last.entry.id, 'd1');

      // 1000 - 200 = 800, + 500 = 1300, - 100 = 1200
      expect(statement.rows.last.balanceAfter, 800);
      expect(statement.rows[1].balanceAfter, 1300);
      expect(statement.rows.first.balanceAfter, 1200);
    });

    test('unsorted input still produces a correct walk', () {
      final AccountStatement statement = buildStatement(
        openingBalance: 0,
        entries: <LedgerEntry>[
          _debit('d2', 100, DateTime(2025, 3, 15)),
          _debit('d1', 200, DateTime(2025, 3, 5)),
          _credit('c1', 500, DateTime(2025, 3, 10)),
        ],
      );

      expect(statement.rows.last.balanceAfter, -200);
      expect(statement.rows.first.balanceAfter, 200);
    });

    test('same-day entries order by creation time, not id', () {
      final DateTime day = DateTime(2025, 3, 7);
      final AccountStatement statement = buildStatement(
        openingBalance: 100,
        entries: <LedgerEntry>[
          _credit('zzz', 50, day, created: DateTime(2025, 3, 7, 9)),
          _debit('aaa', 30, day, created: DateTime(2025, 3, 7, 18)),
        ],
      );

      // Credit happened first despite sorting later alphabetically.
      expect(statement.rows.last.entry.id, 'zzz');
      expect(statement.rows.last.balanceAfter, 150);
      expect(statement.rows.first.balanceAfter, 120);
    });

    test('opening balance carries into the first row', () {
      final AccountStatement statement = buildStatement(
        openingBalance: 2500,
        entries: <LedgerEntry>[_debit('d1', 500, DateTime(2025, 4, 2))],
      );
      expect(statement.rows.single.balanceAfter, 2000);
      expect(statement.openingBalance, 2500);
    });

    test('handles an empty period without dividing or throwing', () {
      final AccountStatement statement = buildStatement(
        openingBalance: 750,
        entries: const <LedgerEntry>[],
      );
      expect(statement.isEmpty, isTrue);
      expect(statement.totalCredits, 0);
      expect(statement.totalDebits, 0);
      expect(statement.closingBalance, 750);
    });
  });

  group('buildStatement summary', () {
    test('totals and closing balance reconcile', () {
      final AccountStatement statement = buildStatement(
        openingBalance: 1000,
        entries: <LedgerEntry>[
          _credit('c1', 2000, DateTime(2025, 3, 1)),
          _debit('d1', 300, DateTime(2025, 3, 2)),
          _debit('d2', 700, DateTime(2025, 3, 3)),
        ],
      );

      expect(statement.totalCredits, 2000);
      expect(statement.totalDebits, 1000);
      expect(statement.closingBalance, 2000);
      // Closing must equal the last computed running balance.
      expect(statement.closingBalance, statement.rows.first.balanceAfter);
      expect(statement.movementCount, 3);
    });

    test('a negative closing balance is preserved, not clamped', () {
      final AccountStatement statement = buildStatement(
        openingBalance: 100,
        entries: <LedgerEntry>[_debit('d1', 400, DateTime(2025, 3, 1))],
      );
      expect(statement.closingBalance, -300);
    });
  });

  group('buildStatement type filter', () {
    final List<LedgerEntry> entries = <LedgerEntry>[
      _debit('d1', 200, DateTime(2025, 3, 5)),
      _credit('c1', 500, DateTime(2025, 3, 10)),
      _debit('d2', 100, DateTime(2025, 3, 15)),
    ];

    test('filtering to debits keeps balances from the full walk', () {
      final AccountStatement statement = buildStatement(
        openingBalance: 1000,
        entries: entries,
        typeFilter: StatementTypeFilter.debitsOnly,
      );

      expect(statement.rows.length, 2);
      // d2's balance still reflects the hidden credit that preceded it.
      expect(statement.rows.first.entry.id, 'd2');
      expect(statement.rows.first.balanceAfter, 1200);
      expect(statement.rows.last.balanceAfter, 800);
    });

    test('totals describe only the visible rows', () {
      final AccountStatement statement = buildStatement(
        openingBalance: 1000,
        entries: entries,
        typeFilter: StatementTypeFilter.debitsOnly,
      );
      expect(statement.totalDebits, 300);
      expect(statement.totalCredits, 0);
    });

    test('credits-only filter', () {
      final AccountStatement statement = buildStatement(
        openingBalance: 1000,
        entries: entries,
        typeFilter: StatementTypeFilter.creditsOnly,
      );
      expect(statement.rows.length, 1);
      expect(statement.rows.single.entry.id, 'c1');
      expect(statement.rows.single.balanceAfter, 1300);
      expect(statement.totalCredits, 500);
    });

    test('filter predicate matches the right directions', () {
      expect(StatementTypeFilter.all.matches(LedgerDirection.debit), isTrue);
      expect(StatementTypeFilter.all.matches(LedgerDirection.credit), isTrue);
      expect(
        StatementTypeFilter.debitsOnly.matches(LedgerDirection.credit),
        isFalse,
      );
      expect(
        StatementTypeFilter.creditsOnly.matches(LedgerDirection.debit),
        isFalse,
      );
    });
  });

  group('BankAccountBalance', () {
    const BankAccount account = BankAccount(
      id: 'a1',
      userId: 'u1',
      bankName: 'HDFC',
      nickname: 'Salary',
      last4: '4821',
      openingBalance: 1000,
    );

    test('current balance derives from opening plus movements', () {
      const BankAccountBalance balance = BankAccountBalance(
        account: account,
        totalCredits: 5000,
        totalDebits: 1200,
      );
      expect(balance.currentBalance, 4800);
      expect(balance.isOverdrawn, isFalse);
    });

    test('detects an overdrawn account', () {
      const BankAccountBalance balance = BankAccountBalance(
        account: account,
        totalCredits: 0,
        totalDebits: 1500,
      );
      expect(balance.currentBalance, -500);
      expect(balance.isOverdrawn, isTrue);
    });

    test('display label includes masked digits when present', () {
      expect(account.displayLabel, contains('4821'));
      expect(account.displayLabel, startsWith('Salary'));

      const BankAccount noDigits = BankAccount(
        id: 'a2',
        userId: 'u1',
        bankName: 'ICICI',
        nickname: 'Joint',
      );
      expect(noDigits.displayLabel, 'Joint');
    });

    test('maps a row and omits blank last4 on write', () {
      final BankAccount parsed = BankAccount.fromMap(<String, dynamic>{
        'id': 'a3',
        'user_id': 'u1',
        'bank_name': 'SBI',
        'nickname': 'Savings',
        'last4': null,
        'opening_balance': 250.75,
        'is_active': true,
      });
      expect(parsed.openingBalance, 250.75);
      expect(parsed.last4, isNull);

      final Map<String, dynamic> insert =
          parsed.copyWith(last4: '   ').toInsertMap();
      expect(insert['last4'], isNull);
    });
  });

  group('cash versus bank separation', () {
    test('a cash expense contributes no ledger entry, so no balance moves', () {
      // A cash expense is modelled as the absence of a movement. Proving the
      // arithmetic here documents the invariant the repository relies on.
      final AccountStatement statement = buildStatement(
        openingBalance: 1000,
        entries: const <LedgerEntry>[],
      );
      expect(statement.closingBalance, 1000);
    });

    test('only bank-funded expenses reduce the balance', () {
      final AccountStatement statement = buildStatement(
        openingBalance: 1000,
        entries: <LedgerEntry>[_debit('d1', 250, DateTime(2025, 3, 4))],
      );
      expect(statement.closingBalance, 750);
      expect(statement.totalDebits, 250);
    });
  });
}

/// Regression tests for the clock-skew retry.
///
/// A token stamped `iat = now` can be rejected by PostgREST if the first
/// query lands in the same second. This surfaced as PGRST303 on the very
/// first screen after signing in.
void _retryTests() {
  group('retryOnTransientAuth', () {
    test('retries PGRST303 and then succeeds', () async {
      int calls = 0;
      final String result = await retryOnTransientAuth(
        () async {
          calls++;
          if (calls < 3) {
            throw const PostgrestException(
              message: 'JWT issued at future',
              code: 'PGRST303',
            );
          }
          return 'ok';
        },
        step: const Duration(milliseconds: 1),
      );

      expect(result, 'ok');
      expect(calls, 3);
    });

    test('gives up after the attempt limit', () async {
      int calls = 0;
      await expectLater(
        retryOnTransientAuth(
          () async {
            calls++;
            throw const PostgrestException(
              message: 'JWT issued at future',
              code: 'PGRST303',
            );
          },
          attempts: 2,
          step: const Duration(milliseconds: 1),
        ),
        throwsA(isA<PostgrestException>()),
      );
      expect(calls, 2);
    });

    test('does not retry an unrelated Postgrest error', () async {
      int calls = 0;
      await expectLater(
        retryOnTransientAuth(
          () async {
            calls++;
            throw const PostgrestException(
              message: 'column does not exist',
              code: '42703',
            );
          },
          step: const Duration(milliseconds: 1),
        ),
        throwsA(isA<PostgrestException>()),
      );
      // Exactly one attempt: a missing column will never fix itself.
      expect(calls, 1);
    });
  });
}
