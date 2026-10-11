// "Paid for someone" on the phone — the one way to track what anyone owes the
// user, a purchase made for them or money lent to them: the expense list's
// rows and its "Paid for someone" view, recording a repayment (and refusing
// one larger than what is owed), the expense form's repayments, and the
// Accounts screen with no separate loans section. Also the expense and income
// forms' tags. Every repository is a fake, so nothing is read from or written
// to a database; the fakes record what the screens asked to write. Every name
// and figure is invented.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/models/bank_account.dart';
import 'package:expense_tracker/models/expense.dart';
import 'package:expense_tracker/models/expense_category.dart';
import 'package:expense_tracker/models/expense_filter.dart';
import 'package:expense_tracker/models/income.dart';
import 'package:expense_tracker/models/ledger_entry.dart';
import 'package:expense_tracker/models/receivable.dart';
import 'package:expense_tracker/models/tag.dart';
import 'package:expense_tracker/providers/auth_provider.dart';
import 'package:expense_tracker/providers/bank_account_provider.dart';
import 'package:expense_tracker/providers/category_provider.dart';
import 'package:expense_tracker/providers/credit_card_provider.dart';
import 'package:expense_tracker/providers/expense_provider.dart';
import 'package:expense_tracker/providers/income_provider.dart';
import 'package:expense_tracker/providers/payment_method_provider.dart';
import 'package:expense_tracker/providers/receivable_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/repositories/auth_repository.dart';
import 'package:expense_tracker/repositories/bank_account_repository.dart';
import 'package:expense_tracker/repositories/category_repository.dart';
import 'package:expense_tracker/repositories/credit_card_repository.dart';
import 'package:expense_tracker/repositories/expense_repository.dart';
import 'package:expense_tracker/repositories/income_repository.dart';
import 'package:expense_tracker/repositories/ledger_repository.dart';
import 'package:expense_tracker/repositories/payment_method_repository.dart';
import 'package:expense_tracker/repositories/profile_repository.dart';
import 'package:expense_tracker/repositories/receivable_repository.dart';
import 'package:expense_tracker/repositories/tag_repository.dart';
import 'package:expense_tracker/screens/accounts/accounts_screen.dart';
import 'package:expense_tracker/screens/expenses/expense_form_screen.dart';
import 'package:expense_tracker/screens/expenses/expenses_screen.dart';
import 'package:expense_tracker/screens/expenses/repayment_sheet.dart';
import 'package:expense_tracker/screens/income/income_form_screen.dart';
import 'package:expense_tracker/services/preferences_service.dart';
import 'package:expense_tracker/services/schema_capabilities.dart';
import 'package:expense_tracker/widgets/common/app_fields.dart';
import 'package:expense_tracker/widgets/transaction_tile.dart';

const BankAccount hdfc = BankAccount(
  id: 'a1',
  userId: 'u1',
  bankName: 'HDFC Bank',
  nickname: 'HDFC Salary Account',
  last4: '6459',
  openingBalance: 25000,
);

final DateTime today = DateTime.now();
DateTime daysAgo(int n) => DateTime(today.year, today.month, today.day - n);

/// A purchase paid for Arun: ₹400, ₹150 of it paid back.
final Expense lunch = Expense(
  id: 'e9',
  userId: 'u1',
  amount: 400,
  expenseDate: daysAgo(3),
  categoryId: 'food',
  description: 'Team lunch',
);

/// The user's own spending, the same day as the lunch.
final Expense coffee = Expense(
  id: 'e5',
  userId: 'u1',
  amount: 120,
  expenseDate: daysAgo(3),
  categoryId: 'food',
  description: 'Coffee',
);

/// Money lent to Arun — an expense paid for him (migration 014): ₹1,000,
/// ₹400 of it paid back.
final Expense lent = Expense(
  id: 'e1',
  userId: 'u1',
  amount: 1000,
  expenseDate: daysAgo(20),
  categoryId: 'food',
  bankAccountId: 'a1',
  description: 'Lent to Arun',
);

List<ClaimSummary> sampleClaims() => summariseClaims(
      receivables: <Receivable>[
        Receivable(
          id: 'c1',
          userId: 'u1',
          person: 'Arun',
          expenseId: 'e1',
          dueDate: daysAgo(2),
          note: 'For the deposit',
        ),
        const Receivable(id: 'c2', userId: 'u1', person: 'arun', expenseId: 'e9', note: 'Split later'),
        const Receivable(id: 'c3', userId: 'u1', person: 'Bea', expenseId: 'e3'),
      ],
      sources: <String, ClaimSource>{
        'c1': ClaimSource(
            date: daysAgo(20), amount: 1000, title: 'Lent to Arun', accountId: 'a1', expenseId: 'e1'),
        'c2': ClaimSource(date: daysAgo(3), amount: 400, title: 'Team lunch', expenseId: 'e9'),
        'c3': ClaimSource(date: daysAgo(40), amount: 500, title: 'Concert tickets', accountId: 'a1', expenseId: 'e3'),
      },
      repayments: <ClaimRepayment>[
        ClaimRepayment(
            entryId: 'r1', receivableId: 'c1', accountId: 'a1', amount: 400, date: daysAgo(10),
            description: 'UPI from Arun'),
        ClaimRepayment(entryId: 'r2', receivableId: 'c2', accountId: 'a1', amount: 150, date: daysAgo(1)),
        ClaimRepayment(entryId: 'r3', receivableId: 'c3', accountId: 'a1', amount: 500, date: daysAgo(30)),
      ],
      today: DateTime(today.year, today.month, today.day),
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

class FakeBanks extends BankAccountRepository {
  FakeBanks(super.client);

  @override
  Future<List<BankAccountBalance>> fetchWithBalances(String userId) async =>
      const <BankAccountBalance>[
        BankAccountBalance(account: hdfc, totalCredits: 900, totalDebits: 1500),
      ];
}

/// Records every movement saved with its treatment — a repayment is one.
class FakeLedger extends LedgerRepository {
  FakeLedger(super.client);

  final List<Map<String, Object?>> movements = <Map<String, Object?>>[];

  @override
  Future<String> recordBankMovement({
    required String accountId,
    required LedgerDirection direction,
    required double amount,
    required DateTime date,
    required String description,
    required Map<String, Object?> treatment,
  }) async {
    movements.add(<String, Object?>{
      'accountId': accountId,
      'direction': direction,
      'amount': amount,
      'description': description,
      'treatment': treatment,
    });
    return 'm${movements.length}';
  }
}

class FakeExpenses extends ExpenseRepository {
  FakeExpenses(super.client);

  final List<Expense> saved = <Expense>[];

  @override
  Future<List<Expense>> fetchPage({
    required String userId,
    required ExpenseFilter filter,
    required int page,
    int pageSize = 20,
  }) async =>
      page == 0 ? <Expense>[lunch, coffee, lent] : const <Expense>[];

  @override
  Future<Expense> create(Expense expense, {MovementDetails? details}) async {
    saved.add(expense);
    return Expense(
      id: 'new1',
      userId: expense.userId,
      amount: expense.amount,
      expenseDate: expense.expenseDate,
      categoryId: expense.categoryId,
    );
  }

  @override
  Future<Expense> update(Expense expense) async {
    saved.add(expense);
    return expense;
  }

  @override
  Future<Expense?> fetchById({required String userId, required String id}) async =>
      <Expense>[lunch, lent, coffee].where((Expense e) => e.id == id).firstOrNull;
}

class FakeIncome extends IncomeRepository {
  FakeIncome(super.client);

  final List<Income> saved = <Income>[];

  @override
  Future<Income> update(Income income) async {
    saved.add(income);
    return income;
  }
}

class FakeReceivables extends ReceivableRepository {
  FakeReceivables(super.client);

  List<ClaimSummary> claims = sampleClaims();
  bool failRead = false;
  final List<(String, PaidForDraft?)> writes = <(String, PaidForDraft?)>[];

  @override
  Future<List<ClaimSummary>> fetchClaims(String userId) async {
    if (failRead) throw StateError('offline');
    return claims;
  }

  @override
  Future<void> setExpensePaidFor({
    required String userId,
    required String expenseId,
    required PaidForDraft? paidFor,
  }) async =>
      writes.add((expenseId, paidFor));
}

class FakeTags extends TagRepository {
  FakeTags(super.client);

  final Map<String, List<String>> onRows = <String, List<String>>{
    'e9': <String>['t2', 't1'],
    'i5': <String>['t3'],
  };
  final List<(TagKind, String, List<String>)> sets = <(TagKind, String, List<String>)>[];

  @override
  Future<List<Tag>> fetchTags(String userId) async => const <Tag>[
        Tag(id: 't1', name: 'family'),
        Tag(id: 't2', name: 'office'),
        Tag(id: 't3', name: 'salary'),
      ];

  @override
  Future<List<String>> fetchTagIdsFor({
    required String userId,
    required TagKind kind,
    required String id,
  }) async =>
      onRows[id] ?? const <String>[];

  @override
  Future<void> setTags({required TagKind kind, required String id, required List<String> names}) async =>
      sets.add((kind, id, names));
}

class Harness {
  Harness(this.client)
      : expenses = FakeExpenses(client),
        income = FakeIncome(client),
        receivables = FakeReceivables(client),
        ledger = FakeLedger(client),
        tags = FakeTags(client);

  final SupabaseClient client;
  final FakeExpenses expenses;
  final FakeIncome income;
  final FakeReceivables receivables;
  final FakeLedger ledger;
  final FakeTags tags;
  Object? popped;

  /// Opens [screen] from a launcher page, so saving can pop back to it.
  Future<void> pump(WidgetTester tester, Widget screen, {double width = 360}) async {
    tester.view.physicalSize = Size(width * 2, 760 * 2);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final PreferencesService preferences = await PreferencesService.create();

    await tester.pumpWidget(MultiProvider(
      providers: <ChangeNotifierProvider<dynamic>>[
        ChangeNotifierProvider<SettingsProvider>.value(
          value: SettingsProvider(repository: ProfileRepository(client), preferences: preferences),
        ),
        ChangeNotifierProvider<AuthProvider>.value(value: FakeAuth()),
        ChangeNotifierProvider<CategoryProvider>.value(value: FakeCategories(client)),
        ChangeNotifierProvider<PaymentMethodProvider>.value(
          value: PaymentMethodProvider(PaymentMethodRepository(client)),
        ),
        ChangeNotifierProvider<BankAccountProvider>.value(
          value: BankAccountProvider(accounts: FakeBanks(client), ledger: ledger),
        ),
        ChangeNotifierProvider<CreditCardProvider>.value(
          value: CreditCardProvider(
            repository: CreditCardRepository(client, expenses: expenses, ledger: ledger),
            ledger: ledger,
          ),
        ),
        ChangeNotifierProvider<ExpenseProvider>.value(
          value: ExpenseProvider(expenses, tags: tags, receivables: receivables),
        ),
        ChangeNotifierProvider<IncomeProvider>.value(value: IncomeProvider(income, tags: tags)),
        ChangeNotifierProvider<ReceivableProvider>.value(
          value: ReceivableProvider(receivables, ledger: ledger),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  popped = await Navigator.of(context).push<Object?>(
                    MaterialPageRoute<Object?>(builder: (_) => screen),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }
}

Future<void> scrollTo(WidgetTester tester, Finder finder, {double delta = 200}) =>
    tester.scrollUntilVisible(finder, delta, scrollable: find.byType(Scrollable).first);

bool chipSelected(WidgetTester tester, String label) =>
    tester.widget<AppChoiceChip>(find.widgetWithText(AppChoiceChip, label)).selected;

void main() {
  late Harness harness;

  setUp(() {
    SchemaCapabilities.debugReset();
    SchemaCapabilities.debugOverride(treatments: true, tags: true);
    harness = Harness(SupabaseClient(
      'http://localhost:54321',
      'test-anon-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    ));
  });
  tearDown(SchemaCapabilities.debugReset);

  group('expense list', () {
    // The accounts name where each one's money came from, and take repayments.
    setUp(() => SchemaCapabilities.debugOverride(bankAccounts: true, expenseBankLink: true));

    testWidgets('marks what was paid for someone, with what is owed, and leaves it out of the day',
        (WidgetTester tester) async {
      await harness.pump(tester, const ExpensesScreen());
      expect(tester.takeException(), isNull);
      expect(find.text('All expenses'), findsOneWidget);
      expect(find.text('Paid for someone'), findsOneWidget);

      final ExpenseTile lunchRow = tester.widget<ExpenseTile>(
          find.byWidgetPredicate((Widget w) => w is ExpenseTile && w.expense.id == 'e9'));
      expect(lunchRow.paidForPerson, 'arun');
      expect(lunchRow.paidForStatus, contains('owed'));
      expect(find.textContaining('Paid for arun'), findsOneWidget);
      final ExpenseTile coffeeRow = tester.widget<ExpenseTile>(
          find.byWidgetPredicate((Widget w) => w is ExpenseTile && w.expense.id == 'e5'));
      expect(coffeeRow.paidForPerson, isNull);
      // ₹400 paid for Arun and ₹120 of the user's own: the day spent ₹120.
      expect(tester.widget<DayHeader>(find.byType(DayHeader).first).total, 120);
    });

    for (final double width in <double>[320, 360, 411]) {
      testWidgets('the "Paid for someone" view lists it by person at $width dp',
          (WidgetTester tester) async {
        await harness.pump(tester, const ExpensesScreen(), width: width);
        await tester.tap(find.text('Paid for someone'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('OWED TO YOU'), findsOneWidget);
        expect(find.text('₹850.00'), findsNWidgets(2),
            reason: '₹600 + ₹250 still owed: the total, and all of it Arun\'s');
        expect(find.text('2 open · 1 person'), findsOneWidget);
        expect(find.text('Arun'), findsOneWidget, reason: '"arun" and "Arun" are one person');
        // Money lent and a purchase, side by side: both paid for Arun.
        expect(find.text('Lent to Arun'), findsOneWidget);
        expect(find.text('Team lunch'), findsOneWidget);
        expect(find.text('Partly repaid'), findsNWidgets(2));
        expect(find.text('Overdue by 2 days'), findsOneWidget);
        expect(find.textContaining('HDFC Salary Account •••• 6459'), findsOneWidget);
        await scrollTo(tester, find.text('Record repayment').last);
        expect(find.text('Record repayment'), findsWidgets);
        expect(find.text('Concert tickets'), findsNothing, reason: 'settled, so not still owed');
        await scrollTo(tester, find.text('Settled'), delta: -200);

        await tester.tap(find.text('Settled'));
        await tester.pumpAndSettle();
        expect(find.text('Concert tickets'), findsOneWidget);
        expect(find.text('Lent to Arun'), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('records a repayment as money in, never more than is owed',
        (WidgetTester tester) async {
      await harness.pump(tester, const ExpensesScreen());
      await tester.tap(find.text('Paid for someone'));
      await tester.pumpAndSettle();
      // Arun's loan — listed after the newer lunch: ₹600 of ₹1,000 still owed.
      await tester.ensureVisible(find.text('Record repayment').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Record repayment').last);
      await tester.pumpAndSettle();
      expect(find.text('Repayment from Arun'), findsOneWidget);
      expect(find.text('₹600.00 left of ₹1,000.00 · not income'), findsOneWidget);
      expect(find.text('This settles it.'), findsOneWidget);

      // ₹700 is more than is owed: refused, nothing written.
      final Finder amount =
          find.descendant(of: find.byType(RepaymentSheet), matching: find.byType(TextField)).first;
      await tester.enterText(amount, '700');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Record repayment').last);
      await tester.pumpAndSettle();
      expect(find.text('Only ₹600.00 is still owed. If more came back, it may already be recorded.'),
          findsOneWidget);
      expect(harness.ledger.movements, isEmpty);

      // ₹200 back into the account it was lent from.
      await tester.enterText(amount, '200');
      await tester.pumpAndSettle();
      expect(find.text('₹400.00 will still be owed.'), findsOneWidget);
      await tester.tap(find.text('Record repayment').last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final Map<String, Object?> written = harness.ledger.movements.single;
      expect(written['accountId'], 'a1');
      expect(written['direction'], LedgerDirection.credit);
      expect(written['amount'], 200);
      expect(written['description'], 'Repayment from Arun');
      expect(written['treatment'], <String, Object?>{'type': 'settlement', 'receivable_id': 'c1'});
      expect(find.text('Repayment recorded'), findsOneWidget);
    });

    testWidgets('what was paid for someone opens its expense', (WidgetTester tester) async {
      await harness.pump(tester, const ExpensesScreen());
      await tester.tap(find.text('Paid for someone'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Team lunch'));
      await tester.pumpAndSettle();
      expect(find.text('Edit expense'), findsOneWidget);
    });
  });

  group('expense form', () {
    testWidgets('an edit of a paid-for purchase shows who, its repayments and its tags',
        (WidgetTester tester) async {
      await harness.pump(tester, ExpenseFormScreen(expense: lunch));
      expect(tester.takeException(), isNull);

      await scrollTo(tester, find.text('Paid for someone else'));
      expect(chipSelected(tester, 'Paid for someone else'), isTrue);
      expect(find.widgetWithText(TextField, 'arun'), findsOneWidget,
          reason: 'spelled as the claim has it');
      expect(find.text('₹150.00 of ₹400.00 paid back · Partly repaid'), findsOneWidget);
      await scrollTo(tester, find.text('Record repayment'));
      expect(find.text('Record repayment'), findsOneWidget);
      expect(find.text('Paid for arun'), findsOneWidget);

      await scrollTo(tester, find.text('#office'));
      expect(find.text('#office'), findsOneWidget);
      expect(find.text('#family'), findsOneWidget);

      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      expect(harness.popped, isTrue);
      final (String id, PaidForDraft? draft) = harness.receivables.writes.single;
      expect(id, 'e9');
      expect(draft!.person, 'arun');
      expect(draft.note, 'Split later', reason: 'the form does not edit it, so it is kept');
      expect(harness.tags.sets.single.$3, <String>['office', 'family']);
    });

    testWidgets('the amount cannot drop below what was already paid back',
        (WidgetTester tester) async {
      await harness.pump(tester, ExpenseFormScreen(expense: lunch));
      await tester.enterText(find.byType(TextField).first, '100');
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      await scrollTo(tester, find.textContaining('has already been paid back'));
      expect(find.text('₹150.00 has already been paid back, so the amount cannot be less than that.'),
          findsOneWidget);
      expect(harness.expenses.saved, isEmpty);
    });

    testWidgets('turning it off unmarks the purchase, and says where repaid money goes',
        (WidgetTester tester) async {
      await harness.pump(tester, ExpenseFormScreen(expense: lunch));
      await scrollTo(tester, find.text('Paid for someone else'));
      await tester.tap(find.text('Paid for someone else'));
      await tester.pumpAndSettle();
      expect(find.textContaining('₹150.00 already paid back stays as plain money in'), findsOneWidget);
      expect(find.text('Record repayment'), findsNothing);

      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      expect(harness.receivables.writes.single, ('e9', null));
    });

    testWidgets('a new one (a purchase or money lent) needs a name, and offers the people already used',
        (WidgetTester tester) async {
      await harness.pump(tester, const ExpenseFormScreen(), width: 320);
      await tester.enterText(find.byType(TextField).first, '250');
      await tester.tap(find.text('Food'));
      await scrollTo(tester, find.text('Paid for someone else'));
      expect(chipSelected(tester, 'Paid for someone else'), isFalse);
      await tester.tap(find.text('Paid for someone else'));
      await tester.pumpAndSettle();
      await scrollTo(tester, find.textContaining('or money you lent them'));
      expect(find.textContaining('or money you lent them'), findsOneWidget);

      await tester.tap(find.text('Add expense').last);
      await tester.pumpAndSettle();
      await scrollTo(tester, find.text('Add who you paid for.'));
      expect(find.text('Add who you paid for.'), findsOneWidget);
      expect(harness.expenses.saved, isEmpty);

      // As last written: the newest claim spells it "arun".
      await scrollTo(tester, find.widgetWithText(AppChoiceChip, 'arun'), delta: -200);
      expect(find.widgetWithText(AppChoiceChip, 'Bea'), findsOneWidget);
      await tester.tap(find.widgetWithText(AppChoiceChip, 'arun'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Add expense').last);
      await tester.pumpAndSettle();
      expect(harness.popped, isTrue);
      expect(harness.receivables.writes.single.$1, 'new1');
      expect(harness.receivables.writes.single.$2!.person, 'arun');
      expect(harness.tags.sets.single.$3, isEmpty);
    });

    testWidgets('when the claim cannot be read nothing about it is shown or changed',
        (WidgetTester tester) async {
      harness.receivables.failRead = true;
      await harness.pump(tester, ExpenseFormScreen(expense: lunch));
      expect(find.text('Paid for someone else'), findsNothing);
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      expect(harness.popped, isTrue);
      expect(harness.receivables.writes, isEmpty);
    });
  });

  testWidgets('the income form shows and saves its tags', (WidgetTester tester) async {
    final Income salary = Income(
      id: 'i5',
      userId: 'u1',
      amount: 50000,
      incomeDate: daysAgo(5),
      source: 'Salary',
    );
    await harness.pump(tester, IncomeFormScreen(income: salary));
    await scrollTo(tester, find.text('#salary'));
    expect(find.text('#salary'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Add tags'), 'bonus');
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(harness.popped, isTrue);
    final (TagKind kind, String id, List<String> names) = harness.tags.sets.single;
    expect((kind, id), (TagKind.income, 'i5'));
    expect(names, <String>['salary', 'bonus'], reason: 'typed but not confirmed counts');
  });

  testWidgets('Accounts has no separate loans or "owed to you" section', (WidgetTester tester) async {
    SchemaCapabilities.debugOverride(bankAccounts: true, expenseBankLink: true);
    await harness.pump(tester, const AccountsScreen());
    expect(tester.takeException(), isNull);
    expect(find.text('Owed to you'), findsNothing);
    expect(find.byTooltip('Owed to you'), findsNothing);
    expect(find.textContaining('Loan'), findsNothing);
  });
}
