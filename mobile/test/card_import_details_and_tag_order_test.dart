// Card statement import rows get the fields of Add Expense (tags, notes,
// payment method, paid for someone), hashtags are listed in one fixed
// priority order everywhere, and a purchase paid by credit card gets the
// Credit Card payment method. Nothing touches a database: the engine and the
// repositories are fakes, every figure is invented.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/models/bank_account.dart';
import 'package:expense_tracker/models/card_statement.dart';
import 'package:expense_tracker/models/credit_card.dart';
import 'package:expense_tracker/models/expense.dart';
import 'package:expense_tracker/models/expense_category.dart';
import 'package:expense_tracker/models/ledger_entry.dart';
import 'package:expense_tracker/models/payment_method.dart';
import 'package:expense_tracker/models/receivable.dart';
import 'package:expense_tracker/models/tag.dart';
import 'package:expense_tracker/models/tag_rules.dart';
import 'package:expense_tracker/providers/bank_account_provider.dart';
import 'package:expense_tracker/providers/card_import_provider.dart';
import 'package:expense_tracker/providers/category_provider.dart';
import 'package:expense_tracker/providers/receivable_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/repositories/bank_account_repository.dart';
import 'package:expense_tracker/repositories/category_repository.dart';
import 'package:expense_tracker/repositories/credit_card_repository.dart';
import 'package:expense_tracker/repositories/emi_plan_repository.dart';
import 'package:expense_tracker/repositories/expense_repository.dart';
import 'package:expense_tracker/repositories/ledger_repository.dart';
import 'package:expense_tracker/repositories/profile_repository.dart';
import 'package:expense_tracker/repositories/receivable_repository.dart';
import 'package:expense_tracker/repositories/tag_repository.dart';
import 'package:expense_tracker/screens/cards/card_import_sheets.dart';
import 'package:expense_tracker/services/preferences_service.dart';
import 'package:expense_tracker/services/schema_capabilities.dart';
import 'package:expense_tracker/services/statement_import/statement_engine.dart';

Tag tag(String name) => Tag(id: 'id-$name', name: name);

List<String> names(List<Tag> tags) => tags.map((Tag t) => t.name).toList();

const List<PaymentMethod> methods = <PaymentMethod>[
  PaymentMethod(id: 'pm-cash', userId: 'u1', name: 'Cash'),
  PaymentMethod(id: 'pm-card', userId: 'u1', name: ' credit  CARD '),
  PaymentMethod(id: 'pm-upi', userId: 'u1', name: 'UPI'),
];

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

void main() {
  group('hashtag priority order', () {
    test('the usual tags come first, in the fixed order, then the rest A–Z', () {
      final List<Tag> sorted = TagRules.sortTags(<Tag>[
        tag('zebra'),
        tag('fuel'),
        tag('Apple'),
        tag('food'),
        tag('famsavings'),
        tag('famfood'),
        tag('groceries'),
        tag('myownspendings'),
        tag('famspendings'),
        tag('banana'),
      ]);
      expect(names(sorted), <String>[
        'famspendings',
        'myownspendings',
        'groceries',
        'famfood',
        'food',
        'famsavings',
        'fuel',
        'Apple',
        'banana',
        'zebra',
      ]);
    });

    test('the priority match ignores case, a leading # and extra spaces', () {
      expect(
        TagRules.sortNames(<String>['Zed', 'FOOD', '#FamSpendings', 'Groceries ']),
        <String>['#FamSpendings', 'Groceries ', 'FOOD', 'Zed'],
      );
    });

    test('sorting returns a new list and leaves ties as they were', () {
      final List<String> input = <String>['b', 'a'];
      final List<String> out = TagRules.sortNames(input);
      expect(out, <String>['a', 'b']);
      expect(input, <String>['b', 'a']);
      // The very same name twice keeps the order it came in.
      List<String> ids(List<String> order) => TagRules.sortTags(<Tag>[
            for (final String id in order) Tag(id: id, name: 'trip'),
          ]).map((Tag t) => t.id).toList();
      expect(ids(<String>['1', '2']), <String>['1', '2']);
      expect(ids(<String>['2', '1']), <String>['2', '1']);
    });

    test('suggestions with nothing typed are in priority order', () {
      final List<Tag> known = <Tag>[tag('trip'), tag('fuel'), tag('famspendings'), tag('food')];
      expect(names(TagRules.suggestions(known, const <String>[], '')),
          <String>['famspendings', 'food', 'fuel', 'trip']);
    });

    test('typed text puts the names starting with it first, then priority', () {
      final List<Tag> known = <Tag>[
        tag('famfood'),
        tag('food'),
        tag('foodie'),
        tag('seafood'),
        tag('fuel'),
      ];
      expect(names(TagRules.suggestions(known, const <String>[], 'foo')),
          <String>['food', 'foodie', 'famfood', 'seafood']);
    });

    test('tags already chosen are not offered again', () {
      final List<Tag> known = <Tag>[tag('famspendings'), tag('food')];
      expect(names(TagRules.suggestions(known, const <String>['FamSpendings'], '')),
          <String>['food']);
    });

    test('merging session tags keeps the saved spelling and the priority order', () {
      final List<Tag> merged = TagRules.merge(
        <Tag>[tag('Trip'), tag('fuel')],
        <String>['TRIP', 'famspendings', 'alpha'],
      );
      expect(names(merged), <String>['famspendings', 'fuel', 'alpha', 'Trip']);
      expect(merged.firstWhere((Tag t) => t.name == 'famspendings').id, 'session:famspendings');
    });

    test('names of a transaction are listed in display order', () {
      final List<Tag> known = <Tag>[tag('trip'), tag('food'), tag('famspendings')];
      expect(
        TagRules.names(known, <String>['id-trip', 'id-food', 'id-famspendings', 'gone']),
        <String>['famspendings', 'food', 'trip'],
      );
    });

    test('anything carrying a tag name can be listed the same way', () {
      final List<({String name, int count})> rows = TagRules.sortedBy(
        <({String name, int count})>[(name: 'zed', count: 9), (name: 'groceries', count: 1)],
        (({String name, int count}) r) => r.name,
      );
      expect(rows.map((({String name, int count}) r) => r.name), <String>['groceries', 'zed']);
    });
  });

  group('creditCardMethod', () {
    test('finds the Credit Card method whatever its case and spacing', () {
      expect(creditCardMethod(methods)?.id, 'pm-card');
    });

    test('is null when the user has none by that name', () {
      expect(
        creditCardMethod(const <PaymentMethod>[
          PaymentMethod(id: 'a', userId: 'u1', name: 'Debit Card'),
          PaymentMethod(id: 'b', userId: 'u1', name: 'Credit'),
        ]),
        isNull,
      );
      expect(creditCardMethod(const <PaymentMethod>[]), isNull);
    });
  });

  group('card import provider', () {
    late SupabaseClient client;
    late _Engine engine;
    late _Expenses expenses;
    late _Tags tags;
    late _Receivables receivables;
    late CardImportProvider provider;

    setUp(() {
      SchemaCapabilities.debugReset();
      SchemaCapabilities.debugOverride(tags: true, treatments: true, creditCards: true, emi: true);
      client = SupabaseClient(
        'http://localhost:54321',
        'test-anon-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      engine = _Engine();
      expenses = _Expenses(client);
      tags = _Tags(client);
      receivables = _Receivables(client);
      provider = CardImportProvider(
        engine: engine,
        expenses: expenses,
        ledger: LedgerRepository(client),
        cards: _Cards(client, expenses: expenses, ledger: LedgerRepository(client)),
        plans: EmiPlanRepository(client),
        tags: tags,
        receivables: receivables,
      );
    });

    tearDown(SchemaCapabilities.debugReset);

    Future<void> begin() => provider.start(
          userId: 'u1',
          card: card,
          accounts: const <BankAccount>[],
          categories: const <ExpenseCategory>[],
          currency: 'INR',
          paymentMethods: methods,
        );

    test('the default payment method is Credit Card', () async {
      await begin();
      expect(provider.defaultPaymentMethodId, 'pm-card');
    });

    test('no Credit Card method, no default', () async {
      await provider.start(
        userId: 'u1',
        card: card,
        accounts: const <BankAccount>[],
        categories: const <ExpenseCategory>[],
        currency: 'INR',
        paymentMethods: const <PaymentMethod>[PaymentMethod(id: 'x', userId: 'u1', name: 'Cash')],
      );
      expect(provider.defaultPaymentMethodId, isNull);
    });

    test('a tag typed on one row is offered on every other row', () async {
      await begin();
      engine.session = _session(<Map<String, Object?>>[
        _row('r1', tags: <String>['trip', 'FamSpendings']),
        _row('r2'),
      ]);
      await provider.changeDirection('r1', 'debit', const <String, Object?>{});
      tags.saved = <Tag>[tag('Trip'), tag('food')];
      final List<Tag> known = await provider.knownTags();
      expect(names(known), <String>['FamSpendings', 'food', 'Trip'],
          reason: 'saved spelling wins, the first spelling of an unsaved tag '
              'wins, priority order');
    });

    test('the plan is asked for with the default payment method', () async {
      await begin();
      engine.session = _session(<Map<String, Object?>>[_row('r1')]);
      await provider.changeDirection('r1', 'debit', const <String, Object?>{});
      await provider.preview();
      final Map<String, Object?> args =
          engine.calls.lastWhere(((String, Map<String, Object?>) c) => c.$1 == 'cardPlan').$2;
      expect(args['defaultPaymentMethodId'], 'pm-card');
    });

    test('an imported purchase is saved with its method, then its tags and who it was paid for', () async {
      await begin();
      engine.session = _session(<Map<String, Object?>>[_row('r1')]);
      await provider.changeDirection('r1', 'debit', const <String, Object?>{});
      engine.operations = <Map<String, Object?>>[
        <String, Object?>{
          'type': 'expense',
          'itemId': 'r1',
          'cardId': 'c1',
          'amount': 249.0,
          'date': '2026-09-12',
          'categoryId': 'cat1',
          'paymentMethodId': 'pm-upi',
          'merchant': 'Corner Cafe',
          'description': null,
          'notes': 'Lunch\nImported from card statement',
          'statementDate': '2026-09-20',
          'emi': null,
          'tags': <String>['famspendings', 'food'],
          'paidForPerson': 'Arun',
        },
      ];
      expect(await provider.runImport(), isTrue);
      expect(expenses.created.single.paymentMethodId, 'pm-upi');
      expect(expenses.created.single.notes, 'Lunch\nImported from card statement');
      expect(tags.written, hasLength(1));
      expect(tags.written.single.$1, 'e1');
      expect(tags.written.single.$2, <String>['famspendings', 'food']);
      expect(receivables.paidFor, <(String, String)>[('e1', 'Arun')]);
      expect(provider.result?.partial, 0);
      expect(provider.result?.importedIds, <String>['r1']);
    });

    test('a failed tag or paid-for write keeps the expense and says so', () async {
      await begin();
      engine.session = _session(<Map<String, Object?>>[_row('r1'), _row('r2')]);
      await provider.changeDirection('r1', 'debit', const <String, Object?>{});
      tags.fail = true;
      receivables.fail = true;
      Map<String, Object?> op(String id, {List<String>? tagNames, String? person}) => <String, Object?>{
            'type': 'expense',
            'itemId': id,
            'cardId': 'c1',
            'amount': 10.0,
            'date': '2026-09-12',
            'categoryId': 'cat1',
            'paymentMethodId': null,
            'merchant': 'Shop',
            'description': null,
            'notes': 'Imported from card statement',
            'statementDate': '2026-09-20',
            'emi': null,
            if (tagNames != null) 'tags': tagNames,
            if (person != null) 'paidForPerson': person,
          };
      engine.operations = <Map<String, Object?>>[
        op('r1', tagNames: <String>['food']),
        op('r2', person: 'Arun'),
      ];
      expect(await provider.runImport(), isTrue);
      expect(expenses.created, hasLength(2));
      expect(provider.result?.partial, 2);
      expect(provider.result?.failed, isEmpty);
      expect(provider.result?.importedIds, <String>['r1', 'r2']);
    });

    test('a plain purchase writes no tags and no claim', () async {
      await begin();
      engine.session = _session(<Map<String, Object?>>[_row('r1')]);
      await provider.changeDirection('r1', 'debit', const <String, Object?>{});
      engine.operations = <Map<String, Object?>>[
        <String, Object?>{
          'type': 'expense',
          'itemId': 'r1',
          'cardId': 'c1',
          'amount': 10.0,
          'date': '2026-09-12',
          'categoryId': 'cat1',
          'paymentMethodId': 'pm-card',
          'merchant': 'Shop',
          'description': null,
          'notes': 'Imported from card statement',
          'statementDate': '2026-09-20',
          'emi': null,
        },
      ];
      await provider.runImport();
      expect(tags.written, isEmpty);
      expect(receivables.paidFor, isEmpty);
      expect(provider.result?.partial, 0);
    });
  });

  group('card import row sheet', () {
    late SupabaseClient client;
    late _Engine engine;
    late CardImportProvider provider;
    late PreferencesService preferences;
    late _Tags tags;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      preferences = await PreferencesService.create();
      SchemaCapabilities.debugReset();
      SchemaCapabilities.debugOverride(tags: true, treatments: true, creditCards: true, emi: true);
      client = SupabaseClient(
        'http://localhost:54321',
        'test-anon-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      engine = _Engine();
      tags = _Tags(client)..saved = <Tag>[tag('trip'), tag('famspendings'), tag('food')];
      final _Expenses expenses = _Expenses(client);
      provider = CardImportProvider(
        engine: engine,
        expenses: expenses,
        ledger: LedgerRepository(client),
        cards: _Cards(client, expenses: expenses, ledger: LedgerRepository(client)),
        plans: EmiPlanRepository(client),
        tags: tags,
        receivables: _Receivables(client),
      );
    });

    tearDown(SchemaCapabilities.debugReset);

    Future<void> pump(WidgetTester tester, Map<String, Object?> row) async {
      tester.view.physicalSize = const Size(720, 1440);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      await provider.start(
        userId: 'u1',
        card: card,
        accounts: const <BankAccount>[],
        categories: const <ExpenseCategory>[],
        currency: 'INR',
        paymentMethods: methods,
      );
      engine.session = _session(<Map<String, Object?>>[row, _row('other', tags: <String>['sessiontag'])]);
      await provider.changeDirection('none', 'debit', const <String, Object?>{});
      final LedgerRepository ledger = LedgerRepository(client);
      await tester.pumpWidget(MultiProvider(
        providers: <ChangeNotifierProvider<dynamic>>[
          ChangeNotifierProvider<CardImportProvider>.value(value: provider),
          ChangeNotifierProvider<CategoryProvider>(
            create: (_) => CategoryProvider(CategoryRepository(client)),
          ),
          ChangeNotifierProvider<BankAccountProvider>(
            create: (_) => BankAccountProvider(accounts: BankAccountRepository(client), ledger: ledger),
          ),
          ChangeNotifierProvider<ReceivableProvider>(
            create: (_) => ReceivableProvider(ReceivableRepository(client), ledger: ledger),
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

    ChoiceChip chip(WidgetTester tester, String label) =>
        tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label));

    /// Taps [finder] after scrolling it into view in the sheet.
    Future<void> tapAt(WidgetTester tester, Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    testWidgets('a purchase offers tags, notes, payment method and paid for someone',
        (WidgetTester tester) async {
      await pump(tester, _row('r1', tags: <String>['trip']));
      expect(find.text('Details'), findsOneWidget);
      expect(find.text('Notes'), findsOneWidget);
      expect(find.text('Payment method'), findsOneWidget);
      expect(find.text('#trip'), findsOneWidget);
      expect(find.text('Paid for someone else'), findsOneWidget);
      // Tags typed on the session's other rows are offered at once, and in order.
      expect(find.widgetWithText(ChoiceChip, 'sessiontag'), findsOneWidget);
      final Offset fam = tester.getTopLeft(find.widgetWithText(ChoiceChip, 'famspendings'));
      final Offset food = tester.getTopLeft(find.widgetWithText(ChoiceChip, 'food'));
      final Offset session = tester.getTopLeft(find.widgetWithText(ChoiceChip, 'sessiontag'));
      bool before(Offset a, Offset b) => a.dy < b.dy || (a.dy == b.dy && a.dx < b.dx);
      expect(before(fam, food), isTrue);
      expect(before(food, session), isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the payment method starts as Credit Card and stays unsent until changed',
        (WidgetTester tester) async {
      await pump(tester, _row('r1'));
      expect(chip(tester, ' credit  CARD ').selected, isTrue);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      final Map<String, Object?> edit = lastEdit();
      expect(edit.containsKey('paymentMethodId'), isFalse);
      expect(edit.containsKey('tags'), isFalse);
      expect(edit.containsKey('notes'), isFalse);
      expect(edit.containsKey('paidForPerson'), isFalse);
    });

    testWidgets('changed fields are sent with Done', (WidgetTester tester) async {
      await pump(tester, _row('r1'));
      await tapAt(tester, find.widgetWithText(ChoiceChip, 'UPI'));
      await tapAt(tester, find.widgetWithText(ChoiceChip, 'food'));
      await tester.ensureVisible(find.widgetWithText(TextField, 'Notes'));
      await tester.enterText(find.widgetWithText(TextField, 'Notes'), '  with the team ');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      final Map<String, Object?> edit = lastEdit();
      expect(edit['paymentMethodId'], 'pm-upi');
      expect(edit['tags'], <String>['food']);
      expect(edit['notes'], 'with the team');
    });

    testWidgets('the method can be cleared, and that is sent as null', (WidgetTester tester) async {
      await pump(tester, _row('r1'));
      await tapAt(tester, find.widgetWithText(ChoiceChip, ' credit  CARD '));
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      final Map<String, Object?> edit = lastEdit();
      expect(edit.containsKey('paymentMethodId'), isTrue);
      expect(edit['paymentMethodId'], isNull);
    });

    testWidgets('a method already chosen on the row is the one shown', (WidgetTester tester) async {
      await pump(tester, <String, Object?>{..._row('r1'), 'paymentMethodId': 'pm-cash'});
      expect(chip(tester, 'Cash').selected, isTrue);
      expect(chip(tester, ' credit  CARD ').selected, isFalse);
    });

    testWidgets('paid for someone needs a name before Done saves', (WidgetTester tester) async {
      await pump(tester, _row('r1'));
      await tapAt(tester, find.text('Paid for someone else'));
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(engine.calls.where(((String, Map<String, Object?>) c) => c.$1 == 'cardReduce'), isEmpty,
          reason: 'the sheet stays open until someone is named');
      await tester.ensureVisible(find.widgetWithText(TextField, 'Name'));
      await tester.enterText(find.widgetWithText(TextField, 'Name'), ' Arun ');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(lastEdit()['paidForPerson'], 'Arun');
    });

    testWidgets('a refund has none of the expense fields', (WidgetTester tester) async {
      await pump(tester, <String, Object?>{
        ..._row('r1'),
        'kind': 'refund',
        'direction': 'credit',
      });
      expect(find.text('Details'), findsNothing);
      expect(find.text('Payment method'), findsNothing);
      expect(find.text('Paid for someone else'), findsNothing);
    });
  });
}

Map<String, Object?> _row(String id, {List<String> tags = const <String>[]}) => <String, Object?>{
      'id': id,
      'screenshotId': 's1',
      'date': '2026-09-12',
      'dateText': '12 Sep',
      'title': 'Corner Cafe',
      'rawTitle': 'CORNER CAFE',
      'detail': null,
      'amount': 249.0,
      'direction': 'debit',
      'kind': 'purchase',
      'kindSource': 'rule',
      'categoryId': 'cat1',
      'confidence': 0.9,
      'issues': <Object?>[],
      'selected': true,
      'edited': false,
      'groupId': null,
      if (tags.isNotEmpty) 'tags': tags,
    };

Map<String, Object?> _session(List<Map<String, Object?>> items) => <String, Object?>{
      'cardId': 'c1',
      'cycle': <String, Object?>{'start': '2026-08-21', 'end': '2026-09-20'},
      'items': items,
      'groups': <Object?>[],
    };

/// The engine as the import sees it: it hands back whatever session or
/// operations the test set, and records every call.
class _Engine implements StatementEngine {
  final List<(String, Map<String, Object?>)> calls = <(String, Map<String, Object?>)>[];
  Map<String, Object?> session = _session(const <Map<String, Object?>>[]);
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

class _Cards extends CreditCardRepository {
  _Cards(super.client, {required super.expenses, required super.ledger});

  @override
  Future<List<CardEntry>> fetchEntries({required String userId, String? cardId}) async => <CardEntry>[];
}

class _Tags extends TagRepository {
  _Tags(super.client);

  List<Tag> saved = const <Tag>[];
  bool fail = false;
  final List<(String, List<String>)> written = <(String, List<String>)>[];

  @override
  Future<List<Tag>> fetchTags(String userId) async => TagRules.sortTags(saved);

  @override
  Future<void> setTags({required TagKind kind, required String id, required List<String> names}) async {
    if (fail) throw StateError('tags failed');
    written.add((id, names));
  }
}

class _Receivables extends ReceivableRepository {
  _Receivables(super.client);

  bool fail = false;
  final List<(String, String)> paidFor = <(String, String)>[];

  @override
  Future<void> setExpensePaidFor({
    required String userId,
    required String expenseId,
    required PaidForDraft? paidFor,
  }) async {
    if (fail) throw StateError('claim failed');
    this.paidFor.add((expenseId, paidFor?.person ?? ''));
  }
}
