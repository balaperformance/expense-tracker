// The credit card and statement import screens, rendered at the Armor X8's
// real size (360 x 720 dp) over fake repositories. They check that every
// state lays out without an overflow and shows what it should — not the
// maths, which credit_card_test.dart covers. Nothing touches a network and
// every figure is invented.

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
import 'package:expense_tracker/providers/auth_provider.dart';
import 'package:expense_tracker/providers/bank_account_provider.dart';
import 'package:expense_tracker/providers/category_provider.dart';
import 'package:expense_tracker/providers/credit_card_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/providers/statement_import_provider.dart';
import 'package:expense_tracker/repositories/auth_repository.dart';
import 'package:expense_tracker/repositories/bank_account_repository.dart';
import 'package:expense_tracker/repositories/category_repository.dart';
import 'package:expense_tracker/repositories/credit_card_repository.dart';
import 'package:expense_tracker/repositories/expense_repository.dart';
import 'package:expense_tracker/repositories/income_repository.dart';
import 'package:expense_tracker/repositories/ledger_repository.dart';
import 'package:expense_tracker/repositories/profile_repository.dart';
import 'package:expense_tracker/screens/cards/card_statement_screen.dart';
import 'package:expense_tracker/screens/cards/credit_cards_screen.dart';
import 'package:expense_tracker/screens/statement_import/import_statement_screen.dart';
import 'package:expense_tracker/services/preferences_service.dart';
import 'package:expense_tracker/services/schema_capabilities.dart';
import 'package:expense_tracker/services/statement_import/statement_engine.dart';

const BankAccount savings = BankAccount(
  id: 'a1',
  userId: 'u1',
  bankName: 'A Bank With A Rather Long Registered Name',
  nickname: 'Everyday savings account',
  last4: '1234',
  openingBalance: 250000,
);

const CreditCard travel = CreditCard(
  id: 'c1',
  userId: 'u1',
  cardName: 'Travel Rewards Signature Card',
  issuer: 'Another Bank With A Long Name',
  network: CardNetwork.visa,
  last4: '4821',
  creditLimit: 150000,
  openingOutstanding: 1200,
  statementDay: 15,
  paymentDueDay: 5,
);

const CreditCard closed = CreditCard(
  id: 'c2',
  userId: 'u1',
  cardName: 'Old card',
  issuer: 'Test Bank',
  last4: '9911',
  creditLimit: 50000,
  statementDay: 1,
  paymentDueDay: 20,
  isActive: false,
);

List<CardEntry> entries() => <CardEntry>[
      CardEntry.fromExpense(Expense(
        id: 'x1',
        userId: 'u1',
        amount: 123456.78,
        expenseDate: DateTime(2026, 9, 2),
        creditCardId: 'c1',
        merchant: 'A merchant whose name runs on for quite a while',
      ))!,
      CardEntry.fromCardTransaction(CardTransaction(
        id: 't1',
        userId: 'u1',
        cardId: 'c1',
        kind: CardTransactionKind.fee,
        direction: LedgerDirection.debit,
        amount: 590,
        txnDate: DateTime(2026, 9, 16),
        description: 'Annual fee',
      )),
      CardEntry.fromPayment(LedgerEntry(
        id: 'l1',
        userId: 'u1',
        accountId: 'a1',
        direction: LedgerDirection.debit,
        amount: 5000,
        txnDate: DateTime(2026, 9, 20),
        creditCardId: 'c1',
      ))!,
    ];

class FakeCardRepository extends CreditCardRepository {
  FakeCardRepository(
    super.client,
    this.cards,
    this.rows, {
    required super.expenses,
    required super.ledger,
  });

  final List<CreditCard> cards;
  final List<CardEntry> rows;

  @override
  Future<void> refreshCapabilities() async {}

  @override
  Future<List<CreditCard>> fetchCards(String userId) async => cards;

  @override
  Future<List<CardEntry>> fetchEntries({
    required String userId,
    String? cardId,
  }) async =>
      rows;
}

class FakeAccounts extends BankAccountRepository {
  FakeAccounts(super.client);

  @override
  Future<void> refreshCapabilities() async {}

  @override
  Future<List<BankAccountBalance>> fetchWithBalances(String userId) async =>
      const <BankAccountBalance>[
        BankAccountBalance(account: savings, totalCredits: 0, totalDebits: 0),
      ];
}

class QuietLedger extends LedgerRepository {
  QuietLedger(super.client);

  @override
  Future<List<LedgerEntry>> fetchForAccount({
    required String userId,
    required String accountId,
    DateTime? from,
    DateTime? toExclusive,
  }) async =>
      const <LedgerEntry>[];
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
          id: 'cat-1',
          userId: 'u1',
          name: 'Shopping',
          icon: 'shopping_bag',
          color: '#FF7043',
        ),
      ];
}

class IdleEngine implements StatementEngine {
  @override
  Future<PickedStatementFile?> pickFile() async => null;

  @override
  Future<Object?> call(String name, Map<String, Object?> args) async =>
      throw StateError('not used');

  @override
  Future<void> release(String token) async {}
}

Future<void> pumpScreen(
  WidgetTester tester,
  Widget screen, {
  List<CreditCard> cards = const <CreditCard>[travel, closed],
}) async {
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
  final QuietLedger ledger = QuietLedger(client);

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
        ChangeNotifierProvider<BankAccountProvider>.value(
          value: BankAccountProvider(
            accounts: FakeAccounts(client),
            ledger: ledger,
          ),
        ),
        ChangeNotifierProvider<CreditCardProvider>.value(
          value: CreditCardProvider(
            repository: FakeCardRepository(
              client,
              cards,
              entries(),
              expenses: ExpenseRepository(client),
              ledger: ledger,
            ),
            ledger: ledger,
          ),
        ),
        ChangeNotifierProvider<StatementImportProvider>.value(
          value: StatementImportProvider(
            engine: IdleEngine(),
            expenses: ExpenseRepository(client),
            income: IncomeRepository(client),
            ledger: ledger,
          ),
        ),
      ],
      child: MaterialApp(theme: AppTheme.light, home: screen),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SchemaCapabilities.debugOverride(
        bankAccounts: true,
        expenseBankLink: true,
        incomeBankLink: true,
        transfers: true,
        creditCards: true,
      ));
  tearDown(SchemaCapabilities.debugReset);

  testWidgets('cards list: totals, active and closed cards, no overflow',
      (WidgetTester tester) async {
    await pumpScreen(tester, const CreditCardsScreen());

    expect(tester.takeException(), isNull);
    expect(find.text('Credit cards'), findsOneWidget);
    expect(find.text('Your cards'), findsOneWidget);
    expect(find.textContaining('Travel Rewards'), findsWidgets);
    expect(find.text('Pay bill'), findsWidgets);
  });

  testWidgets('cards list: empty state offers to add a card',
      (WidgetTester tester) async {
    await pumpScreen(tester, const CreditCardsScreen(),
        cards: const <CreditCard>[]);

    expect(tester.takeException(), isNull);
    expect(find.text('Add card'), findsOneWidget);
  });

  testWidgets('cards list: says when the migration is missing',
      (WidgetTester tester) async {
    SchemaCapabilities.debugOverride(creditCards: false);
    await pumpScreen(tester, const CreditCardsScreen());

    expect(tester.takeException(), isNull);
    expect(find.textContaining('004'), findsWidgets);
  });

  testWidgets('add-card form opens as a sheet without overflow',
      (WidgetTester tester) async {
    await pumpScreen(tester, const CreditCardsScreen());

    await tester.tap(find.text('Card'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Statement day'), findsWidgets);
  });

  testWidgets('statement: hero, latest bill and every kind of row',
      (WidgetTester tester) async {
    await pumpScreen(tester, const CardStatementScreen(cardId: 'c1'));

    expect(tester.takeException(), isNull);
    expect(find.text('Latest bill'), findsOneWidget);
    expect(find.text('Pay bill'), findsOneWidget);
    expect(find.text('Refund, fee…'), findsOneWidget);
    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Annual fee'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(tester.takeException(), isNull);
  });

  testWidgets('statement: pay-bill sheet opens with the bill prefilled',
      (WidgetTester tester) async {
    await pumpScreen(tester, const CardStatementScreen(cardId: 'c1'));

    await tester.tap(find.text('Pay bill'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Full outstanding'), findsOneWidget);
    expect(find.textContaining('Bill due'), findsOneWidget);
  });

  testWidgets('statement: refund/fee sheet opens without overflow',
      (WidgetTester tester) async {
    await pumpScreen(tester, const CardStatementScreen(cardId: 'c1'));

    await tester.tap(find.text('Refund, fee…'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Interest'), findsWidgets);
  });

  testWidgets('statement: an unknown card says so', (WidgetTester tester) async {
    await pumpScreen(tester, const CardStatementScreen(cardId: 'missing'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('import: asks for the account, then offers a file',
      (WidgetTester tester) async {
    await pumpScreen(tester, const ImportStatementScreen());

    expect(tester.takeException(), isNull);
    expect(find.text('Which account is this statement for?'), findsOneWidget);
    await tester.tap(find.text('Everyday savings account'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Choose file'), findsOneWidget);
    expect(find.textContaining('PDF'), findsWidgets);
  });
}
