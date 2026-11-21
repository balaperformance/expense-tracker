// EMIs on bank accounts with a pending balance, deleting hashtags, and the
// tags typed during a statement import (migration 020). The pure rules —
// what is pending, which plans a reimbursement or an expense may use, which
// tags a row is offered — ported from the web app so both answer alike.
// Nothing touches a database.

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:expense_tracker/models/emi_plan.dart';
import 'package:expense_tracker/models/emi_reimbursement.dart';
import 'package:expense_tracker/models/credit_card.dart';
import 'package:expense_tracker/models/receivable.dart';
import 'package:expense_tracker/models/tag.dart';
import 'package:expense_tracker/models/tag_rules.dart';
import 'package:expense_tracker/providers/credit_card_provider.dart';
import 'package:expense_tracker/models/card_statement.dart';
import 'package:expense_tracker/models/bank_account.dart';
import 'package:expense_tracker/providers/statement_import_provider.dart';
import 'package:expense_tracker/repositories/credit_card_repository.dart';
import 'package:expense_tracker/repositories/income_repository.dart';
import 'package:expense_tracker/repositories/tag_repository.dart';
import 'package:expense_tracker/services/statement_import/statement_engine.dart';
import 'package:expense_tracker/repositories/emi_plan_repository.dart';
import 'package:expense_tracker/repositories/expense_repository.dart';
import 'package:expense_tracker/repositories/ledger_repository.dart';
import 'package:expense_tracker/services/schema_capabilities.dart';

String money(double v) => '₹${v.toStringAsFixed(0)}';

EmiPlan plan({
  String id = 'p1',
  String title = 'Home loan',
  String? cardId,
  String? bankAccountId = 'a1',
  double? pendingAmount,
  String? person,
  bool isClosed = false,
}) =>
    EmiPlan(
      id: id,
      userId: 'u1',
      cardId: cardId,
      title: title,
      person: person,
      bankAccountId: bankAccountId,
      pendingAmount: pendingAmount,
      isClosed: isClosed,
    );

void main() {
  group('pending balance', () {
    test('there is none without a pending amount', () {
      expect(pendingLeft(null, 0), isNull);
      expect(pendingLeft(null, 5000), isNull);
      expect(emiPendingText(null, money), isNull);
    });

    test('each month recorded comes off what is pending', () {
      expect(pendingLeft(120000, 0), 120000);
      expect(pendingLeft(120000, 10000), 110000);
      expect(pendingLeft(120000, 30000.5), 89999.5);
    });

    test('it never goes below zero, and zero is fully paid', () {
      expect(pendingLeft(10000, 12000), 0);
      expect(pendingLeft(0, 0), 0);
      expect(emiPendingText(0, money), 'Fully paid');
    });

    test('it is worked out in whole paise', () {
      // 0.1 + 0.2 style float noise must not leave a stray paisa.
      expect(pendingLeft(100.3, 0.1 + 0.2), 100.0);
    });

    test('the text names what is pending', () {
      expect(emiPendingText(36000, money), '₹36000 pending');
    });

    test('the database row reads into the plan and its balance', () {
      final EmiPlan p = EmiPlan.fromMap(<String, dynamic>{
        'id': 'p1',
        'user_id': 'u1',
        'card_id': null,
        'title': 'Car loan',
        'bank_account_id': 'a1',
        'pending_amount': '250000.50',
        'pending_set_at': '2026-11-01T08:30:00+00:00',
      });
      expect(p.cardId, isNull);
      expect(p.bankAccountId, 'a1');
      expect(p.pendingAmount, 250000.5);
      expect(p.pendingSetAt, DateTime.utc(2026, 11, 1, 8, 30));

      final EmiBalance b = EmiBalance.fromMap(<String, dynamic>{
        'plan_id': 'p1',
        'paid': 15000.25,
        'payments': 2,
      });
      expect(pendingLeft(p.pendingAmount, b.paid), 235000.25);
      expect(b.payments, 2);
    });
  });

  group('an EMI needs only a name', () {
    test('everything else is written as null', () {
      final Map<String, dynamic> map =
          const EmiPlan(id: '', userId: 'u1', title: 'Loan', bankAccountId: 'a1')
              .toWriteMap();
      expect(map['card_id'], isNull);
      expect(map['purchase_amount'], isNull);
      expect(map['monthly_amount'], isNull);
      expect(map['tenure_months'], isNull);
      expect(map['start_date'], isNull);
      expect(map['category_id'], isNull);
      expect(map['reference'], isNull);
      expect(map['pending_amount'], isNull);
      expect(map['bank_account_id'], 'a1');
    });

    test('a pending amount of zero is kept: nothing left to pay', () {
      expect(
        const EmiPlan(id: '', userId: 'u1', title: 'Loan', pendingAmount: 0)
            .toWriteMap()['pending_amount'],
        0,
      );
    });
  });

  group('which plans are offered', () {
    Future<CreditCardProvider> provider(List<EmiPlan> plans) =>
        loaded(plans, const <String, EmiBalance>{});

    test('an expense is offered open plans nobody else pays', () async {
      final CreditCardProvider cards = await provider(<EmiPlan>[
        plan(id: 'own'),
        plan(id: 'closed', isClosed: true),
        plan(id: 'theirs', cardId: 'c1', person: 'Arun'),
      ]);
      expect(
        cards.plansForExpense().map((EmiPlan p) => p.id),
        <String>['own'],
      );
    });

    test("the expense's own plan stays offered whatever it is", () async {
      final CreditCardProvider cards = await provider(<EmiPlan>[
        plan(id: 'closed', isClosed: true),
        plan(id: 'theirs', cardId: 'c1', person: 'Arun'),
      ]);
      expect(
        cards.plansForExpense(keepId: 'closed').map((EmiPlan p) => p.id),
        <String>['closed'],
      );
      expect(
        cards.plansForExpense(keepId: 'theirs').map((EmiPlan p) => p.id),
        <String>['theirs'],
      );
    });

    test('an account lists its own plans, and none paid from elsewhere', () async {
      final CreditCardProvider cards = await provider(<EmiPlan>[
        plan(id: 'a'),
        plan(id: 'b', bankAccountId: 'a2'),
        plan(id: 'c', cardId: 'c1', bankAccountId: 'a1'),
      ]);
      expect(
        cards.plansForAccount('a1').map((EmiPlan p) => p.id),
        <String>['a', 'c'],
      );
      expect(cards.plansForAccount('a2').map((EmiPlan p) => p.id), <String>['b']);
    });

    test('the provider deducts what was recorded from each plan', () async {
      final CreditCardProvider cards = await loaded(
        <EmiPlan>[
          plan(id: 'a', pendingAmount: 100000),
          plan(id: 'b', pendingAmount: 20000),
          plan(id: 'c'),
        ],
        const <String, EmiBalance>{
          'a': EmiBalance(paid: 25000, payments: 2),
          'b': EmiBalance(paid: 30000, payments: 3),
        },
      );
      expect(cards.pendingLeftFor(cards.planById('a')!), 75000);
      expect(cards.pendingLeftFor(cards.planById('b')!), 0);
      expect(cards.pendingLeftFor(cards.planById('c')!), isNull);
    });

    test('a plan with no card is never offered a reimbursement', () {
      const CreditCard card = CreditCard(
        id: 'c1',
        userId: 'u1',
        cardName: 'Millennia',
        issuer: 'HDFC Bank',
        last4: '3020',
        creditLimit: 200000,
        statementDay: 20,
        paymentDueDay: 8,
      );
      final List<EmiReimbursementOption> options = emiReimbursementOptions(
        plans: <EmiPlan>[
          plan(id: 'bank'),
          plan(id: 'card', cardId: 'c1', bankAccountId: null),
        ],
        claims: const <ClaimSummary>[],
        cards: const <CreditCard>[card],
        entries: null,
      );
      expect(options.map((EmiReimbursementOption o) => o.plan.id), <String>['card']);
    });
  });

  group('hashtags typed during an import', () {
    const List<Tag> saved = <Tag>[
      Tag(id: 't1', name: 'family'),
      Tag(id: 't2', name: 'CarSpending'),
    ];

    test('a tag typed on one row is offered on the next', () {
      final List<Tag> offered = TagRules.merge(saved, <String>['Holiday']);
      expect(offered.map((Tag t) => t.name), <String>['CarSpending', 'family', 'Holiday']);
      expect(offered.last.id, 'session:holiday');
    });

    test('a saved tag keeps its spelling, whatever case it was typed in', () {
      final List<Tag> offered = TagRules.merge(saved, <String>['FAMILY', '#carspending']);
      expect(offered, hasLength(2));
      expect(offered.firstWhere((Tag t) => t.id == 't1').name, 'family');
    });

    test('the same new tag on several rows is offered once, as first typed', () {
      final List<Tag> offered =
          TagRules.merge(const <Tag>[], <String>['Trip', 'trip', '#TRIP ', '']);
      expect(offered.map((Tag t) => t.name), <String>['Trip']);
    });

    test('a long name is clipped as the database clips it', () {
      final List<Tag> offered = TagRules.merge(const <Tag>[], <String>['x' * 60]);
      expect(offered.single.name.length, TagRules.maxLength);
    });

    test('the next row can pick the offered tag by its typed spelling', () {
      final List<Tag> offered = TagRules.merge(saved, <String>['Holiday']);
      expect(TagRules.add(<String>[], 'holiday', offered), <String>['Holiday']);
    });
  });

  group('the import session offers the tags typed on its rows', () {
    tearDown(SchemaCapabilities.debugReset);

    test('a tag typed on the first row is offered with the saved ones', () async {
      SchemaCapabilities.debugOverride(tags: true);
      final SupabaseClient client = SupabaseClient(
        'http://localhost:54321',
        'test-anon-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      final StatementImportProvider import = StatementImportProvider(
        engine: _RowsEngine(),
        expenses: ExpenseRepository(client),
        income: IncomeRepository(client),
        ledger: LedgerRepository(client),
        tags: _SavedTags(client),
      )..begin(
          userId: 'u1',
          account: const BankAccount(
              id: 'a1', userId: 'u1', bankName: 'HDFC', nickname: 'Salary'),
          accounts: const <BankAccount>[],
          categories: const [],
          cards: const <CreditCard>[],
        );

      // Nothing typed yet: only the saved tags.
      expect((await import.knownTags()).map((Tag t) => t.name), <String>['family']);

      // "Done" on the first row with a brand-new tag.
      await import.edit('r1', const <String, Object?>{});
      final List<Tag> offered = await import.knownTags();
      expect(offered.map((Tag t) => t.name), <String>['family', 'Holiday']);
    });
  });

  group('tag usage', () {
    test('a tag counts expenses and income together', () {
      final TagUsage u = TagUsage.fromMap(<String, dynamic>{
        'tag_id': 't1',
        'expense_count': 3,
        'income_count': 1,
      });
      expect(u.total, 4);
      expect(const TagUsage(tagId: 't2').total, 0);
    });
  });
}

/// A [CreditCardProvider] that has loaded [plans] and their [balances],
/// without a database.
Future<CreditCardProvider> loaded(
  List<EmiPlan> plans,
  Map<String, EmiBalance> balances,
) async {
  SchemaCapabilities.debugOverride(
    creditCards: true,
    treatments: true,
    emi: true,
    emiBank: true,
  );
  final SupabaseClient client = SupabaseClient(
    'http://localhost:54321',
    'test-anon-key',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  final LedgerRepository ledger = LedgerRepository(client);
  final CreditCardProvider provider = CreditCardProvider(
    repository: _NoCards(
      client,
      expenses: ExpenseRepository(client),
      ledger: ledger,
    ),
    ledger: ledger,
    plans: _Plans(client, plans, balances),
  );
  await provider.load(userId: 'u1');
  return provider;
}

class _NoCards extends CreditCardRepository {
  _NoCards(super.client, {required super.expenses, required super.ledger});

  @override
  Future<void> refreshCapabilities() async {}

  @override
  Future<List<CreditCard>> fetchCards(String userId) async =>
      const <CreditCard>[];

  @override
  Future<List<CardEntry>> fetchEntries({
    required String userId,
    String? cardId,
  }) async =>
      const <CardEntry>[];
}

class _Plans extends EmiPlanRepository {
  _Plans(super.client, this.plans, this.balances);

  final List<EmiPlan> plans;
  final Map<String, EmiBalance> balances;

  @override
  Future<List<EmiPlan>> fetchPlans({
    required String userId,
    String? cardId,
  }) async =>
      plans;

  @override
  Future<Map<String, EmiBalance>> fetchBalances() async => balances;
}

/// An engine whose rows are one expense that has been given a new tag.
class _RowsEngine implements StatementEngine {
  @override
  Future<Object?> call(String name, Map<String, Object?> args) async =>
      switch (name) {
        'reduce' => <Object?>[
            <String, Object?>{
              'id': 'r1',
              'tags': <Object?>['Holiday', 'family'],
            },
          ],
        'view' => <String, Object?>{'summary': <String, Object?>{}, 'rows': <Object?>[]},
        _ => null,
      };

  @override
  Future<PickedStatementFile?> pickFile() async => null;

  @override
  Future<void> release(String token) async {}
}

class _SavedTags extends TagRepository {
  const _SavedTags(super.client);

  @override
  Future<List<Tag>> fetchTags(String userId) async =>
      const <Tag>[Tag(id: 't1', name: 'family')];
}
