// Quick add on the Add expense form, rendered at the Armor X8's real size
// (360 x 720 dp) over fake repositories: the chips appear only on a blank new
// expense, and a tap fills the form without saving anything. Nothing touches
// a network and every purchase is invented.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/models/bank_account.dart';
import 'package:expense_tracker/models/expense.dart';
import 'package:expense_tracker/models/expense_category.dart';
import 'package:expense_tracker/models/expense_prefill.dart';
import 'package:expense_tracker/models/payment_method.dart';
import 'package:expense_tracker/providers/auth_provider.dart';
import 'package:expense_tracker/providers/bank_account_provider.dart';
import 'package:expense_tracker/providers/category_provider.dart';
import 'package:expense_tracker/providers/credit_card_provider.dart';
import 'package:expense_tracker/providers/expense_provider.dart';
import 'package:expense_tracker/providers/payment_method_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/repositories/auth_repository.dart';
import 'package:expense_tracker/repositories/bank_account_repository.dart';
import 'package:expense_tracker/repositories/category_repository.dart';
import 'package:expense_tracker/repositories/credit_card_repository.dart';
import 'package:expense_tracker/repositories/expense_repository.dart';
import 'package:expense_tracker/repositories/ledger_repository.dart';
import 'package:expense_tracker/repositories/payment_method_repository.dart';
import 'package:expense_tracker/repositories/profile_repository.dart';
import 'package:expense_tracker/screens/expenses/expense_form_screen.dart';
import 'package:expense_tracker/services/preferences_service.dart';
import 'package:expense_tracker/services/schema_capabilities.dart';
import 'package:expense_tracker/widgets/common/app_fields.dart';

const BankAccount salary = BankAccount(
  id: 'a1',
  userId: 'u1',
  bankName: 'Test Bank',
  nickname: 'Salary',
  last4: '1234',
  openingBalance: 50000,
);

DateTime daysAgo(int days) {
  final DateTime now = DateTime.now();
  return DateTime(now.year, now.month, now.day - days);
}

Expense purchase(
  String id,
  int daysBack,
  double amount, {
  required String categoryId,
  String? merchant,
  String? description,
  String? accountId,
  String? methodId,
}) =>
    Expense(
      id: id,
      userId: 'u1',
      amount: amount,
      expenseDate: daysAgo(daysBack),
      categoryId: categoryId,
      paymentMethodId: methodId,
      bankAccountId: accountId,
      merchant: merchant,
      description: description,
    );

final List<Expense> history = <Expense>[
  for (int i = 0; i < 3; i++)
    purchase('c$i', 2 + i * 3, 120,
        categoryId: 'food',
        description: 'Coffee',
        accountId: 'a1',
        methodId: 'upi'),
  for (final (int i, double amount) in <(int, double)>[(0, 532), (1, 845), (2, 1210)])
    purchase('g$i', 4 + i * 7, amount,
        categoryId: 'groceries',
        merchant: 'BigBasket',
        description: 'Weekly groceries'),
  // Paid for a friend each time: owed back, so never a habit to suggest.
  for (int i = 0; i < 3; i++)
    purchase('l$i', 5 + i * 7, 400,
        categoryId: 'food', description: 'Team lunch', accountId: 'a1'),
];

class FakeHistory extends ExpenseRepository {
  FakeHistory(super.client);

  int reads = 0;

  @override
  Future<List<Expense>> fetchRecent({
    required String userId,
    required DateTime from,
    required DateTime toExclusive,
    required int limit,
  }) async {
    reads++;
    return history;
  }

  @override
  Future<Set<String>> fetchPaidForExpenseIds({required String userId}) async =>
      <String>{'l0', 'l1', 'l2'};
}

class FakeAuth extends AuthProvider {
  FakeAuth() : super(AuthRepository(GoTrueClient(autoRefreshToken: false)));

  @override
  String? get userId => 'u1';
}

class FakeCategories extends CategoryProvider {
  FakeCategories(SupabaseClient client) : super(CategoryRepository(client));

  @override
  List<ExpenseCategory> get categories => const <ExpenseCategory>[
        ExpenseCategory(
          id: 'food',
          userId: 'u1',
          name: 'Food',
          icon: 'restaurant',
          color: '#FF7043',
        ),
        ExpenseCategory(
          id: 'groceries',
          userId: 'u1',
          name: 'Groceries',
          icon: 'shopping_cart',
          color: '#43A047',
        ),
      ];
}

class FakeMethods extends PaymentMethodProvider {
  FakeMethods(SupabaseClient client) : super(PaymentMethodRepository(client));

  @override
  List<PaymentMethod> get methods => const <PaymentMethod>[
        PaymentMethod(id: 'upi', userId: 'u1', name: 'UPI'),
      ];
}

class FakeAccounts extends BankAccountProvider {
  FakeAccounts(SupabaseClient client, LedgerRepository ledger)
      : super(accounts: BankAccountRepository(client), ledger: ledger);

  @override
  List<BankAccount> get accounts => const <BankAccount>[salary];
}

Future<FakeHistory> pumpForm(WidgetTester tester, Widget screen) async {
  tester.view.physicalSize = const Size(720, 1440);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues(<String, Object>{});
  final PreferencesService preferences = await PreferencesService.create();
  final SupabaseClient client = SupabaseClient(
    'http://localhost:54321',
    'test-anon-key',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  final LedgerRepository ledger = LedgerRepository(client);
  final FakeHistory expenses = FakeHistory(client);

  await tester.pumpWidget(
    MultiProvider(
      providers: <ChangeNotifierProvider<dynamic>>[
        ChangeNotifierProvider<SettingsProvider>.value(
          value: SettingsProvider(
            repository: ProfileRepository(client),
            preferences: preferences,
          ),
        ),
        ChangeNotifierProvider<AuthProvider>.value(value: FakeAuth()),
        ChangeNotifierProvider<CategoryProvider>.value(
          value: FakeCategories(client),
        ),
        ChangeNotifierProvider<PaymentMethodProvider>.value(
          value: FakeMethods(client),
        ),
        ChangeNotifierProvider<BankAccountProvider>.value(
          value: FakeAccounts(client, ledger),
        ),
        ChangeNotifierProvider<CreditCardProvider>.value(
          value: CreditCardProvider(
            repository: CreditCardRepository(
              client,
              expenses: ExpenseRepository(client),
              ledger: ledger,
            ),
            ledger: ledger,
          ),
        ),
        ChangeNotifierProvider<ExpenseProvider>.value(
          value: ExpenseProvider(expenses),
        ),
      ],
      child: MaterialApp(theme: AppTheme.light, home: screen),
    ),
  );
  await tester.pumpAndSettle();
  return expenses;
}

bool chipSelected(WidgetTester tester, String label) =>
    tester.widget<AppChoiceChip>(find.widgetWithText(AppChoiceChip, label)).selected;

Future<void> scrollTo(WidgetTester tester, Finder finder) =>
    tester.scrollUntilVisible(finder, 200,
        scrollable: find.byType(Scrollable).first);

void main() {
  setUp(() => SchemaCapabilities.debugOverride(
        merchant: true,
        bankAccounts: true,
        expenseBankLink: true,
        treatments: true,
      ));
  tearDown(SchemaCapabilities.debugReset);

  testWidgets('a blank new expense offers the frequent ones, without overflow',
      (WidgetTester tester) async {
    final FakeHistory expenses = await pumpForm(tester, const ExpenseFormScreen());

    expect(tester.takeException(), isNull);
    expect(find.text('Quick add'), findsOneWidget);
    expect(find.text('Coffee · ₹120.00'), findsOneWidget);
    expect(find.text('BigBasket'), findsOneWidget,
        reason: 'its amount varies, so the chip shows none');
    expect(find.textContaining('Team lunch'), findsNothing,
        reason: 'paid for someone else, so not a habit');
    expect(expenses.reads, 1);
  });

  testWidgets('a chip fills the form like the last purchase and saves nothing',
      (WidgetTester tester) async {
    await pumpForm(tester, const ExpenseFormScreen());

    await tester.tap(find.text('Coffee · ₹120.00'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('Filled in from your usual “Coffee”'),
        findsOneWidget);
    expect(find.text('120'), findsOneWidget, reason: 'the usual amount');
    expect(chipSelected(tester, 'Coffee · ₹120.00'), isTrue);
    expect(chipSelected(tester, 'Food'), isTrue);
    await scrollTo(tester, find.widgetWithText(AppChoiceChip, 'Salary'));
    expect(chipSelected(tester, 'Salary'), isTrue);
    await scrollTo(tester, find.widgetWithText(AppChoiceChip, 'UPI'));
    expect(chipSelected(tester, 'UPI'), isTrue);
    expect(find.text('Coffee'), findsOneWidget, reason: 'the description');
    // Still the form: nothing was written, the user saves when ready.
    expect(find.text('Add expense'), findsWidgets);
  });

  testWidgets('switching chips never mixes two habits',
      (WidgetTester tester) async {
    await pumpForm(tester, const ExpenseFormScreen());

    await tester.tap(find.text('Coffee · ₹120.00'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('BigBasket'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('Enter the amount (it varies)'), findsOneWidget);
    expect(find.text('120'), findsNothing, reason: 'a varying amount is blank');
    expect(chipSelected(tester, 'Groceries'), isTrue);
    expect(chipSelected(tester, 'Food'), isFalse);
    await scrollTo(tester, find.widgetWithText(AppChoiceChip, 'Cash'));
    expect(chipSelected(tester, 'Cash'), isTrue,
        reason: 'the groceries were paid in cash');
    await scrollTo(tester, find.text('Weekly groceries'));
    expect(find.text('BigBasket'), findsWidgets, reason: 'the merchant');
    expect(find.text('Weekly groceries'), findsOneWidget);
    await scrollTo(tester, find.widgetWithText(AppChoiceChip, 'UPI'));
    expect(chipSelected(tester, 'UPI'), isFalse,
        reason: 'no method last time, so the coffee one is cleared');
  });

  testWidgets('not offered when editing or when a scan filled the form',
      (WidgetTester tester) async {
    final FakeHistory editing = await pumpForm(
      tester,
      ExpenseFormScreen(expense: history.first),
    );
    expect(find.text('Quick add'), findsNothing);
    expect(editing.reads, 0, reason: 'nothing is read for an edit');

    final FakeHistory scanned = await pumpForm(
      tester,
      const ExpenseFormScreen(
        prefill: ExpensePrefill(
          amount: 250,
          source: ExpensePrefillSource.receiptScan,
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Quick add'), findsNothing);
    expect(scanned.reads, 0);
  });
}
