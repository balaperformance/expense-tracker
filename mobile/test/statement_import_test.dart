// Statement import on the phone: the session the provider keeps around the
// shared engine, and the writes it makes once the user confirms.
//
// The engine itself is the web app's code (tested there); here it is a
// scripted fake, and the repositories record what would have been written.
// Nothing touches a network or a database, and every figure is invented.

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:expense_tracker/models/bank_account.dart';
import 'package:expense_tracker/models/credit_card.dart';
import 'package:expense_tracker/models/expense.dart';
import 'package:expense_tracker/models/expense_category.dart';
import 'package:expense_tracker/models/income.dart';
import 'package:expense_tracker/models/ledger_entry.dart';
import 'package:expense_tracker/providers/statement_import_provider.dart';
import 'package:expense_tracker/repositories/expense_repository.dart';
import 'package:expense_tracker/repositories/income_repository.dart';
import 'package:expense_tracker/repositories/ledger_repository.dart';
import 'package:expense_tracker/services/statement_import/statement_engine.dart';

const BankAccount account = BankAccount(
  id: 'a1',
  userId: 'u1',
  bankName: 'Test Bank',
  nickname: 'Savings',
  last4: '1234',
);

/// Answers engine calls from a script and records each one.
class FakeEngine implements StatementEngine {
  FakeEngine(this.handlers);

  final Map<String, Object? Function(Map<String, Object?> args)> handlers;
  final List<(String, Map<String, Object?>)> calls =
      <(String, Map<String, Object?>)>[];
  final List<String> released = <String>[];
  int picks = 0;

  @override
  Future<PickedStatementFile?> pickFile() async {
    picks++;
    return PickedStatementFile(token: 'f$picks', name: 'statement.pdf', size: 10);
  }

  @override
  Future<Object?> call(String name, Map<String, Object?> args) async {
    calls.add((name, args));
    final Object? Function(Map<String, Object?>)? handler = handlers[name];
    if (handler == null) throw StateError('unexpected call $name');
    return handler(args);
  }

  @override
  Future<void> release(String token) async => released.add(token);

  List<Map<String, Object?>> argsOf(String name) => <Map<String, Object?>>[
        for (final (String n, Map<String, Object?> a) in calls)
          if (n == name) a,
      ];
}

class RecordingLedger extends LedgerRepository {
  RecordingLedger(super.client);

  List<LedgerEntry> recorded = <LedgerEntry>[];
  bool failFetch = false;
  final List<Map<String, Object?>> writes = <Map<String, Object?>>[];

  @override
  Future<List<LedgerEntry>> fetchForAccount({
    required String userId,
    required String accountId,
    DateTime? from,
    DateTime? toExclusive,
  }) async {
    if (failFetch) throw StateError('offline');
    return recorded;
  }

  @override
  Future<void> recordCardPayment({
    required String userId,
    required String accountId,
    required String cardId,
    required double amount,
    required DateTime date,
    required String description,
  }) async =>
      writes.add(<String, Object?>{
        'type': 'cardPayment',
        'accountId': accountId,
        'cardId': cardId,
        'amount': amount,
      });

  @override
  Future<LedgerEntry> deposit({
    required String userId,
    required String accountId,
    required double amount,
    required DateTime date,
    String? description,
  }) async {
    writes.add(<String, Object?>{'type': 'deposit', 'amount': amount});
    return _entry(LedgerDirection.credit, amount, date);
  }

  @override
  Future<LedgerEntry> withdraw({
    required String userId,
    required String accountId,
    required double amount,
    required DateTime date,
    String? description,
  }) async {
    writes.add(<String, Object?>{'type': 'withdraw', 'amount': amount});
    return _entry(LedgerDirection.debit, amount, date);
  }

  LedgerEntry _entry(LedgerDirection direction, double amount, DateTime date) =>
      LedgerEntry(
        id: 'l${writes.length}',
        userId: 'u1',
        accountId: 'a1',
        direction: direction,
        amount: amount,
        txnDate: date,
      );
}

class RecordingExpenses extends ExpenseRepository {
  RecordingExpenses(super.client);

  final List<Expense> created = <Expense>[];
  int failures = 0;

  @override
  Future<Expense> create(Expense expense) async {
    if (failures > 0) {
      failures--;
      throw StateError('write failed');
    }
    created.add(expense);
    return expense;
  }
}

class RecordingIncome extends IncomeRepository {
  RecordingIncome(super.client);

  final List<Income> created = <Income>[];

  @override
  Future<Income> create(Income income) async {
    created.add(income);
    return income;
  }
}

Map<String, Object?> statement(String id, {int rows = 2}) => <String, Object?>{
      'statement': <String, Object?>{
        'id': id,
        'fileName': 'statement.pdf',
        'period': <String, Object?>{'from': '2026-09-01', 'to': '2026-09-30'},
        'transactions': <Object?>[
          for (int i = 0; i < rows; i++) <String, Object?>{'id': '$id-$i'},
        ],
        'warnings': <Object?>[],
      },
      'periodLabel': 'Monthly · 1 Sep – 30 Sep 2026',
      'accountMismatch': false,
    };

Map<String, Object?> row(String id, {bool selected = true}) => <String, Object?>{
      'id': id,
      'transactionDate': '2026-09-10',
      'amount': 100,
      'transactionType': 'debit',
      'kind': 'expense',
      'selected': selected,
    };

Map<String, Object?> op(String type, {String? card, String direction = 'debit'}) =>
    <String, Object?>{
      'type': type,
      'bankAccountId': 'a1',
      'amount': 1200.5,
      'date': '2026-09-10',
      'description': 'Row',
      'direction': direction,
      if (card != null) 'creditCardId': card,
    };

void main() {
  late SupabaseClient client;
  late RecordingLedger ledger;
  late RecordingExpenses expenses;
  late RecordingIncome income;

  setUp(() {
    client = SupabaseClient(
      'http://localhost:54321',
      'test-anon-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    ledger = RecordingLedger(client);
    expenses = RecordingExpenses(client);
    income = RecordingIncome(client);
  });

  StatementImportProvider providerFor(FakeEngine engine) {
    final StatementImportProvider provider = StatementImportProvider(
      engine: engine,
      expenses: expenses,
      income: income,
      ledger: ledger,
    );
    provider.begin(
      userId: 'u1',
      account: account,
      accounts: const <BankAccount>[account],
      categories: const <ExpenseCategory>[],
      cards: const <CreditCard>[],
    );
    return provider;
  }

  Map<String, Object? Function(Map<String, Object?>)> reviewing(
    Object? Function(Map<String, Object?>) read,
  ) =>
      <String, Object? Function(Map<String, Object?>)>{
        'read': read,
        'sessionRange': (_) =>
            <String, Object?>{'from': '2026-09-01', 'to': '2026-09-30'},
        'review': (Map<String, Object?> args) => <Object?>[
              for (final Object? t in args['transactions']! as List<Object?>)
                row((t! as Map<String, Object?>)['id']! as String),
            ],
        'view': (Map<String, Object?> args) => <String, Object?>{
              'summary': <String, Object?>{
                'selected': (args['items']! as List<Object?>).length,
              },
              'rows': <Object?>[],
            },
      };

  group('reading a statement', () {
    test('asks for a password, says when it is wrong, and never keeps it',
        () async {
      final FakeEngine engine = FakeEngine(reviewing((Map<String, Object?> a) {
        return switch (a['password']) {
          null => throw const StatementEngineException(
              'passwordRequired', 'This statement is password-protected.'),
          'right' => statement('s1'),
          _ => throw const StatementEngineException(
              'passwordIncorrect', 'That password did not open it.'),
        };
      }));
      final StatementImportProvider provider = providerFor(engine);

      await provider.addFile();
      expect(provider.pending, isNotNull);
      expect(provider.pending!.incorrect, isFalse);
      expect(provider.hasRows, isFalse);
      expect(engine.released, isEmpty,
          reason: 'the file stays open while the password is asked for');

      await provider.unlock('wrong');
      expect(provider.pending!.incorrect, isTrue);

      await provider.unlock('right');
      expect(provider.pending, isNull);
      expect(provider.rows, hasLength(2));
      expect(provider.statements.single.periodLabel, contains('Sep'));

      // The password reaches the reader with the read call and nowhere else.
      final List<String> named = <String>[
        for (final (String name, Map<String, Object?> args) in engine.calls)
          if (args.containsKey('password')) name,
      ];
      expect(named.toSet(), <String>{'read'});
    });

    test('cancelling the password closes the file', () async {
      final FakeEngine engine = FakeEngine(reviewing((_) =>
          throw const StatementEngineException('passwordRequired', 'Locked.')));
      final StatementImportProvider provider = providerFor(engine);

      await provider.addFile();
      provider.cancelPassword();
      expect(provider.pending, isNull);
      expect(engine.released, <String>['f1']);
    });

    test('the same statement twice is refused, and its file closed', () async {
      final FakeEngine engine = FakeEngine(reviewing((_) => statement('s1')));
      final StatementImportProvider provider = providerFor(engine);

      await provider.addFile();
      await provider.addFile();
      expect(provider.problem, contains('already added'));
      expect(provider.rows, hasLength(2), reason: 'no rows were doubled');
      expect(engine.released, <String>['f2']);
    });

    test('a file with no transactions says its layout is unsupported',
        () async {
      final FakeEngine engine =
          FakeEngine(reviewing((_) => statement('s1', rows: 0)));
      final StatementImportProvider provider = providerFor(engine);

      await provider.addFile();
      expect(provider.problem, contains('not supported'));
      expect(provider.hasRows, isFalse);
    });

    test('an unreadable file reports the reader message', () async {
      final FakeEngine engine = FakeEngine(reviewing((_) =>
          throw const StatementEngineException(
              'unsupported', 'This file is not a supported statement.')));
      final StatementImportProvider provider = providerFor(engine);

      await provider.addFile();
      expect(provider.problem, contains('not a supported statement'));
      expect(engine.released, <String>['f1']);
    });

    test('recorded movements are passed to the duplicate check', () async {
      ledger.recorded = <LedgerEntry>[
        LedgerEntry(
          id: 'l1',
          userId: 'u1',
          accountId: 'a1',
          direction: LedgerDirection.debit,
          amount: 5000,
          txnDate: DateTime(2026, 9, 3),
          creditCardId: 'c1',
        ),
      ];
      final FakeEngine engine = FakeEngine(reviewing((_) => statement('s1')));
      final StatementImportProvider provider = providerFor(engine);

      await provider.addFile();
      final List<Object?> existing =
          engine.argsOf('review').single['existing']! as List<Object?>;
      expect(existing.single, <String, Object?>{
        'accountId': 'a1',
        'date': '2026-09-03',
        'amount': 5000.0,
        'direction': 'debit',
        'description': null,
        'creditCardId': 'c1',
      });
      expect(provider.checkFailed, isFalse);
    });

    test('a failed duplicate check holds the import until a retry works',
        () async {
      ledger.failFetch = true;
      final FakeEngine engine = FakeEngine(<String,
          Object? Function(Map<String, Object?>)>{
        ...reviewing((_) => statement('s1')),
        'recheck': (Map<String, Object?> a) => a['items'],
      });
      final StatementImportProvider provider = providerFor(engine);

      await provider.addFile();
      expect(provider.hasRows, isTrue);
      expect(provider.checkFailed, isTrue);

      ledger.failFetch = false;
      await provider.recheck();
      expect(provider.checkFailed, isFalse);
    });
  });

  group('importing', () {
    Future<StatementImportProvider> ready(
      FakeEngine engine,
    ) async {
      final StatementImportProvider provider = providerFor(engine);
      await provider.addFile();
      return provider;
    }

    test('nothing to import is said, not attempted', () async {
      final FakeEngine engine = FakeEngine(<String,
          Object? Function(Map<String, Object?>)>{
        ...reviewing((_) => statement('s1')),
        'plan': (_) => <String, Object?>{
              'operations': <Object?>[],
              'skipped': <Object?>[
                <String, Object?>{'reason': 'Already recorded'},
              ],
            },
      });
      final StatementImportProvider provider = await ready(engine);

      expect(await provider.preview(paymentMethods: const []), isNull);
      expect(provider.problem, contains('already recorded'));
      expect(expenses.created, isEmpty);
    });

    test('writes each planned row through the normal paths — a card bill is '
        'one bank debit, never an expense', () async {
      final List<Object?> ops = <Object?>[
        op('expense'),
        op('income', direction: 'credit'),
        op('movement', card: 'c1'),
        op('movement', direction: 'credit'),
        op('movement'),
      ];
      final FakeEngine engine = FakeEngine(<String,
          Object? Function(Map<String, Object?>)>{
        ...reviewing((_) => statement('s1')),
        'plan': (_) => <String, Object?>{'operations': ops, 'skipped': <Object?>[]},
        // A row recorded since review began is left out.
        'finalPlan': (Map<String, Object?> a) => <String, Object?>{
              'operations': ops,
              'skipped': <Object?>[
                <String, Object?>{'reason': 'Recorded since review'},
              ],
            },
      });
      final StatementImportProvider provider = await ready(engine);

      final ImportPreview? plan =
          await provider.preview(paymentMethods: const []);
      expect(plan, isNotNull);
      expect(expenses.created, isEmpty, reason: 'nothing before confirming');

      final ImportOutcome? outcome = await provider.execute(plan!);
      expect(outcome, isNotNull);
      expect(outcome!.expenses, 1);
      expect(outcome.income, 1);
      expect(outcome.movements, 3);
      expect(outcome.skipped, 1);
      expect(outcome.failures, isEmpty);

      expect(expenses.created.single.bankAccountId, 'a1');
      expect(expenses.created.single.creditCardId, isNull);
      expect(expenses.created.single.amount, 1200.5);
      expect(income.created.single.bankAccountId, 'a1');
      expect(ledger.writes.map((Map<String, Object?> w) => w['type']),
          <String>['cardPayment', 'deposit', 'withdraw']);
      expect(ledger.writes.first['cardId'], 'c1');

      // The final check ran against freshly read rows.
      expect(engine.argsOf('finalPlan').single['fresh'], isA<List<Object?>>());
    });

    test('stops after repeated failures instead of failing every row',
        () async {
      expenses.failures = 10;
      final List<Object?> ops = <Object?>[
        for (int i = 0; i < 6; i++) op('expense'),
      ];
      final FakeEngine engine = FakeEngine(<String,
          Object? Function(Map<String, Object?>)>{
        ...reviewing((_) => statement('s1')),
        'plan': (_) => <String, Object?>{'operations': ops, 'skipped': <Object?>[]},
        'finalPlan': (_) => <String, Object?>{'operations': ops, 'skipped': <Object?>[]},
      });
      final StatementImportProvider provider = await ready(engine);

      final ImportOutcome outcome = (await provider
          .execute((await provider.preview(paymentMethods: const []))!))!;
      expect(outcome.written, 0);
      expect(outcome.failures, hasLength(3));
      expect(outcome.notAttempted, 3);
    });

    test('a failed fresh check stops the import before any write', () async {
      final FakeEngine engine = FakeEngine(<String,
          Object? Function(Map<String, Object?>)>{
        ...reviewing((_) => statement('s1')),
        'plan': (_) => <String, Object?>{
              'operations': <Object?>[op('expense')],
              'skipped': <Object?>[],
            },
      });
      final StatementImportProvider provider = await ready(engine);
      final ImportPreview plan =
          (await provider.preview(paymentMethods: const []))!;

      ledger.failFetch = true;
      expect(await provider.execute(plan), isNull);
      expect(provider.problem, contains('could not start'));
      expect(expenses.created, isEmpty);
    });
  });

  test('signing out closes every open file and forgets the session', () async {
    final FakeEngine engine = FakeEngine(reviewing((_) => statement('s1')));
    final StatementImportProvider provider = providerFor(engine);
    await provider.addFile();

    provider.reset();
    expect(engine.released, <String>['f1']);
    expect(provider.hasRows, isFalse);
    expect(provider.account, isNull);
  });

  group('engine JSON', () {
    test('a card is described in the shape the web models use', () {
      const CreditCard card = CreditCard(
        id: 'c1',
        userId: 'u1',
        cardName: 'Travel',
        issuer: 'Test Bank',
        network: CardNetwork.visa,
        last4: '4821',
        creditLimit: 1000,
        statementDay: 15,
        paymentDueDay: 5,
      );
      expect(EngineJson.card(card), <String, Object?>{
        'id': 'c1',
        'userId': 'u1',
        'cardName': 'Travel',
        'issuer': 'Test Bank',
        'network': 'visa',
        'last4': '4821',
        'creditLimit': 1000.0,
        'openingOutstanding': 0.0,
        'statementDay': 15,
        'paymentDueDay': 5,
        'paymentAccountId': null,
        'isActive': true,
        'notes': null,
        'createdAt': null,
      });
    });

    test('an account keeps its digits for the account check', () {
      final Map<String, Object?> json = EngineJson.account(account);
      expect(json['last4'], '1234');
      expect(json['isActive'], isTrue);
    });
  });
}
