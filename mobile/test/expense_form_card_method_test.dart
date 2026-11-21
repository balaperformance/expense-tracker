// The Add expense form's payment method follows "Paid from": choosing Credit
// card sets the Credit Card method, which can still be changed, and a new
// purchase opened on a card starts with it. An expense being edited keeps the
// method it was saved with. Fake providers, invented figures, no network.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/models/card_statement.dart';
import 'package:expense_tracker/models/credit_card.dart';
import 'package:expense_tracker/models/expense.dart';
import 'package:expense_tracker/models/expense_category.dart';
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

const CreditCard travel = CreditCard(
  id: 'c1',
  userId: 'u1',
  cardName: 'Millennia',
  issuer: 'HDFC Bank',
  last4: '3020',
  creditLimit: 200000,
  statementDay: 20,
  paymentDueDay: 8,
);

class FakeAuth extends AuthProvider {
  FakeAuth() : super(AuthRepository(GoTrueClient(autoRefreshToken: false)));

  @override
  String? get userId => 'u1';
}

class FakeCategories extends CategoryProvider {
  FakeCategories(SupabaseClient client) : super(CategoryRepository(client));

  @override
  List<ExpenseCategory> get categories => const <ExpenseCategory>[
        ExpenseCategory(id: 'food', userId: 'u1', name: 'Food', icon: 'restaurant', color: '#FF7043'),
      ];
}

class FakeMethods extends PaymentMethodProvider {
  FakeMethods(SupabaseClient client) : super(PaymentMethodRepository(client));

  @override
  List<PaymentMethod> get methods => const <PaymentMethod>[
        PaymentMethod(id: 'cash', userId: 'u1', name: 'Cash'),
        PaymentMethod(id: 'card', userId: 'u1', name: 'Credit Card'),
        PaymentMethod(id: 'upi', userId: 'u1', name: 'UPI'),
      ];
}

/// One active card, whatever is read.
class OneCard extends CreditCardProvider {
  OneCard({required super.repository, required super.ledger});

  @override
  Future<void> load({required String userId, bool force = false}) async {}

  @override
  List<CardOverview> get overviews => <CardOverview>[
        CardOverview(
          card: travel,
          summary: summariseCard(travel, const <CardEntry>[], DateTime.now()),
        ),
      ];
}

Future<void> pumpForm(WidgetTester tester, Widget screen) async {
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
  final ExpenseRepository expenses = ExpenseRepository(client);

  await tester.pumpWidget(
    MultiProvider(
      providers: <ChangeNotifierProvider<dynamic>>[
        ChangeNotifierProvider<SettingsProvider>.value(
          value: SettingsProvider(repository: ProfileRepository(client), preferences: preferences),
        ),
        ChangeNotifierProvider<AuthProvider>.value(value: FakeAuth()),
        ChangeNotifierProvider<CategoryProvider>.value(value: FakeCategories(client)),
        ChangeNotifierProvider<PaymentMethodProvider>.value(value: FakeMethods(client)),
        ChangeNotifierProvider<BankAccountProvider>.value(
          value: BankAccountProvider(accounts: BankAccountRepository(client), ledger: ledger),
        ),
        ChangeNotifierProvider<CreditCardProvider>.value(
          value: OneCard(
            repository: CreditCardRepository(client, expenses: expenses, ledger: ledger),
            ledger: ledger,
          ),
        ),
        ChangeNotifierProvider<ExpenseProvider>.value(value: ExpenseProvider(expenses)),
      ],
      child: MaterialApp(theme: AppTheme.light, home: screen),
    ),
  );
  await tester.pumpAndSettle();
}

bool chipSelected(WidgetTester tester, String label) =>
    tester.widget<AppChoiceChip>(find.widgetWithText(AppChoiceChip, label)).selected;

Future<void> scrollTo(WidgetTester tester, Finder finder) =>
    tester.scrollUntilVisible(finder, 200, scrollable: find.byType(Scrollable).first);

void main() {
  setUp(() => SchemaCapabilities.debugOverride(creditCards: true, bankAccounts: true, expenseBankLink: true));
  tearDown(SchemaCapabilities.debugReset);

  testWidgets('choosing Credit card sets the Credit Card payment method, which can be changed',
      (WidgetTester tester) async {
    await pumpForm(tester, const ExpenseFormScreen());
    await scrollTo(tester, find.widgetWithText(AppChoiceChip, 'Cash'));
    expect(chipSelected(tester, 'Credit Card'), isFalse);

    await tester.ensureVisible(find.text('Credit card'));
    await tester.tap(find.text('Credit card'));
    await tester.pumpAndSettle();
    await scrollTo(tester, find.widgetWithText(AppChoiceChip, 'UPI'));
    expect(chipSelected(tester, 'Credit Card'), isTrue);

    // Free to change it afterwards.
    await tester.tap(find.widgetWithText(AppChoiceChip, 'UPI'));
    await tester.pumpAndSettle();
    expect(chipSelected(tester, 'UPI'), isTrue);
    expect(chipSelected(tester, 'Credit Card'), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a new purchase opened on a card starts with the Credit Card method',
      (WidgetTester tester) async {
    await pumpForm(tester, const ExpenseFormScreen(initialCardId: 'c1'));
    await scrollTo(tester, find.widgetWithText(AppChoiceChip, 'UPI'));
    expect(chipSelected(tester, 'Credit Card'), isTrue);
  });

  testWidgets('a new expense that is not on a card has no method until one is chosen',
      (WidgetTester tester) async {
    await pumpForm(tester, const ExpenseFormScreen());
    await scrollTo(tester, find.widgetWithText(AppChoiceChip, 'UPI'));
    for (final String name in <String>['Cash', 'Credit Card', 'UPI']) {
      expect(chipSelected(tester, name), isFalse);
    }
  });

  testWidgets('an expense being edited keeps the method it was saved with',
      (WidgetTester tester) async {
    await pumpForm(
      tester,
      ExpenseFormScreen(
        expense: Expense(
          id: 'e1',
          userId: 'u1',
          amount: 250,
          expenseDate: DateTime(2026, 9, 12),
          categoryId: 'food',
          creditCardId: 'c1',
          paymentMethodId: 'upi',
        ),
      ),
    );
    await scrollTo(tester, find.widgetWithText(AppChoiceChip, 'UPI'));
    expect(chipSelected(tester, 'UPI'), isTrue);
    expect(chipSelected(tester, 'Credit Card'), isFalse);
  });
}
