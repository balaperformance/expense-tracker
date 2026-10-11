// Statement reconciliation on the phone: what the provider reads, what it
// hands the shared engine, how decisions are kept, and the dashboard.
//
// The comparison itself is the web app's code, tested there; here the engine
// answers with test/fixtures/reconciliation.json — the real bundled engine's
// output for an invented September statement (3 matched, 2 missing, 1
// possible duplicate, 1 amount mismatch, balances ₹261 apart). Nothing
// touches a network or a database, and every figure is invented.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/models/bank_account.dart';
import 'package:expense_tracker/models/card_statement.dart';
import 'package:expense_tracker/models/credit_card.dart';
import 'package:expense_tracker/models/expense.dart';
import 'package:expense_tracker/models/income.dart';
import 'package:expense_tracker/models/ledger_entry.dart';
import 'package:expense_tracker/models/receivable.dart';
import 'package:expense_tracker/providers/reconciliation_provider.dart';
import 'package:expense_tracker/repositories/credit_card_repository.dart';
import 'package:expense_tracker/repositories/expense_repository.dart';
import 'package:expense_tracker/repositories/income_repository.dart';
import 'package:expense_tracker/repositories/ledger_repository.dart';
import 'package:expense_tracker/repositories/reconciliation_repository.dart';
import 'package:expense_tracker/screens/statement_import/reconcile_view.dart';
import 'package:expense_tracker/services/schema_capabilities.dart';
import 'package:expense_tracker/services/statement_import/statement_engine.dart';

final Map<String, Object?> fixture =
    (jsonDecode(File('test/fixtures/reconciliation.json').readAsStringSync()) as Map<String, dynamic>).cast<String, Object?>();

List<Map<String, Object?>> _maps(Object? list) =>
    (list! as List<Object?>).map((Object? m) => (m! as Map<String, dynamic>).cast<String, Object?>()).toList();

const BankAccount savings = BankAccount(id: 'a1', userId: 'u1', bankName: 'Test Bank', nickname: 'Savings', last4: '1234', openingBalance: 4000);

/// Answers the engine calls from the fixture and records each one.
class FakeEngine implements StatementEngine {
  final List<(String, Map<String, Object?>)> calls = <(String, Map<String, Object?>)>[];

  List<Map<String, Object?>> argsOf(String name) => <Map<String, Object?>>[
        for (final (String n, Map<String, Object?> a) in calls)
          if (n == name) a,
      ];

  @override
  Future<Object?> call(String name, Map<String, Object?> args) async {
    calls.add((name, args));
    switch (name) {
      case 'reconScopes':
        return fixture['scopes'];
      case 'reconcile':
        return fixture['output'];
      case 'withDecision':
        final Map<String, Object?> d = (args['decision']! as Map<String, Object?>);
        return <Object?>[
          for (final Map<String, Object?> e in (args['list']! as List<Object?>).cast<Map<String, Object?>>())
            if (e['itemKey'] != d['itemKey'] || e['action'] != d['action']) e,
          d,
        ];
      case 'withoutDecision':
        final Map<String, Object?> d = (args['decision']! as Map<String, Object?>);
        return <Object?>[
          for (final Map<String, Object?> e in (args['list']! as List<Object?>).cast<Map<String, Object?>>())
            if (e['itemKey'] != d['itemKey'] || e['action'] != d['action']) e,
        ];
    }
    throw StateError('unexpected call $name');
  }

  @override
  Future<PickedStatementFile?> pickFile() async => null;

  @override
  Future<void> release(String token) async {}
}

class FakeLedger extends LedgerRepository {
  FakeLedger(super.client);

  final List<String> windows = <String>[];
  List<LedgerEntry> entries = <LedgerEntry>[];

  @override
  Future<List<LedgerEntry>> fetchForAccount({required String userId, required String accountId, DateTime? from, DateTime? toExclusive}) async {
    windows.add('$accountId ${from?.toIso8601String().substring(0, 10)}..${toExclusive?.toIso8601String().substring(0, 10)}');
    return entries;
  }

  @override
  Future<double> netBefore({required String userId, required String accountId, required DateTime before}) async => 6000;
}

class FakeCards extends CreditCardRepository {
  FakeCards(super.client) : super(expenses: ExpenseRepository(client), ledger: LedgerRepository(client));

  int reads = 0;

  @override
  Future<List<CardEntry>> fetchEntries({required String userId, String? cardId}) async {
    reads++;
    return const <CardEntry>[];
  }
}

class FakeExpenses extends ExpenseRepository {
  FakeExpenses(super.client);

  int reads = 0;

  @override
  Future<List<Expense>> fetchRange({
    required String userId,
    required DateTime from,
    required DateTime toExclusive,
    Set<String> categoryIds = const <String>{},
    int limit = 0,
  }) async {
    reads++;
    return const <Expense>[];
  }
}

class FakeIncome extends IncomeRepository {
  FakeIncome(super.client);

  @override
  Future<List<Income>> fetchRange({required String userId, required DateTime from, required DateTime toExclusive, int limit = 0}) async =>
      const <Income>[];
}

class FakeDecisions extends ReconciliationRepository {
  FakeDecisions(super.client);

  final List<Map<String, Object?>> saved = <Map<String, Object?>>[];
  final List<Map<String, Object?>> removed = <Map<String, Object?>>[];
  List<Map<String, Object?>> stored = <Map<String, Object?>>[];
  bool fail = false;

  @override
  Future<List<Map<String, Object?>>> fetchDecisions({required String userId, required List<String> scopes}) async => stored;

  @override
  Future<void> saveDecision({required String userId, required Map<String, Object?> decision}) async {
    if (fail) throw StateError('offline');
    saved.add(decision);
  }

  @override
  Future<void> removeDecision({required String userId, required Map<String, Object?> decision}) async {
    if (fail) throw StateError('offline');
    removed.add(decision);
  }
}

void main() {
  late SupabaseClient client;
  late FakeEngine engine;
  late FakeLedger ledger;
  late FakeCards cards;
  late FakeExpenses expenses;
  late FakeDecisions decisions;
  late ReconciliationProvider recon;

  setUp(() {
    client = SupabaseClient('http://localhost:54321', 'test-anon-key', authOptions: const AuthClientOptions(autoRefreshToken: false));
    engine = FakeEngine();
    ledger = FakeLedger(client);
    cards = FakeCards(client);
    expenses = FakeExpenses(client);
    decisions = FakeDecisions(client);
    SchemaCapabilities.debugReset();
    SchemaCapabilities.debugOverride(bankAccounts: true, expenseBankLink: true, creditCards: true, treatments: true);
    recon = ReconciliationProvider(
      engine: engine,
      ledger: ledger,
      cards: cards,
      expenses: expenses,
      income: FakeIncome(client),
      decisions: decisions,
    );
  });

  tearDown(SchemaCapabilities.debugReset);

  Future<void> run({List<Map<String, Object?>>? items, List<ClaimSummary> claims = const <ClaimSummary>[], bool reload = false}) => recon.run(
        userId: 'u1',
        statements: _maps(fixture['statements']),
        items: items ?? _maps(fixture['items']),
        accounts: const <BankAccount>[savings],
        cards: const <CreditCard>[],
        claims: claims,
        currency: 'INR',
        reload: reload,
      );

  group('ReconciliationProvider', () {
    test('reads the ledger around the period and the balance before it, then compares', () async {
      ledger.entries = <LedgerEntry>[
        LedgerEntry(id: 'l1', userId: 'u1', accountId: 'a1', direction: LedgerDirection.debit, amount: 800, txnDate: DateTime(2026, 9, 12), expenseId: 'x1'),
      ];
      final Receivable lent = Receivable.fromMap(<String, dynamic>{
        'id': 'r1',
        'user_id': 'u1',
        'kind': 'reimbursable',
        'person': 'Ravi',
        'ledger_entry_id': null,
        'expense_id': 'x1',
        'due_date': null,
        'note': null,
        'created_at': null,
      });
      await run(claims: <ClaimSummary>[
        ClaimSummary(receivable: lent, source: null, principal: 800, received: 0, outstanding: 800, status: ClaimStatus.open, repayments: const <ClaimRepayment>[], overdue: false),
      ]);

      expect(ledger.windows, <String>['a1 2026-08-18..2026-10-15']);
      final Map<String, Object?> args = engine.argsOf('reconcile').single;
      final Map<String, Object?> account = _maps(args['accounts']).single;
      // The opening balance plus everything before 1 Sep.
      expect(account['opening'], 10000);
      final Map<String, Object?> entry = _maps(account['entries']).single;
      expect(entry['claim'], <String, Object?>{'receivableId': 'r1', 'person': 'Ravi', 'role': 'source'});
      expect((args['labels']! as Map<String, Object?>)['accounts'], <String, String>{'a1': savings.displayLabel});

      expect(recon.count('matched'), 3);
      expect(recon.count('open'), 4);
      expect(recon.scopes.single.headline, contains('₹261.00 lower'));
      expect(recon.scopes.single.agrees, isFalse);
      expect(recon.tileOrder.first, 'matched');
      expect(recon.statusMark('missing'), '🔴');
    });

    test('compares again without reading again until the periods change or a reload is asked for', () async {
      await run();
      await run(items: List<Map<String, Object?>>.of(_maps(fixture['items'])));
      expect(ledger.windows, hasLength(1));
      expect(expenses.reads, 1);
      expect(engine.argsOf('reconcile'), hasLength(2));
      await run(reload: true);
      expect(ledger.windows, hasLength(2));
    });

    test('filters by status, type and date like the web', () async {
      await run();
      expect(recon.filtered(const ReconFilter()).map((ReconItem i) => i.issue).toSet(), <String>{'notInApp', 'notOnStatement', 'amount', 'appDuplicate'});
      expect(recon.filtered(const ReconFilter(status: 'missing')), hasLength(2));
      expect(recon.filtered(const ReconFilter(status: 'matched')), hasLength(3));
      expect(recon.filtered(const ReconFilter(status: null, kind: 'income')).single.name, 'ACME Payroll');
      expect(recon.filtered(ReconFilter(status: null, from: DateTime(2026, 9, 15), to: DateTime(2026, 9, 17))).map((ReconItem i) => i.name), <String>['Groceries', 'Netflix']);
      final ReconItem zomato = recon.items.firstWhere((ReconItem i) => i.issue == 'amount');
      expect(zomato.difference, 90);
      expect(zomato.explanation, contains('₹90.00 more on the statement'));
      expect(zomato.movement?['id'], 'l3');
    });

    test('before migration 015, decisions live in memory and never reach the database', () async {
      await run();
      final ReconItem netflix = recon.items.firstWhere((ReconItem i) => i.issue == 'notInApp');
      final bool ok = await recon.decide(<String, Object?>{'scope': netflix.scope, 'itemKey': netflix.key, 'action': 'dismiss', 'entryId': null});
      expect(ok, isTrue);
      expect(decisions.saved, isEmpty);
      final List<Map<String, Object?>> sent = _maps(engine.argsOf('reconcile').last['decisions']);
      expect(sent.single['itemKey'], netflix.key);
    });

    test('with migration 015, a decision is saved — and taken back if saving fails', () async {
      SchemaCapabilities.debugOverride(reconciliation: true);
      decisions.stored = <Map<String, Object?>>[];
      await run();
      final ReconItem chai = recon.items.firstWhere((ReconItem i) => i.issue == 'appDuplicate');
      final Map<String, Object?> decision = <String, Object?>{'scope': chai.scope, 'itemKey': chai.key, 'action': 'dismiss', 'entryId': null};
      expect(await recon.decide(decision), isTrue);
      expect(decisions.saved, <Map<String, Object?>>[decision]);

      decisions.fail = true;
      expect(await recon.undo(decision), isFalse);
      // The failed undo left the decision in place.
      expect(_maps(engine.argsOf('reconcile').last['decisions']).single['itemKey'], chai.key);
      expect(recon.errorMessage, isNotNull);
    });
  });

  group('ReconcileView', () {
    Future<void> pump(WidgetTester tester, {void Function(String)? onAdd}) async {
      await run();
      await tester.pumpWidget(ChangeNotifierProvider<ReconciliationProvider>.value(
        value: recon,
        child: MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: ReconcileView(
              currency: 'INR',
              onAddToApp: onAdd,
              onOpen: (_) async {},
              onRefresh: () async {},
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('shows the five groups, the balance check and what to resolve', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(360 * 3, 720 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await pump(tester);

      expect(find.text('4 discrepancies to resolve'), findsOneWidget);
      expect(find.text('✅ Matched'), findsOneWidget);
      expect(find.text('🔴 Missing'), findsOneWidget);
      expect(find.text('🟠 Possible duplicates'), findsOneWidget);
      expect(find.text('🟡 Mismatches'), findsOneWidget);
      expect(find.text('🔵 To review'), findsOneWidget);
      expect(find.textContaining('₹261.00 lower'), findsOneWidget);
      expect(find.text('Savings ••1234'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.scrollUntilVisible(find.text('Netflix'), 200, scrollable: find.byType(Scrollable).first);
      await tester.scrollUntilVisible(find.text('Zomato'), 200, scrollable: find.byType(Scrollable).first);
      expect(find.textContaining('+₹90.00 diff'), findsOneWidget);
      // Matches are not listed until asked for.
      expect(find.text('ACME Payroll'), findsNothing);
    });

    testWidgets('a discrepancy opens beside what it was compared to, and can be accepted', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(360 * 3, 720 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      String? added;
      await pump(tester, onAdd: (String id) => added = id);

      await tester.scrollUntilVisible(find.text('Netflix'), 200, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('Netflix'));
      await tester.pumpAndSettle();
      expect(find.text('Not in the app'), findsWidgets);
      expect(find.textContaining("isn't recorded in the app"), findsOneWidget);
      expect(find.text('ON THE STATEMENT'), findsOneWidget);
      expect(find.text('Not recorded'), findsOneWidget);

      await tester.tap(find.text('Add to app'));
      await tester.pumpAndSettle();
      expect(added, 's:4');

      await tester.scrollUntilVisible(find.text('Zomato'), 200, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('Zomato'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Accept as it is'));
      await tester.tap(find.text('Accept as it is'));
      await tester.pumpAndSettle();
      final Map<String, Object?> decision = engine.argsOf('withDecision').single['decision']! as Map<String, Object?>;
      expect(decision['action'], 'dismiss');
      expect(decision['itemKey'], recon.items.firstWhere((ReconItem i) => i.issue == 'amount').key);
    });
  });
}
