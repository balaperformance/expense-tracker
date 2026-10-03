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
import 'package:expense_tracker/repositories/tag_repository.dart';
import 'package:expense_tracker/services/schema_capabilities.dart';
import 'package:expense_tracker/services/statement_import/statement_engine.dart';

const BankAccount account = BankAccount(
  id: 'a1',
  userId: 'u1',
  bankName: 'Test Bank',
  nickname: 'Savings',
  last4: '1234',
);

const BankAccount salary = BankAccount(
  id: 'a2',
  userId: 'u1',
  bankName: 'Other Bank',
  nickname: 'Salary',
  last4: '5678',
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
  final List<String> fetchedAccounts = <String>[];
  final List<Map<String, Object?>> writes = <Map<String, Object?>>[];
  Set<String> lent = <String>{};

  @override
  Future<List<LedgerEntry>> fetchForAccount({
    required String userId,
    required String accountId,
    DateTime? from,
    DateTime? toExclusive,
  }) async {
    if (failFetch) throw StateError('offline');
    fetchedAccounts.add(accountId);
    return recorded.where((LedgerEntry e) => e.accountId == accountId).toList();
  }

  @override
  Future<Set<String>> fetchLentEntryIds({required String userId}) async => lent;

  @override
  Future<void> recordCardPayment({
    required String userId,
    required String accountId,
    required String cardId,
    required double amount,
    required DateTime date,
    required String description,
    MovementDetails? details,
  }) async =>
      writes.add(<String, Object?>{
        'type': 'cardPayment',
        'accountId': accountId,
        'cardId': cardId,
        'amount': amount,
        'reference': details?.reference,
      });

  @override
  Future<LedgerEntry> recordMovement({
    required String userId,
    required String accountId,
    required LedgerDirection direction,
    required double amount,
    required DateTime date,
    String? description,
    MovementDetails? details,
  }) async {
    writes.add(<String, Object?>{
      'type': 'movement:${direction.wire}',
      'accountId': accountId,
      'amount': amount,
      'reference': details?.reference,
    });
    return LedgerEntry(
      id: 'l${writes.length}',
      userId: userId,
      accountId: accountId,
      direction: direction,
      amount: amount,
      txnDate: date,
    );
  }

  @override
  Future<void> recordTransferPair({
    required String userId,
    required String accountId,
    required String counterpartyAccountId,
    required LedgerDirection direction,
    required double amount,
    required DateTime date,
    required String description,
    required String counterpartDescription,
    MovementDetails? details,
  }) async =>
      writes.add(<String, Object?>{
        'type': 'transferPair',
        'accountId': accountId,
        'counterpartyAccountId': counterpartyAccountId,
        'direction': direction.wire,
        'counterpartDescription': counterpartDescription,
        'reference': details?.reference,
      });

  @override
  Future<String> recordBankMovement({
    required String accountId,
    required LedgerDirection direction,
    required double amount,
    required DateTime date,
    required String description,
    required Map<String, Object?> treatment,
  }) async {
    writes.add(<String, Object?>{
      'type': 'bankMovement',
      'accountId': accountId,
      'direction': direction.wire,
      'treatment': treatment,
    });
    return 'saved-${writes.length}';
  }

  @override
  Future<void> setMovementDetails({
    required String userId,
    required String entryId,
    required MovementDetails details,
  }) async =>
      writes.add(<String, Object?>{
        'type': 'details',
        'entryId': entryId,
        'reference': details.reference,
        'upiId': details.upiId,
        'time': details.time,
      });
}

class RecordingExpenses extends ExpenseRepository {
  RecordingExpenses(super.client);

  final List<Expense> created = <Expense>[];
  final List<MovementDetails?> details = <MovementDetails?>[];
  int failures = 0;

  @override
  Future<Expense> create(Expense expense, {MovementDetails? details}) async {
    if (failures > 0) {
      failures--;
      throw StateError('write failed');
    }
    created.add(expense);
    this.details.add(details);
    return Expense(
      id: 'e${created.length}',
      userId: expense.userId,
      amount: expense.amount,
      expenseDate: expense.expenseDate,
      categoryId: expense.categoryId,
      bankAccountId: expense.bankAccountId,
      notes: expense.notes,
    );
  }
}

class RecordingIncome extends IncomeRepository {
  RecordingIncome(super.client);

  final List<Income> created = <Income>[];
  final List<MovementDetails?> details = <MovementDetails?>[];

  @override
  Future<Income> create(Income income, {MovementDetails? details}) async {
    created.add(income);
    this.details.add(details);
    return Income(
      id: 'i${created.length}',
      userId: income.userId,
      amount: income.amount,
      incomeDate: income.incomeDate,
      bankAccountId: income.bankAccountId,
    );
  }
}

class RecordingTags extends TagRepository {
  RecordingTags(super.client);

  final List<(TagKind, String, List<String>)> sets =
      <(TagKind, String, List<String>)>[];
  bool fail = false;

  @override
  Future<void> setTags({
    required TagKind kind,
    required String id,
    required List<String> names,
  }) async {
    if (fail) throw StateError('tags failed');
    sets.add((kind, id, names));
  }
}

Map<String, Object?> statement(
  String id, {
  int rows = 2,
  bool accountPerRow = false,
  List<String>? accounts,
}) =>
    <String, Object?>{
      'statement': <String, Object?>{
        'id': id,
        'fileName': 'statement.pdf',
        'period': <String, Object?>{'from': '2026-09-01', 'to': '2026-09-30'},
        'accountPerRow': accountPerRow,
        'transactions': <Object?>[
          for (int i = 0; i < rows; i++)
            <String, Object?>{
              'id': '$id:$i',
              'bankAccountId': accounts == null ? 'a1' : accounts[i],
            },
        ],
        'warnings': <Object?>[],
      },
      'periodLabel': 'Monthly · 1 Sep – 30 Sep 2026',
      'accountMismatch': false,
    };

Map<String, Object?> row(String id,
        {bool selected = true, String bankAccountId = 'a1'}) =>
    <String, Object?>{
      'id': id,
      'transactionDate': '2026-09-10',
      'amount': 100,
      'transactionType': 'debit',
      'kind': 'expense',
      'selected': selected,
      'bankAccountId': bankAccountId,
    };

Map<String, Object?> op(
  String type, {
  String? card,
  String direction = 'debit',
  String account = 'a1',
  Map<String, Object?>? details,
  List<String>? tags,
  String itemId = 'item',
  Map<String, Object?>? extra,
}) =>
    <String, Object?>{
      'type': type,
      'itemId': itemId,
      'bankAccountId': account,
      'amount': 1200.5,
      'date': '2026-09-10',
      'description': 'Row',
      'direction': direction,
      if (card != null) 'creditCardId': card,
      if (details != null) 'details': details,
      if (tags != null) 'tags': tags,
      ...?extra,
    };

/// The engine's counting of what was written, for the outcome.
Map<String, Object?> countsOf(Map<String, Object?> args) {
  final List<Object?> ops = args['operations']! as List<Object?>;
  int n(String type) =>
      ops.where((Object? o) => (o! as Map<String, Object?>)['type'] == type).length;
  return <String, Object?>{
    'expenses': n('expense'),
    'income': n('income'),
    'movements': n('movement'),
    'transfers': n('transfer') + n('treatment'),
    'paidFor': 0,
    'lent': 0,
    'repaid': 0,
  };
}

void main() {
  late SupabaseClient client;
  late RecordingLedger ledger;
  late RecordingExpenses expenses;
  late RecordingIncome income;
  late RecordingTags tags;

  setUp(() {
    client = SupabaseClient(
      'http://localhost:54321',
      'test-anon-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    ledger = RecordingLedger(client);
    expenses = RecordingExpenses(client);
    income = RecordingIncome(client);
    tags = RecordingTags(client);
    SchemaCapabilities.debugReset();
  });

  tearDown(SchemaCapabilities.debugReset);

  StatementImportProvider providerFor(FakeEngine engine) {
    final StatementImportProvider provider = StatementImportProvider(
      engine: engine,
      expenses: expenses,
      income: income,
      ledger: ledger,
      tags: tags,
    );
    provider.begin(
      userId: 'u1',
      account: account,
      accounts: const <BankAccount>[account, salary],
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
                row(
                  (t! as Map<String, Object?>)['id']! as String,
                  bankAccountId: (t as Map<String, Object?>)['bankAccountId']
                          as String? ??
                      'a1',
                ),
            ],
        'view': (Map<String, Object?> args) => <String, Object?>{
              'summary': <String, Object?>{
                'selected': (args['items']! as List<Object?>).length,
              },
              'rows': <Object?>[],
            },
        'autoMatchWindows': (_) => <Object?>[],
        'counts': countsOf,
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

    test('a recorded UPI reference reaches the duplicate check', () async {
      ledger.recorded = <LedgerEntry>[
        LedgerEntry(
          id: 'l1',
          userId: 'u1',
          accountId: 'a1',
          direction: LedgerDirection.debit,
          amount: 249,
          txnDate: DateTime(2026, 9, 12),
          reference: '600012345678',
          upiId: 'cafe@upi',
        ),
      ];
      final FakeEngine engine = FakeEngine(reviewing((_) => statement('s1')));
      final StatementImportProvider provider = providerFor(engine);

      await provider.addFile();
      final Map<String, Object?> existing = (engine
              .argsOf('review')
              .single['existing']! as List<Object?>)
          .single! as Map<String, Object?>;
      expect(existing['reference'], '600012345678');
      expect(existing['upiId'], 'cafe@upi');
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

  group('a statement covering several accounts (Paytm)', () {
    test('checks for duplicates on every account its rows name', () async {
      final FakeEngine engine = FakeEngine(reviewing((_) => statement('p1',
          rows: 3, accountPerRow: true, accounts: <String>['a2', 'a2', ''])));
      final StatementImportProvider provider = providerFor(engine);

      await provider.addFile();
      expect(provider.multiAccount, isTrue);
      expect(ledger.fetchedAccounts.toSet(), <String>{'a1', 'a2'},
          reason: 'the upload account and every account named; an unmatched '
              'row has none to check');
      expect(provider.rows.map((ImportRow r) => r.bankAccountId),
          <String>['a2', 'a2', '']);
    });

    test('a row moved to another account is checked again on it', () async {
      final FakeEngine engine = FakeEngine(<String,
          Object? Function(Map<String, Object?>)>{
        ...reviewing((_) => statement('p1',
            rows: 1, accountPerRow: true, accounts: <String>[''])),
        'reduce': (Map<String, Object?> a) => <Object?>[
              row('p1:0', bankAccountId: 'a2'),
            ],
        'recheck': (Map<String, Object?> a) => a['items'],
      });
      final StatementImportProvider provider = providerFor(engine);
      await provider.addFile();
      ledger.fetchedAccounts.clear();

      await provider.edit('p1:0', <String, Object?>{'bankAccountId': 'a2'});
      expect(engine.argsOf('recheck'), hasLength(1));
      expect(ledger.fetchedAccounts.toSet(), <String>{'a1', 'a2'});
      expect(provider.checkFailed, isFalse);

      // When that check fails, importing waits — quietly, without an error.
      ledger.failFetch = true;
      await provider.edit('p1:0', <String, Object?>{'bankAccountId': 'a2'});
      expect(provider.checkFailed, isTrue);
      expect(provider.problem, isNull);
    });

    test('the phone offers only the kinds it can record', () async {
      final FakeEngine engine = FakeEngine(<String,
          Object? Function(Map<String, Object?>)>{
        ...reviewing((_) => statement('s1')),
        'kindsFor': (Map<String, Object?> a) => <Object?>['expense', 'transfer'],
      });
      final StatementImportProvider provider = providerFor(engine);

      expect(await provider.kindsFor(true), <String>['expense', 'transfer']);
      expect(engine.argsOf('kindsFor').single,
          <String, Object?>{'type': 'debit', 'treatments': false});
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

    test('plans with what the database can store, as the web import does',
        () async {
      SchemaCapabilities.debugOverride(
        treatments: true,
        transfers: true,
        statementDetails: true,
        tags: false,
      );
      final FakeEngine engine = FakeEngine(<String,
          Object? Function(Map<String, Object?>)>{
        ...reviewing((_) => statement('s1')),
        'plan': (_) => <String, Object?>{
              'operations': <Object?>[op('expense')],
              'skipped': <Object?>[],
            },
      });
      final StatementImportProvider provider = await ready(engine);

      await provider.preview(paymentMethods: const []);
      expect(engine.argsOf('plan').single['options'], <String, Object?>{
        'linkAccounts': true,
        'pairAccounts': true,
        'storeDetails': true,
        'storeTags': false,
        'accountNames': <String, String>{'a1': 'Savings', 'a2': 'Salary'},
      });
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
          <String>['cardPayment', 'movement:credit', 'movement:debit']);
      expect(ledger.writes.first['cardId'], 'c1');

      // The final check ran against freshly read rows.
      expect(engine.argsOf('finalPlan').single['fresh'], isA<List<Object?>>());
    });

    test('writes each row into its own account, and tags and UPI details with it',
        () async {
      final Map<String, Object?> details = <String, Object?>{
        'reference': '600012345678',
        'upiId': 'cafe@upi',
        'time': '13:05',
      };
      final List<Object?> ops = <Object?>[
        op('expense', account: 'a2', details: details, tags: <String>['food', 'office']),
        op('income', direction: 'credit', tags: <String>['refund']),
        op('movement', direction: 'credit', account: 'a2', details: details),
      ];
      final FakeEngine engine = FakeEngine(<String,
          Object? Function(Map<String, Object?>)>{
        ...reviewing((_) => statement('p1',
            accountPerRow: true, accounts: <String>['a2', 'a1'])),
        'plan': (_) => <String, Object?>{'operations': ops, 'skipped': <Object?>[]},
        'finalPlan': (_) => <String, Object?>{'operations': ops, 'skipped': <Object?>[]},
      });
      SchemaCapabilities.debugOverride(tags: true, statementDetails: true);
      final StatementImportProvider provider = await ready(engine);
      ledger.fetchedAccounts.clear();

      final ImportOutcome outcome = (await provider
          .execute((await provider.preview(paymentMethods: const []))!))!;
      expect(outcome.written, 3);
      expect(outcome.partial, 0);

      // The final check read both accounts written to.
      expect(ledger.fetchedAccounts.toSet(), <String>{'a1', 'a2'});

      expect(expenses.created.single.bankAccountId, 'a2');
      expect(expenses.details.single?.reference, '600012345678');
      expect(expenses.details.single?.upiId, 'cafe@upi');
      expect(expenses.details.single?.time, '13:05');
      expect(income.details.single, isNull);
      expect(ledger.writes.single['reference'], '600012345678');

      expect(
        tags.sets.map(((TagKind, String, List<String>) s) =>
            '${s.$1.wire} ${s.$2}: ${s.$3.join(', ')}'),
        <String>['expense e1: food, office', 'income i1: refund'],
      );
    });

    test('a row whose tags could not be saved is kept, and reported', () async {
      tags.fail = true;
      SchemaCapabilities.debugOverride(tags: true);
      final List<Object?> ops = <Object?>[
        op('expense', tags: <String>['food']),
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
      expect(outcome.expenses, 1);
      expect(outcome.partial, 1);
      expect(outcome.failures, isEmpty);
    });

    test('a transfer to another of your accounts links the other leg when one '
        'is already there', () async {
      final Map<String, Object?> request = <String, Object?>{
        'kind': 'transfer',
        'direction': 'debit',
        'transferTarget': <String, Object?>{'type': 'account', 'accountId': 'a2'},
        'counterpartDescription': 'Transfer from Savings',
      };
      final List<Object?> ops = <Object?>[
        op('treatment',
            itemId: 't1',
            details: <String, Object?>{'reference': '600099990000'},
            extra: <String, Object?>{'request': request, 'autoMatch': true}),
      ];
      ledger.recorded = <LedgerEntry>[
        LedgerEntry(
          id: 'other-leg',
          userId: 'u1',
          accountId: 'a2',
          direction: LedgerDirection.credit,
          amount: 1200.5,
          txnDate: DateTime(2026, 9, 11),
        ),
      ];
      ledger.lent = <String>{'lent-1'};
      final FakeEngine engine = FakeEngine(<String,
          Object? Function(Map<String, Object?>)>{
        ...reviewing((_) => statement('s1')),
        'plan': (_) => <String, Object?>{'operations': ops, 'skipped': <Object?>[]},
        'finalPlan': (_) => <String, Object?>{'operations': ops, 'skipped': <Object?>[]},
        'autoMatchWindows': (_) => <Object?>[
              <String, Object?>{
                'accountId': 'a2',
                'from': '2026-09-07',
                'toExclusive': '2026-09-14',
              },
            ],
        'autoMatches': (Map<String, Object?> a) =>
            <String, Object?>{'t1': 'other-leg'},
        'treatmentPayload': (Map<String, Object?> a) => <String, Object?>{
              'type': 'transfer',
              'counterparty_account_id': 'a2',
              if (a['matchEntryId'] != null) 'match_entry_id': a['matchEntryId'],
            },
      });
      final StatementImportProvider provider = await ready(engine);

      final ImportOutcome outcome = (await provider
          .execute((await provider.preview(paymentMethods: const []))!))!;
      expect(outcome.transfers, 1);
      expect(outcome.failures, isEmpty);

      // The other account's rows went to the engine in the web model's shape.
      final List<Object?> entries =
          engine.argsOf('autoMatches').single['entries']! as List<Object?>;
      expect((entries.single! as Map<String, Object?>)['id'], 'other-leg');
      expect((entries.single! as Map<String, Object?>)['claim'], isNull);

      expect(engine.argsOf('treatmentPayload').single['matchEntryId'], 'other-leg');
      expect(ledger.writes.map((Map<String, Object?> w) => w['type']),
          <String>['bankMovement', 'details']);
      expect(ledger.writes.first['treatment'], <String, Object?>{
        'type': 'transfer',
        'counterparty_account_id': 'a2',
        'match_entry_id': 'other-leg',
      });
      expect(ledger.writes.last['reference'], '600099990000');
    });

    test('without migration 005 a transfer is written as both legs at once',
        () async {
      final List<Object?> ops = <Object?>[
        op('transfer',
            extra: <String, Object?>{
              'counterpartyAccountId': 'a2',
              'counterpartDescription': 'Transfer from Savings',
            }),
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
      expect(outcome.transfers, 1);
      expect(ledger.writes.single, <String, Object?>{
        'type': 'transferPair',
        'accountId': 'a1',
        'counterpartyAccountId': 'a2',
        'direction': 'debit',
        'counterpartDescription': 'Transfer from Savings',
        'reference': null,
      });
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

    test('money lent is never taken for a plain movement', () {
      final LedgerEntry entry = LedgerEntry(
        id: 'l9',
        userId: 'u1',
        accountId: 'a2',
        direction: LedgerDirection.debit,
        amount: 500,
        txnDate: DateTime(2026, 9, 2),
      );
      expect(EngineJson.ledgerEntry(entry)['claim'], isNull);
      expect(EngineJson.ledgerEntry(entry, lent: true)['claim'],
          isA<Map<String, Object?>>());
      expect(EngineJson.ledgerEntry(entry)['txnDate'], '2026-09-02');
    });
  });

  group('statement details', () {
    test('are cleaned exactly as the web app writes them', () {
      const MovementDetails details = MovementDetails(
        reference: ' 600012345678 ',
        upiId: 'ab',
        time: '13:05',
      );
      expect(details.toColumns(), <String, dynamic>{
        'reference': '600012345678',
        'upi_id': null,
        'txn_time': '13:05',
      });
      expect(MovementDetails.fromJson(<String, Object?>{'reference': null}), isNull);
      expect(MovementDetails.fromJson(null), isNull);
    });
  });
}
