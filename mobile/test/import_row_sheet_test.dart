// The import review's row editor with a Paytm UPI statement row: its own
// account (unmatched here, so it must be chosen), a time of day, a note, tags
// and the UPI details as printed — rendered at real phone widths, so a long
// account name or a row of chips cannot overflow. Every figure is invented.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/models/bank_account.dart';
import 'package:expense_tracker/models/credit_card.dart';
import 'package:expense_tracker/models/expense_category.dart';
import 'package:expense_tracker/providers/category_provider.dart';
import 'package:expense_tracker/providers/credit_card_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/providers/statement_import_provider.dart';
import 'package:expense_tracker/repositories/category_repository.dart';
import 'package:expense_tracker/repositories/credit_card_repository.dart';
import 'package:expense_tracker/repositories/expense_repository.dart';
import 'package:expense_tracker/repositories/income_repository.dart';
import 'package:expense_tracker/repositories/ledger_repository.dart';
import 'package:expense_tracker/repositories/profile_repository.dart';
import 'package:expense_tracker/repositories/tag_repository.dart';
import 'package:expense_tracker/screens/statement_import/import_row_sheet.dart';
import 'package:expense_tracker/services/preferences_service.dart';
import 'package:expense_tracker/services/schema_capabilities.dart';
import 'package:expense_tracker/services/statement_import/statement_engine.dart';

class _Engine implements StatementEngine {
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
      'sessionRange' => null,
      _ => null,
    };
  }

  @override
  Future<PickedStatementFile?> pickFile() async => null;

  @override
  Future<void> release(String token) async {}
}

const List<BankAccount> _accounts = <BankAccount>[
  BankAccount(id: 'a1', userId: 'u1', bankName: 'Airtel Payments Bank', nickname: 'Airtel Payments Bank wallet', last4: '9714'),
  BankAccount(id: 'a2', userId: 'u1', bankName: 'HDFC Bank', nickname: 'HDFC Salary Account', last4: '6459'),
  BankAccount(id: 'a3', userId: 'u1', bankName: 'Indian Bank', nickname: 'Indian Bank Savings', last4: '4462'),
];

ImportRow _paytmRow({String kind = 'expense', Map<String, Object?>? target}) => ImportRow(
      <String, Object?>{
        'id': 'p1:0',
        'sourceStatementId': 'p1',
        'transactionDate': '2026-09-12',
        'description': 'Paid to Corner Cafe',
        'rawDescription': 'Paid to Corner Cafe',
        'amount': 249,
        'transactionType': 'debit',
        'kind': kind,
        'categoryId': null,
        'counterparty': 'Corner Cafe',
        'reference': '600012345678',
        'upiId': 'cornercafe@okaxis',
        'transactionTime': '13:05',
        'notes': 'Lunch with the team',
        'tags': <Object?>['food', 'office'],
        'sourceAccount': 'Unknown Bank - 99',
        'accountStatus': 'unmatched',
        'bankAccountId': '',
        if (target != null) 'transferTarget': target,
        'selected': true,
        'issues': <Object?>[],
      },
      const <String, Object?>{'problem': 'account'},
    );

void main() {
  late SupabaseClient client;
  late _Engine engine;
  late StatementImportProvider import;
  late PreferencesService preferences;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    preferences = await PreferencesService.create();
    client = SupabaseClient(
      'http://localhost:54321',
      'test-anon-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    engine = _Engine();
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
        categories: const <ExpenseCategory>[],
        cards: const <CreditCard>[],
      );
    SchemaCapabilities.debugReset();
    SchemaCapabilities.debugOverride(transfers: true, tags: true, creditCards: true);
  });

  tearDown(SchemaCapabilities.debugReset);

  Future<void> pump(WidgetTester tester, ImportRow row, double width) async {
    tester.view.physicalSize = Size(width * 2, 720 * 2);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final ExpenseRepository expenses = ExpenseRepository(client);
    final LedgerRepository ledger = LedgerRepository(client);
    await tester.pumpWidget(MultiProvider(
      providers: <ChangeNotifierProvider<dynamic>>[
        ChangeNotifierProvider<StatementImportProvider>.value(value: import),
        ChangeNotifierProvider<CategoryProvider>(
          create: (_) => CategoryProvider(CategoryRepository(client)),
        ),
        ChangeNotifierProvider<CreditCardProvider>(
          create: (_) => CreditCardProvider(
            repository: CreditCardRepository(client, expenses: expenses, ledger: ledger),
            ledger: ledger,
          ),
        ),
        ChangeNotifierProvider<SettingsProvider>(
          create: (_) => SettingsProvider(
            repository: ProfileRepository(client),
            preferences: preferences,
          ),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(body: ImportRowSheet(row: row)),
      ),
    ));
    await tester.pumpAndSettle();
  }

  for (final double width in <double>[320, 360, 411]) {
    testWidgets('a Paytm row shows its account, time, note, tags and UPI '
        'details at $width dp', (WidgetTester tester) async {
      await pump(tester, _paytmRow(), width);
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Paid from'), findsOneWidget);
      expect(find.text('Choose one'), findsOneWidget);
      expect(find.text('The statement says: Unknown Bank - 99'), findsOneWidget);
      expect(find.text('1:05 PM'), findsOneWidget);
      expect(find.text('Lunch with the team'), findsOneWidget);
      expect(find.text('#food'), findsOneWidget);
      expect(find.text('#office'), findsOneWidget);

      // The sheet's own list, not a text field's inner scroller.
      await tester.scrollUntilVisible(
        find.text('UPI Ref No: 600012345678'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('UPI ID: cornercafe@okaxis'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a self transfer offers your other accounts, a card bill and cash',
      (WidgetTester tester) async {
    await pump(
      tester,
      _paytmRow(kind: 'transfer', target: <String, Object?>{'type': 'account', 'accountId': 'a2'}),
      360,
    );
    expect(find.textContaining('Transfer to'), findsOneWidget);
    expect(find.text('HDFC Salary Account •••• 6459'), findsNWidgets(2),
        reason: 'once to choose the row\'s account, once as the transfer target');
    expect(find.text('Cash or other'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('saving without an account says which one to choose',
      (WidgetTester tester) async {
    await pump(tester, _paytmRow(), 360);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Choose the account it was paid from.'), findsOneWidget);
    expect(engine.calls.where(((String, Map<String, Object?>) c) => c.$1 == 'reduce'), isEmpty);
  });
}
