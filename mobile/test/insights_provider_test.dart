// The Reports provider: what it hands the shared insights engine, and how it
// copes when the engine is missing or has forgotten the loaded history.
//
// Nothing here reaches the network: the repositories are fakes and the engine
// answers from a script.

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:expense_tracker/models/credit_card.dart';
import 'package:expense_tracker/models/expense_category.dart';
import 'package:expense_tracker/models/ledger_entry.dart';
import 'package:expense_tracker/models/tag.dart';
import 'package:expense_tracker/providers/insights_provider.dart';
import 'package:expense_tracker/repositories/credit_card_repository.dart';
import 'package:expense_tracker/repositories/expense_repository.dart';
import 'package:expense_tracker/repositories/income_repository.dart';
import 'package:expense_tracker/repositories/ledger_repository.dart';
import 'package:expense_tracker/repositories/tag_repository.dart';
import 'package:expense_tracker/services/statement_import/statement_engine.dart';

class ScriptedEngine implements StatementEngine {
  ScriptedEngine(this.answer);

  final Object? Function(String name, Map<String, Object?> args) answer;
  final List<(String, Map<String, Object?>)> calls = <(String, Map<String, Object?>)>[];

  @override
  Future<Object?> call(String name, Map<String, Object?> args) async {
    calls.add((name, args));
    return answer(name, args);
  }

  @override
  Future<PickedStatementFile?> pickFile() async => null;

  @override
  Future<void> release(String token) async {}

  List<String> get names => <String>[for (final (String n, _) in calls) n];

  Map<String, Object?> firstArgs(String name) => calls.firstWhere(((String, Map<String, Object?>) c) => c.$1 == name).$2;
}

class History extends ExpenseRepository {
  History(super.client);

  @override
  Future<List<Map<String, dynamic>>> fetchHistoryRows({
    required String userId,
    required DateTime from,
    required DateTime toExclusive,
  }) async =>
      <Map<String, dynamic>>[
        <String, dynamic>{'id': 'e1', 'amount': 649, 'expense_date': '2026-09-12', 'category_id': 'c1', 'merchant': 'Netflix'},
        <String, dynamic>{'id': 'e2', 'amount': 1200, 'expense_date': '2026-09-20', 'category_id': 'gone'},
      ];

  @override
  Future<Set<String>> fetchPaidForExpenseIds({required String userId}) async => <String>{'e2'};
}

class NoIncome extends IncomeRepository {
  NoIncome(super.client);

  @override
  Future<Map<String, double>> fetchMonthlyTotals({
    required String userId,
    required DateTime from,
    required DateTime toExclusive,
  }) async =>
      <String, double>{'2026-09': 80000};
}

class Tags extends TagRepository {
  Tags(super.client);

  @override
  Future<List<Tag>> fetchTags(String userId) async => const <Tag>[Tag(id: 't1', name: 'family')];

  @override
  Future<Map<String, List<String>>> fetchExpenseTagLinks(String userId) async =>
      const <String, List<String>>{
        'e1': <String>['t1', 't2'],
      };
}

CardTransaction charge(String id, CardTransactionKind kind, LedgerDirection direction, double amount) => CardTransaction(
      id: id,
      userId: 'u1',
      cardId: 'card',
      kind: kind,
      direction: direction,
      amount: amount,
      txnDate: DateTime(2026, 9, 1),
    );

class Charges extends CreditCardRepository {
  Charges(super.client, {required super.expenses, required super.ledger});

  @override
  Future<List<CardTransaction>> fetchCharges({required String userId, required DateTime from}) async => <CardTransaction>[
        charge('fee', CardTransactionKind.fee, LedgerDirection.debit, 500),
        // A fee credited back reverses one.
        charge('waived', CardTransactionKind.fee, LedgerDirection.credit, 200),
        charge('refund', CardTransactionKind.refund, LedgerDirection.credit, 300),
        // A refund that is a debit is not money back.
        charge('odd', CardTransactionKind.refund, LedgerDirection.debit, 50),
      ];
}

Map<String, Object?> overview(String session) => <String, Object?>{
      'session': session,
      'today': '2026-10-05',
      'since': '2024-09-05',
      'historyStart': '2026-09-12',
      'enoughData': true,
      'highlights': <Object?>[],
      'recurring': <Object?>[],
      'savings': <Object?>[],
      'unusual': <Object?>[],
      'changes': <String, Object?>{
        'current': <String, Object?>{'start': '2026-09-01', 'end': '2026-09-30', 'label': 'September 2026', 'short': 'Sep'},
        'previous': <String, Object?>{'start': '2026-08-01', 'end': '2026-08-31', 'label': 'August 2026', 'short': 'Aug'},
      },
      'presets': <Object?>[],
    };

void main() {
  late SupabaseClient client;
  setUp(() {
    client = SupabaseClient('http://localhost:54321', 'test-anon-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false));
  });

  InsightsProvider provider(StatementEngine engine) {
    final History expenses = History(client);
    return InsightsProvider(
      engine: engine,
      expenses: expenses,
      income: NoIncome(client),
      tags: Tags(client),
      cards: Charges(client, expenses: expenses, ledger: LedgerRepository(client)),
    );
  }

  const InsightsCatalog catalog = InsightsCatalog(
    categories: <ExpenseCategory>[
      ExpenseCategory(id: 'c1', userId: 'u1', name: 'Entertainment', icon: 'movie', color: '#6650A6'),
    ],
    paymentMethods: [],
    accounts: [],
    cards: [],
  );

  test('without the engine, Reports falls back to the month report', () async {
    final InsightsProvider insights = provider(ScriptedEngine((String name, _) {
      throw const StatementEngineException('engineUnavailable', 'Statement import is available in the Android app.');
    }));
    await insights.load(userId: 'u1', currency: 'INR', catalog: catalog);
    expect(insights.engineUnavailable, isTrue);
    expect(insights.hasError, isFalse);
  });

  test('hands the engine the history the web reads, with the web’s card-charge signs', () async {
    final ScriptedEngine engine = ScriptedEngine((String name, _) => name == 'insightsLoad' ? overview('s1') : <String, Object?>{});
    final InsightsProvider insights = provider(engine);
    await insights.load(userId: 'u1', currency: 'INR', catalog: catalog);

    expect(engine.names, containsAll(<String>['insightsLoad', 'insightsSpending', 'insightsAnalytics']));
    final Map<String, Object?> args = engine.firstArgs('insightsLoad');
    final List<Map<String, Object?>> expenses = (args['expenses']! as List<Object?>).cast<Map<String, Object?>>();
    expect(expenses.first['expenseDate'], '2026-09-12');
    expect(expenses.first['category'], <String, Object?>{'name': 'Entertainment'});
    // A category deleted since has no name to give.
    expect(expenses.last['category'], isNull);
    expect(args['paidFor'], <String>['e2']);
    expect(args['tagLinks'], <List<String>>[
      <String>['e1', 't1'],
      <String>['e1', 't2'],
    ]);
    final List<Map<String, Object?>> charges = (args['cardCharges']! as List<Object?>).cast<Map<String, Object?>>();
    expect(<String, Object?>{for (final Map<String, Object?> c in charges) c['id']! as String: c['amount']},
        <String, Object?>{'fee': 500.0, 'waived': -200.0, 'refund': 300.0});
    expect(args['income'], <String, double>{'2026-09': 80000});
    expect(insights.overview?.session, 's1');
  });

  test('reloads once when the engine has forgotten the history', () async {
    int loads = 0;
    bool expired = true;
    final ScriptedEngine engine = ScriptedEngine((String name, Map<String, Object?> args) {
      if (name == 'insightsLoad') return overview('s${++loads}');
      if (name == 'insightsSpending' && expired) {
        expired = false;
        throw const StatementEngineException('insightsExpired', 'The report needs to be loaded again.');
      }
      return <String, Object?>{};
    });
    final InsightsProvider insights = provider(engine);
    await insights.load(userId: 'u1', currency: 'INR', catalog: catalog);
    expect(loads, 2);
    // The retried call goes to the reloaded history.
    final List<Map<String, Object?>> spending = <Map<String, Object?>>[
      for (final (String n, Map<String, Object?> a) in engine.calls)
        if (n == 'insightsSpending') a,
    ];
    expect(spending.map((Map<String, Object?> a) => a['session']), <Object?>['s1', 's2']);
    expect(insights.engineUnavailable, isFalse);
  });
}
