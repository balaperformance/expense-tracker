// One set of expense fields everywhere an expense is added or edited — Add
// Expense, a bank statement row, a card statement row — with the EMI picker
// in the imports too; and the `groceries` + `famspendings` tags a Groceries
// expense gets automatically (once, on moving into Groceries, removable).
// Every figure is invented.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/models/bank_account.dart';
import 'package:expense_tracker/models/card_statement.dart';
import 'package:expense_tracker/models/credit_card.dart';
import 'package:expense_tracker/models/emi_plan.dart';
import 'package:expense_tracker/models/expense.dart';
import 'package:expense_tracker/models/expense_category.dart';
import 'package:expense_tracker/models/ledger_entry.dart';
import 'package:expense_tracker/models/payment_method.dart';
import 'package:expense_tracker/models/tag.dart';
import 'package:expense_tracker/models/tag_rules.dart';
import 'package:expense_tracker/providers/bank_account_provider.dart';
import 'package:expense_tracker/providers/card_import_provider.dart';
import 'package:expense_tracker/providers/category_provider.dart';
import 'package:expense_tracker/providers/credit_card_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/providers/statement_import_provider.dart';
import 'package:expense_tracker/repositories/bank_account_repository.dart';
import 'package:expense_tracker/repositories/category_repository.dart';
import 'package:expense_tracker/repositories/credit_card_repository.dart';
import 'package:expense_tracker/repositories/emi_plan_repository.dart';
import 'package:expense_tracker/repositories/expense_repository.dart';
import 'package:expense_tracker/repositories/income_repository.dart';
import 'package:expense_tracker/repositories/ledger_repository.dart';
import 'package:expense_tracker/repositories/profile_repository.dart';
import 'package:expense_tracker/repositories/receivable_repository.dart';
import 'package:expense_tracker/repositories/tag_repository.dart';
import 'package:expense_tracker/screens/cards/card_import_sheets.dart';
import 'package:expense_tracker/screens/statement_import/import_row_sheet.dart';
import 'package:expense_tracker/services/preferences_service.dart';
import 'package:expense_tracker/services/schema_capabilities.dart';
import 'package:expense_tracker/services/statement_import/statement_engine.dart';
import 'package:expense_tracker/widgets/expense_fields.dart';

Tag tag(String name) => Tag(id: 'id-$name', name: name);

const List<ExpenseCategory> categories = <ExpenseCategory>[
  ExpenseCategory(id: 'cat-food', userId: 'u1', name: 'Food'),
  ExpenseCategory(id: 'cat-groc', userId: 'u1', name: 'Groceries'),
];

const EmiPlan homeLoan = EmiPlan(
  id: 'plan-home',
  userId: 'u1',
  bankAccountId: 'a1',
  title: 'Home loan',
  monthlyAmount: 12000,
  pendingAmount: 240000,
  categoryId: 'cat-food',
);

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

SupabaseClient testClient() => SupabaseClient(
      'http://localhost:54321',
      'test-anon-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );

void main() {
  group('grocery tags', () {
    test('Groceries is recognised whatever the case, spacing or plural', () {
      expect(TagRules.isGroceriesCategory('Groceries'), isTrue);
      expect(TagRules.isGroceriesCategory('  grocery '), isTrue);
      expect(TagRules.isGroceriesCategory('GROCERIES'), isTrue);
      expect(TagRules.isGroceriesCategory('Food'), isFalse);
      expect(TagRules.isGroceriesCategory(null), isFalse);
    });

    test('both tags are added once, spelled as the user already spells them', () {
      expect(TagRules.withAutoTags(<String>[], 'Groceries'), <String>['groceries', 'famspendings']);
      expect(
        TagRules.withAutoTags(<String>['FamSpendings'], 'Groceries', <Tag>[tag('Groceries')]),
        <String>['FamSpendings', 'Groceries'],
      );
      expect(TagRules.withAutoTags(<String>['trip'], 'Food'), <String>['trip']);
    });

    test('never past the per-transaction limit', () {
      final List<String> full = List<String>.generate(TagRules.maxPerTransaction, (int i) => 't$i');
      expect(TagRules.withAutoTags(full, 'Groceries'), full);
    });

    test('only moving into Groceries adds them', () {
      expect(TagRules.autoTagsOnCategoryChange(<String>[], 'Food', 'Groceries'),
          <String>['groceries', 'famspendings']);
      expect(TagRules.autoTagsOnCategoryChange(<String>[], null, 'Groceries'),
          <String>['groceries', 'famspendings']);
      // Already Groceries (the user removed them), or not Groceries: nothing.
      expect(TagRules.autoTagsOnCategoryChange(<String>[], 'Groceries', 'Groceries'), isNull);
      expect(TagRules.autoTagsOnCategoryChange(<String>[], 'Groceries', 'Food'), isNull);
      expect(TagRules.autoTagsOnCategoryChange(<String>['groceries', 'famspendings'], 'Food', 'Groceries'),
          isNull);
    });
  });

  group('ExpenseFields', () {
    Future<_FieldsHarness> pump(WidgetTester tester, {List<String> tags = const <String>[]}) async {
      final _FieldsHarness harness = _FieldsHarness(tags);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: SingleChildScrollView(
            child: StatefulBuilder(
              builder: (BuildContext context, StateSetter setState) => ExpenseFields(
                categories: categories,
                categoryId: harness.categoryId,
                onCategory: (String? id) => setState(() => harness.categoryId = id),
                tags: harness.tags,
                tagDraft: harness.draft,
                onTags: (List<String> next) => setState(() => harness.tags = next),
              ),
            ),
          ),
        ),
      ));
      return harness;
    }

    testWidgets('picking Groceries adds its tags, which can be removed and stay removed',
        (WidgetTester tester) async {
      final _FieldsHarness h = await pump(tester, tags: <String>['trip']);
      await tester.tap(find.text('Groceries'));
      await tester.pump();
      expect(h.tags, <String>['trip', 'groceries', 'famspendings']);

      // Removed by the user, and not added back while it stays Groceries.
      await tester.tap(find.byTooltip('Remove tag groceries'));
      await tester.pump();
      await tester.tap(find.text('Groceries'));
      await tester.pump();
      expect(h.tags, <String>['trip', 'famspendings']);

      // Away and back again is a new choice of Groceries: it is added once more.
      await tester.tap(find.text('Food'));
      await tester.pump();
      await tester.tap(find.text('Groceries'));
      await tester.pump();
      expect(h.tags, <String>['trip', 'famspendings', 'groceries']);
    });

    testWidgets('another category adds nothing', (WidgetTester tester) async {
      final _FieldsHarness h = await pump(tester);
      await tester.tap(find.text('Food'));
      await tester.pump();
      expect(h.tags, isEmpty);
    });
  });

  group('bank statement row', () {
    late SupabaseClient client;
    late _ImportEngine engine;
    late StatementImportProvider import;
    late PreferencesService preferences;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      preferences = await PreferencesService.create();
      client = testClient();
      engine = _ImportEngine();
      import = StatementImportProvider(
        engine: engine,
        expenses: ExpenseRepository(client),
        income: IncomeRepository(client),
        ledger: LedgerRepository(client),
        tags: TagRepository(client),
      )..begin(
          userId: 'u1',
          account: _accounts.first,
          accounts: _accounts,
          categories: categories,
          cards: const <CreditCard>[],
        );
      SchemaCapabilities.debugReset();
      SchemaCapabilities.debugOverride(tags: true, creditCards: true, emi: true, emiBank: true);
    });

    tearDown(SchemaCapabilities.debugReset);

    Future<void> pump(WidgetTester tester, ImportRow row) async {
      tester.view.physicalSize = const Size(720, 1440);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      final CategoryProvider cats = CategoryProvider(_Categories(client));
      await cats.initialise('u1');
      final CreditCardProvider cards = await _cardsWith(client, <EmiPlan>[homeLoan]);
      await tester.pumpWidget(MultiProvider(
        providers: <ChangeNotifierProvider<dynamic>>[
          ChangeNotifierProvider<StatementImportProvider>.value(value: import),
          ChangeNotifierProvider<CategoryProvider>.value(value: cats),
          ChangeNotifierProvider<CreditCardProvider>.value(value: cards),
          ChangeNotifierProvider<SettingsProvider>(
            create: (_) => SettingsProvider(repository: ProfileRepository(client), preferences: preferences),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          home: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => Scaffold(body: ImportRowSheet(row: row)),
              )),
              child: const Text('Open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
    }

    Map<String, Object?> lastPatch() {
      final Map<String, Object?> action =
          engine.calls.lastWhere(((String, Map<String, Object?>) c) => c.$1 == 'reduce').$2['action']!
              as Map<String, Object?>;
      expect(action['type'], 'edit');
      return action['patch']! as Map<String, Object?>;
    }

    Future<void> tapAt(WidgetTester tester, Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    testWidgets('an expense offers the EMI picker, and the plan picked is sent with Done',
        (WidgetTester tester) async {
      await pump(tester, _bankRow());
      expect(find.text('EMI'), findsOneWidget);
      await tapAt(tester, find.textContaining('Home loan'));
      expect(find.textContaining('Pending after this'), findsOneWidget);
      await tapAt(tester, find.text('Done'));
      final Map<String, Object?> patch = lastPatch();
      expect(patch['emiPlanId'], 'plan-home');
      // An empty category is filled from the plan; the statement's amount stays.
      expect(patch['categoryId'], 'cat-food');
      expect(patch.containsKey('amount'), isFalse);
    });

    testWidgets('income has no EMI picker', (WidgetTester tester) async {
      await pump(tester, _bankRow(kind: 'income', debit: false));
      expect(find.text('EMI'), findsNothing);
      expect(find.text('Source'), findsOneWidget);
    });

    testWidgets('picking Groceries adds its tags to the row', (WidgetTester tester) async {
      await pump(tester, _bankRow());
      await tapAt(tester, find.text('Groceries'));
      await tapAt(tester, find.text('Done'));
      expect(lastPatch()['tags'], <String>['groceries', 'famspendings']);
    });
  });

  group('card statement row', () {
    late SupabaseClient client;
    late _CardEngine engine;
    late _Expenses expenses;
    late CardImportProvider provider;
    late PreferencesService preferences;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      preferences = await PreferencesService.create();
      SchemaCapabilities.debugReset();
      SchemaCapabilities.debugOverride(tags: true, creditCards: true, emi: true, emiBank: true);
      client = testClient();
      engine = _CardEngine();
      expenses = _Expenses(client);
      provider = CardImportProvider(
        engine: engine,
        expenses: expenses,
        ledger: LedgerRepository(client),
        cards: _NoCards(client, expenses: expenses, ledger: LedgerRepository(client)),
        plans: EmiPlanRepository(client),
        tags: TagRepository(client),
        receivables: ReceivableRepository(client),
      );
    });

    tearDown(SchemaCapabilities.debugReset);

    Future<void> start() => provider.start(
          userId: 'u1',
          card: card,
          accounts: const <BankAccount>[],
          categories: categories,
          currency: 'INR',
          paymentMethods: const <PaymentMethod>[],
        );

    test('a purchase picked as an EMI payment is written with its plan', () async {
      await start();
      engine.session = _cardSession(<Map<String, Object?>>[_cardRow('r1')]);
      await provider.changeDirection('r1', 'debit', const <String, Object?>{});
      engine.operations = <Map<String, Object?>>[
        <String, Object?>{
          'type': 'expense',
          'itemId': 'r1',
          'cardId': 'c1',
          'amount': 12000.0,
          'date': '2026-09-12',
          'categoryId': 'cat-food',
          'paymentMethodId': null,
          'merchant': 'Home loan',
          'description': null,
          'notes': 'Imported from card statement',
          'statementDate': '2026-09-20',
          'emi': null,
          'emiPlanId': 'plan-home',
        },
      ];
      expect(await provider.runImport(), isTrue);
      expect(expenses.created.single.emiPlanId, 'plan-home');
      expect(expenses.created.single.emiComponent, isNull);
    });

    Future<void> pump(WidgetTester tester, Map<String, Object?> row) async {
      tester.view.physicalSize = const Size(720, 1440);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      await start();
      engine.session = _cardSession(<Map<String, Object?>>[row]);
      await provider.changeDirection('none', 'debit', const <String, Object?>{});
      final LedgerRepository ledger = LedgerRepository(client);
      final CategoryProvider cats = CategoryProvider(_Categories(client));
      await cats.initialise('u1');
      final CreditCardProvider cards = await _cardsWith(client, <EmiPlan>[homeLoan]);
      await tester.pumpWidget(MultiProvider(
        providers: <ChangeNotifierProvider<dynamic>>[
          ChangeNotifierProvider<CardImportProvider>.value(value: provider),
          ChangeNotifierProvider<CategoryProvider>.value(value: cats),
          ChangeNotifierProvider<CreditCardProvider>.value(value: cards),
          ChangeNotifierProvider<BankAccountProvider>(
            create: (_) => BankAccountProvider(accounts: BankAccountRepository(client), ledger: ledger),
          ),
          ChangeNotifierProvider<SettingsProvider>(
            create: (_) => SettingsProvider(repository: ProfileRepository(client), preferences: preferences),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          home: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  body: CardImportRowSheet(provider: provider, itemId: row['id']! as String, card: card),
                ),
              )),
              child: const Text('Open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
    }

    Map<String, Object?> lastEdit() {
      final Map<String, Object?> action = engine.calls
          .lastWhere(((String, Map<String, Object?>) c) => c.$1 == 'cardReduce')
          .$2['action']! as Map<String, Object?>;
      expect(action['type'], 'edit');
      return action['edit']! as Map<String, Object?>;
    }

    testWidgets('a purchase offers the EMI picker, and the plan picked is sent with Done',
        (WidgetTester tester) async {
      await pump(tester, _cardRow('r1'));
      expect(find.text('EMI'), findsOneWidget);
      final Finder plan = find.textContaining('Home loan');
      await tester.ensureVisible(plan);
      await tester.pumpAndSettle();
      await tester.tap(plan);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Done'));
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(lastEdit()['emiPlanId'], 'plan-home');
    });

    testWidgets('an EMI principal row keeps its instalment grouping instead',
        (WidgetTester tester) async {
      await pump(tester, _cardRow('r1', kind: 'emiPrincipal'));
      expect(find.text('EMI'), findsNothing);
      expect(find.text('Instalment'), findsOneWidget);
    });
  });
}

class _FieldsHarness {
  _FieldsHarness(List<String> tags) : tags = List<String>.of(tags);

  String? categoryId;
  List<String> tags;
  final TextEditingController draft = TextEditingController();
}

class _Categories extends CategoryRepository {
  _Categories(super.client);

  @override
  Future<List<ExpenseCategory>> ensureDefaults(String userId) async => categories;
}

const List<BankAccount> _accounts = <BankAccount>[
  BankAccount(id: 'a1', userId: 'u1', bankName: 'HDFC Bank', nickname: 'HDFC Salary Account', last4: '6459'),
];

ImportRow _bankRow({String kind = 'expense', bool debit = true}) => ImportRow(
      <String, Object?>{
        'id': 'b1:0',
        'sourceStatementId': 'b1',
        'transactionDate': '2026-09-05',
        'description': 'NACH HOME LOAN EMI',
        'rawDescription': 'NACH HOME LOAN EMI',
        'amount': 12000,
        'transactionType': debit ? 'debit' : 'credit',
        'kind': kind,
        'categoryId': null,
        'bankAccountId': 'a1',
        'selected': true,
        'issues': <Object?>[],
      },
      const <String, Object?>{},
    );

Map<String, Object?> _cardRow(String id, {String kind = 'purchase'}) => <String, Object?>{
      'id': id,
      'screenshotId': 's1',
      'date': '2026-09-12',
      'dateText': '12 Sep',
      'title': 'Corner Cafe',
      'rawTitle': 'CORNER CAFE',
      'detail': null,
      'amount': 249.0,
      'direction': 'debit',
      'kind': kind,
      'kindSource': 'rule',
      'categoryId': 'cat-food',
      'confidence': 0.9,
      'issues': <Object?>[],
      'selected': true,
      'edited': false,
      'groupId': null,
    };

Map<String, Object?> _cardSession(List<Map<String, Object?>> items) => <String, Object?>{
      'cardId': 'c1',
      'cycle': <String, Object?>{'start': '2026-08-21', 'end': '2026-09-20'},
      'items': items,
      'groups': <Object?>[],
    };

/// A card provider holding [plans], with no cards or card entries.
Future<CreditCardProvider> _cardsWith(SupabaseClient client, List<EmiPlan> plans) async {
  final LedgerRepository ledger = LedgerRepository(client);
  final CreditCardProvider provider = CreditCardProvider(
    repository: _NoCards(client, expenses: ExpenseRepository(client), ledger: ledger),
    ledger: ledger,
    plans: _Plans(client, plans),
  );
  await provider.load(userId: 'u1');
  return provider;
}

class _NoCards extends CreditCardRepository {
  _NoCards(super.client, {required super.expenses, required super.ledger});

  @override
  Future<void> refreshCapabilities() async {}

  @override
  Future<List<CreditCard>> fetchCards(String userId) async => const <CreditCard>[];

  @override
  Future<List<CardEntry>> fetchEntries({required String userId, String? cardId}) async =>
      const <CardEntry>[];
}

class _Plans extends EmiPlanRepository {
  _Plans(super.client, this.plans);

  final List<EmiPlan> plans;

  @override
  Future<List<EmiPlan>> fetchPlans({required String userId, String? cardId}) async => plans;

  @override
  Future<Map<String, EmiBalance>> fetchBalances() async => const <String, EmiBalance>{};
}

class _Expenses extends ExpenseRepository {
  _Expenses(super.client);

  final List<Expense> created = <Expense>[];

  @override
  Future<Expense> create(Expense expense, {MovementDetails? details}) async {
    created.add(expense);
    return Expense(
      id: 'e${created.length}',
      userId: expense.userId,
      amount: expense.amount,
      expenseDate: expense.expenseDate,
    );
  }
}

/// The bank import's engine: every call is recorded; the review state is
/// not needed by the sheet.
class _ImportEngine implements StatementEngine {
  final List<(String, Map<String, Object?>)> calls = <(String, Map<String, Object?>)>[];

  @override
  Future<Object?> call(String name, Map<String, Object?> args) async {
    calls.add((name, args));
    return switch (name) {
      'kindsFor' => args['type'] == 'debit'
          ? <Object?>['expense', 'transfer']
          : <Object?>['income', 'refund', 'transfer'],
      'reduce' => <Object?>[],
      'view' => <String, Object?>{'summary': <String, Object?>{}, 'rows': <Object?>[]},
      'recheck' => <Object?>[],
      _ => null,
    };
  }

  @override
  Future<PickedStatementFile?> pickFile() async => null;

  @override
  Future<void> release(String token) async {}
}

/// The card import's engine: hands back the session or operations the test
/// set, and records every call.
class _CardEngine implements StatementEngine {
  final List<(String, Map<String, Object?>)> calls = <(String, Map<String, Object?>)>[];
  Map<String, Object?> session = _cardSession(const <Map<String, Object?>>[]);
  List<Map<String, Object?>> operations = <Map<String, Object?>>[];

  @override
  Future<Object?> call(String name, Map<String, Object?> args) async {
    calls.add((name, args));
    return switch (name) {
      'cardCycles' => <Object?>[
          <String, Object?>{
            'cycle': <String, Object?>{'start': '2026-08-21', 'end': '2026-09-20'},
            'label': 'Sep 2026',
            'open': false,
          },
        ],
      'cardSettle' || 'cardReduce' => session,
      'cardView' => <String, Object?>{
          'items': <String, Object?>{},
          'groups': <String, Object?>{},
          'summary': <String, Object?>{},
        },
      'cardPlan' => <String, Object?>{
          'plan': <String, Object?>{'operations': operations, 'skipped': <Object?>[]},
          'counts': <String, Object?>{},
        },
      'cardFinalPlan' => <String, Object?>{'operations': operations, 'skipped': <Object?>[]},
      'cardCounts' => <String, Object?>{},
      _ => null,
    };
  }

  @override
  Future<PickedStatementFile?> pickFile() async => null;

  @override
  Future<void> release(String token) async {}
}
