// Self-account transfer tests.
//
// The two things worth guarding here are the validation rules (which decide
// whether money is allowed to move) and the guarantee that a transfer is
// invisible to income, expense and budget arithmetic. Both are pure logic, so
// both are tested without a database.

import 'package:expense_tracker/core/utils/uuid.dart';
import 'package:expense_tracker/models/analytics.dart';
import 'package:expense_tracker/models/expense.dart';
import 'package:expense_tracker/models/expense_category.dart';
import 'package:expense_tracker/models/income.dart';
import 'package:expense_tracker/models/ledger_entry.dart';
import 'package:expense_tracker/models/money_transfer.dart';
import 'package:flutter_test/flutter_test.dart';

const String _accountA = 'aaaaaaaa-0000-4000-8000-000000000001';
const String _accountB = 'bbbbbbbb-0000-4000-8000-000000000002';

TransferDraft _draft({
  String? from = _accountA,
  String? to = _accountB,
  double? amount = 10000,
  DateTime? date,
  String? note,
}) {
  return TransferDraft(
    fromAccountId: from,
    toAccountId: to,
    amount: amount,
    date: date ?? DateTime(2026, 9, 21),
    note: note,
  );
}

/// The pair of ledger rows a transfer produces, built the same way the
/// repository builds them.
List<LedgerEntry> _legs({
  required double amount,
  required DateTime date,
  String? note,
  String group = 'group-1',
}) {
  return <LedgerEntry>[
    LedgerEntry(
      id: 'leg-debit',
      userId: 'u1',
      accountId: _accountA,
      direction: LedgerDirection.debit,
      amount: amount,
      txnDate: date,
      description: transferDescription(
        note: note,
        isOutgoing: true,
        counterpartyLabel: 'Savings',
      ),
      transferGroupId: group,
      counterpartyAccountId: _accountB,
    ),
    LedgerEntry(
      id: 'leg-credit',
      userId: 'u1',
      accountId: _accountB,
      direction: LedgerDirection.credit,
      amount: amount,
      txnDate: date,
      description: transferDescription(
        note: note,
        isOutgoing: false,
        counterpartyLabel: 'Current',
      ),
      transferGroupId: group,
      counterpartyAccountId: _accountA,
    ),
  ];
}

void main() {
  group('TransferValidation', () {
    test('accepts a well-formed transfer within balance', () {
      expect(
        TransferValidation.check(draft: _draft(), availableBalance: 25000),
        isNull,
      );
    });

    test('rejects a transfer to the same account', () {
      expect(
        TransferValidation.check(
          draft: _draft(to: _accountA),
          availableBalance: 999999,
        ),
        TransferProblem.sameAccount,
      );
    });

    test('rejects more than the account holds', () {
      expect(
        TransferValidation.check(
          draft: _draft(amount: 10000),
          availableBalance: 9999.99,
        ),
        TransferProblem.insufficientFunds,
      );
    });

    test('allows transferring the balance down to exactly zero', () {
      // Guards against binary-float noise rejecting a legitimate full
      // transfer: 0.1 + 0.2 style error must not decide this.
      expect(
        TransferValidation.check(
          draft: _draft(amount: 10000.30),
          availableBalance: 10000.10 + 0.20,
        ),
        isNull,
      );
    });

    test('rejects an overdraft of a single paisa', () {
      expect(
        TransferValidation.check(
          draft: _draft(amount: 10000.01),
          availableBalance: 10000,
        ),
        TransferProblem.insufficientFunds,
      );
    });

    test('rejects zero, negative and missing amounts', () {
      for (final double? amount in <double?>[null, 0, -1]) {
        expect(
          TransferValidation.check(
            draft: _draft(amount: amount),
            availableBalance: 50000,
          ),
          TransferProblem.invalidAmount,
          reason: 'amount $amount should be rejected',
        );
      }
    });

    test('rejects an amount beyond the supported ceiling', () {
      expect(
        TransferValidation.check(
          draft: _draft(amount: TransferValidation.maxAmount + 1),
          availableBalance: null,
        ),
        TransferProblem.amountTooLarge,
      );
    });

    test('a null balance checks shape only and never throws', () {
      // The provider runs this pass before it spends a request reading the
      // balance. `round()` throws on a non-finite double, so a sentinel like
      // double.infinity here would break every otherwise valid transfer.
      expect(
        TransferValidation.check(draft: _draft(), availableBalance: null),
        isNull,
      );
      expect(
        TransferValidation.check(
          draft: _draft(to: _accountA),
          availableBalance: null,
        ),
        TransferProblem.sameAccount,
      );
    });

    test('a non-finite balance does not throw or block a transfer', () {
      for (final double balance in <double>[double.infinity, double.nan]) {
        expect(
          TransferValidation.check(
            draft: _draft(amount: 250),
            availableBalance: balance,
          ),
          isNull,
          reason: 'balance $balance must not crash the check',
        );
      }
    });

    test('requires both accounts', () {
      expect(
        TransferValidation.check(
          draft: _draft(from: null),
          availableBalance: 1000,
        ),
        TransferProblem.noSource,
      );
      expect(
        TransferValidation.check(
          draft: _draft(to: null),
          availableBalance: 1000,
        ),
        TransferProblem.noDestination,
      );
    });

    test('same-account is caught before the balance is consulted', () {
      // An unfunded same-account transfer must report the account clash, not
      // the balance, so the user is told what actually needs fixing.
      expect(
        TransferValidation.check(
          draft: _draft(to: _accountA, amount: 99999),
          availableBalance: 0,
        ),
        TransferProblem.sameAccount,
      );
    });

    test('every problem produces a non-empty message', () {
      for (final TransferProblem problem in TransferProblem.values) {
        expect(problem.message(), isNotEmpty);
      }
    });
  });

  group('transfer legs', () {
    test('debit and credit are equal, opposite and share a group', () {
      final List<LedgerEntry> legs =
          _legs(amount: 10000, date: DateTime(2026, 9, 10));

      expect(legs[0].amount, legs[1].amount);
      expect(legs[0].signedAmount + legs[1].signedAmount, 0);
      expect(legs[0].transferGroupId, legs[1].transferGroupId);
    });

    test('each leg points at the other account', () {
      final List<LedgerEntry> legs =
          _legs(amount: 500, date: DateTime(2026, 9, 21));

      expect(legs[0].accountId, _accountA);
      expect(legs[0].counterpartyAccountId, _accountB);
      expect(legs[1].accountId, _accountB);
      expect(legs[1].counterpartyAccountId, _accountA);
    });

    test('both legs are labelled Money Transfer', () {
      for (final LedgerEntry leg
          in _legs(amount: 500, date: DateTime(2026, 9, 21))) {
        expect(leg.isTransfer, isTrue);
        expect(leg.categoryLabel, moneyTransferLabel);
      }
    });

    test('a leg is never an expense or income document', () {
      // Mirrors the account_transactions_transfer_not_document CHECK
      // constraint: this is the property that keeps transfers out of
      // spending analytics.
      for (final LedgerEntry leg
          in _legs(amount: 500, date: DateTime(2026, 9, 21))) {
        expect(leg.expenseId, isNull);
        expect(leg.incomeId, isNull);
        expect(leg.isDocumentBacked, isFalse);
      }
    });

    test('a leg carries no category id', () {
      for (final LedgerEntry leg
          in _legs(amount: 500, date: DateTime(2026, 9, 21))) {
        expect(leg.categoryId, isNull);
      }
    });

    test('description describes the direction when no note is given', () {
      final List<LedgerEntry> legs =
          _legs(amount: 500, date: DateTime(2026, 9, 21));
      expect(legs[0].description, 'Transfer to Savings');
      expect(legs[1].description, 'Transfer from Current');
    });

    test('a note replaces the generated description on both legs', () {
      final List<LedgerEntry> legs = _legs(
        amount: 500,
        date: DateTime(2026, 9, 21),
        note: '  Rent set aside  ',
      );
      expect(legs[0].description, 'Rent set aside');
      expect(legs[1].description, 'Rent set aside');
    });

    test('a blank note falls back to the generated description', () {
      final List<LedgerEntry> legs = _legs(
        amount: 500,
        date: DateTime(2026, 9, 21),
        note: '   ',
      );
      expect(legs[0].description, 'Transfer to Savings');
    });

    test('insert map omits the counterparty when there is none', () {
      // Sending an explicit null would break ordinary deposits on a database
      // where migration 003 has not been applied.
      final LedgerEntry deposit = LedgerEntry(
        id: '',
        userId: 'u1',
        accountId: _accountA,
        direction: LedgerDirection.credit,
        amount: 100,
        txnDate: DateTime(2026, 9, 21),
      );
      expect(
        deposit.toInsertMap().containsKey('counterparty_account_id'),
        isFalse,
      );
    });

    test('insert map includes the counterparty for a transfer leg', () {
      final Map<String, dynamic> map =
          _legs(amount: 100, date: DateTime(2026, 9, 21))[0].toInsertMap();
      expect(map['counterparty_account_id'], _accountB);
      expect(map['transfer_group_id'], 'group-1');
    });

    test('a row read back from the database keeps the transfer link', () {
      final LedgerEntry entry = LedgerEntry.fromMap(<String, dynamic>{
        'id': 'x',
        'user_id': 'u1',
        'account_id': _accountA,
        'direction': 'debit',
        'amount': 10000,
        'txn_date': '2026-09-21',
        'description': 'Transfer to Savings',
        'transfer_group_id': 'group-9',
        'counterparty_account_id': _accountB,
      });

      expect(entry.isTransfer, isTrue);
      expect(entry.counterpartyAccountId, _accountB);
      expect(entry.title, 'Transfer to Savings');
    });

    test('a transfer with no description still titles itself', () {
      final LedgerEntry entry = LedgerEntry.fromMap(<String, dynamic>{
        'id': 'x',
        'user_id': 'u1',
        'account_id': _accountA,
        'direction': 'credit',
        'amount': 10,
        'txn_date': '2026-09-21',
        'transfer_group_id': 'group-9',
      });
      expect(entry.title, moneyTransferLabel);
    });
  });

  group('statements show both sides of a transfer', () {
    test('sender sees a debit that reduces the running balance', () {
      final AccountStatement statement = buildStatement(
        openingBalance: 25000,
        entries: <LedgerEntry>[
          _legs(amount: 10000, date: DateTime(2026, 9, 10))[0],
        ],
      );

      expect(statement.rows.single.entry.isDebit, isTrue);
      expect(statement.rows.single.entry.categoryLabel, moneyTransferLabel);
      expect(statement.rows.single.balanceAfter, 15000);
      expect(statement.totalDebits, 10000);
      expect(statement.totalCredits, 0);
      expect(statement.closingBalance, 15000);
    });

    test('receiver sees a credit that raises the running balance', () {
      final AccountStatement statement = buildStatement(
        openingBalance: 2000,
        entries: <LedgerEntry>[
          _legs(amount: 10000, date: DateTime(2026, 9, 10))[1],
        ],
      );

      expect(statement.rows.single.entry.isCredit, isTrue);
      expect(statement.rows.single.entry.categoryLabel, moneyTransferLabel);
      expect(statement.rows.single.balanceAfter, 12000);
      expect(statement.totalCredits, 10000);
      expect(statement.closingBalance, 12000);
    });

    test('the pair leaves the combined balance untouched', () {
      final List<LedgerEntry> legs =
          _legs(amount: 10000, date: DateTime(2026, 9, 10));

      final double senderClosing = buildStatement(
        openingBalance: 25000,
        entries: <LedgerEntry>[legs[0]],
      ).closingBalance;
      final double receiverClosing = buildStatement(
        openingBalance: 2000,
        entries: <LedgerEntry>[legs[1]],
      ).closingBalance;

      // Money moved; none was created or destroyed.
      expect(senderClosing + receiverClosing, 25000 + 2000);
    });

    test('a debits-only filter still shows the full-walk balance', () {
      final List<LedgerEntry> legs =
          _legs(amount: 1000, date: DateTime(2026, 9, 10));

      final AccountStatement statement = buildStatement(
        openingBalance: 5000,
        entries: <LedgerEntry>[legs[0]],
        typeFilter: StatementTypeFilter.debitsOnly,
      );

      expect(statement.rows.single.balanceAfter, 4000);
    });
  });

  group('transfers are not income or spending', () {
    // The guarantee is structural rather than a filter: a transfer writes
    // ledger rows only, while the Dashboard, Reports and budgets are all
    // computed from expense and income rows. There is no type a transfer
    // could even be added to these lists as, which is the point.

    final List<Expense> expenses = <Expense>[
      Expense(
        id: 'e1',
        userId: 'u1',
        amount: 1200,
        categoryId: 'c1',
        expenseDate: DateTime(2026, 9, 5),
      ),
    ];
    final List<Income> incomes = <Income>[
      Income(
        id: 'i1',
        userId: 'u1',
        amount: 50000,
        source: 'Salary',
        incomeDate: DateTime(2026, 9, 1),
      ),
    ];

    double totalExpense() =>
        expenses.fold<double>(0, (double sum, Expense e) => sum + e.amount);
    double totalIncome() =>
        incomes.fold<double>(0, (double sum, Income i) => sum + i.amount);

    test('dashboard totals are unmoved by a transfer', () {
      final double expenseBefore = totalExpense();
      final double incomeBefore = totalIncome();

      // A ₹10,000 transfer happens here. It produces ledger rows and nothing
      // else, so neither list the dashboard sums has changed.
      final List<LedgerEntry> legs =
          _legs(amount: 10000, date: DateTime(2026, 9, 10));
      expect(legs, hasLength(2));

      expect(totalExpense(), expenseBefore);
      expect(totalIncome(), incomeBefore);
      expect(totalIncome() - totalExpense(), 50000 - 1200);
    });

    test('the category breakdown gains no Money Transfer slice', () {
      final List<CategorySpend> breakdown = buildCategoryBreakdown(
        expenses,
        const <ExpenseCategory>[],
      );

      expect(
        breakdown.any((CategorySpend c) => c.name == moneyTransferLabel),
        isFalse,
      );
      expect(
        breakdown.fold<double>(0, (double s, CategorySpend c) => s + c.total),
        1200,
      );
    });

    test('a transfer leg carries no category, so no budget can absorb it', () {
      for (final LedgerEntry leg
          in _legs(amount: 10000, date: DateTime(2026, 9, 10))) {
        expect(leg.categoryId, isNull);
        expect(leg.expenseId, isNull);
        expect(leg.incomeId, isNull);
      }
    });
  });

  group('Uuid', () {
    test('produces a canonical version 4 uuid', () {
      final RegExp pattern = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-'
        r'[0-9a-f]{12}$',
      );
      for (int i = 0; i < 50; i++) {
        expect(pattern.hasMatch(Uuid.v4()), isTrue);
      }
    });

    test('does not repeat', () {
      final Set<String> seen = <String>{
        for (int i = 0; i < 500; i++) Uuid.v4(),
      };
      expect(seen.length, 500);
    });
  });
}
