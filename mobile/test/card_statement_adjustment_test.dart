// Card statement (bill) adjustments (migration 023) and dates with their
// weekday: a statement confirmed from the bank's figure is the bill that is
// due, paid against and carried into the outstanding, never spending; the
// app's own figure stays visible beside it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/core/utils/formatters.dart';
import 'package:expense_tracker/models/bank_account.dart';
import 'package:expense_tracker/models/card_statement.dart';
import 'package:expense_tracker/models/credit_card.dart';
import 'package:expense_tracker/models/expense.dart';
import 'package:expense_tracker/models/ledger_entry.dart';
import 'package:expense_tracker/providers/credit_card_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/repositories/credit_card_repository.dart';
import 'package:expense_tracker/repositories/expense_repository.dart';
import 'package:expense_tracker/repositories/ledger_repository.dart';
import 'package:expense_tracker/repositories/profile_repository.dart';
import 'package:expense_tracker/screens/cards/statement_adjustment_sheet.dart';
import 'package:expense_tracker/services/preferences_service.dart';
import 'package:expense_tracker/services/schema_capabilities.dart';

/// Statement on the 20th, due on the 8th — the HDFC card of the request.
const CreditCard card = CreditCard(
  id: 'c1',
  userId: 'u1',
  cardName: 'HDFC Regalia',
  issuer: 'HDFC',
  last4: '2008',
  creditLimit: 371000,
  statementDay: 20,
  paymentDueDay: 8,
);

const BankAccount salary = BankAccount(
  id: 'a1',
  userId: 'u1',
  bankName: 'HDFC',
  nickname: 'Salary',
  last4: '6459',
  openingBalance: 50000,
);

DateTime d(int month, int day, [int year = 2026]) => DateTime(year, month, day);

Expense purchase(String id, double amount, DateTime date) => Expense(
      id: id,
      userId: 'u1',
      amount: amount,
      expenseDate: date,
      categoryId: 'food',
      creditCardId: 'c1',
    );

/// The card row the database keeps for the 20 Nov statement's adjustment.
CardEntry adjustmentRow(double amount, {LedgerDirection direction = LedgerDirection.debit}) =>
    CardEntry.fromCardTransaction(CardTransaction(
      id: 't-adj',
      userId: 'u1',
      cardId: 'c1',
      kind: CardTransactionKind.adjustment,
      direction: direction,
      amount: amount,
      txnDate: d(11, 20),
      statementDate: d(11, 20),
      description: 'Statement adjustment · As per HDFC statement',
      statementAdjustmentId: 'adj-1',
    ));

CardEntry bankPayment(String id, double amount, DateTime date) => CardEntry.fromPayment(LedgerEntry(
      id: id,
      userId: 'u1',
      accountId: 'a1',
      direction: LedgerDirection.debit,
      amount: amount,
      txnDate: date,
      creditCardId: 'c1',
    ))!;

SupabaseClient _client() => SupabaseClient(
      'http://localhost:54321',
      'test-anon-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );

String money(double v) => Formatters.currency(v);

void main() {
  // The app works out ₹15,000 for the 21 Oct – 20 Nov cycle; the bank printed ₹16,000.
  final List<Expense> purchases = <Expense>[
    purchase('e1', 9000, d(10, 27)),
    purchase('e2', 6000, d(11, 4)),
  ];
  final List<CardEntry> calculatedOnly = purchases.map((Expense e) => CardEntry.fromExpense(e)!).toList();
  final List<CardEntry> adjusted = <CardEntry>[...calculatedOnly, adjustmentRow(1000)];

  group('a confirmed bill', () {
    test('is the statement balance and what is still to pay', () {
      final CardSummary summary = summariseCard(card, adjusted, d(11, 22));
      expect(summary.lastStatement.cycle.end, d(11, 20));
      expect(summary.lastStatement.balance, 16000);
      expect(summary.lastStatement.remaining, 16000);
      expect(
        calculatedStatementBalance(summary.lastStatement.balance, adjusted, d(11, 20)),
        15000,
      );
    });

    test('the outstanding is the calculated figure plus the difference', () {
      final double calculated = outstandingOf(0, calculatedOnly);
      expect(calculated, 15000);
      expect(outstandingOf(0, adjusted), calculated + 1000);
      expect(statementBalanceOn(0, adjusted, d(11, 20)), 16000);
    });

    test('a bill lowered by the bank works the same way', () {
      final List<CardEntry> lowered = <CardEntry>[
        ...calculatedOnly,
        adjustmentRow(500, direction: LedgerDirection.credit),
      ];
      expect(summariseCard(card, lowered, d(11, 22)).lastStatement.balance, 14500);
      expect(calculatedStatementBalance(14500, lowered, d(11, 20)), 15000);
    });

    test('paying the confirmed amount pays it in full', () {
      final List<CardEntry> paid = <CardEntry>[...adjusted, bankPayment('l1', 16000, d(12, 2))];
      final CardSummary summary = summariseCard(card, paid, d(12, 3));
      expect(summary.lastStatement.remaining, 0);
      expect(summary.lastStatement.status, DueStatus.paid);
      final List<CardBillPaymentRow> rows = cardBillPayments(
        entries: paid,
        cards: const <CreditCard>[card],
        accounts: const <BankAccount>[salary],
      );
      expect(rows.single.status, BillPaymentStatus.full);
      expect(summary.outstanding, 0);
    });

    test('paying only the calculated amount leaves the difference to pay', () {
      final List<CardEntry> paid = <CardEntry>[...adjusted, bankPayment('l1', 15000, d(12, 2))];
      expect(summariseCard(card, paid, d(12, 3)).lastStatement.remaining, 1000);
      final List<CardBillPaymentRow> rows = cardBillPayments(
        entries: paid,
        cards: const <CreditCard>[card],
        accounts: const <BankAccount>[salary],
      );
      expect(rows.single.status, BillPaymentStatus.partial);
    });

    test('is never spending and never a bill payment', () {
      // Spending is the expenses alone; the adjustment is a card row.
      final double spending = purchases.fold<double>(0, (double s, Expense e) => s + e.amount);
      expect(spending, 15000);
      expect(adjusted.where((CardEntry e) => e.expense != null).length, 2);
      final CardEntry row = adjusted.last;
      expect(row.isStatementAdjustment, isTrue);
      expect(row.title, 'Statement adjustment · As per HDFC statement');
      expect(
        cardBillPayments(entries: adjusted, cards: const <CreditCard>[card], accounts: const <BankAccount>[salary]),
        isEmpty,
      );
      expect(findRecordedPayments(adjusted, cardId: 'c1', amount: 1000, date: d(11, 20)), isEmpty);
    });

    test('nothing adjusted: the calculated figure is the balance', () {
      expect(calculatedStatementBalance(15000, calculatedOnly, d(11, 20)), 15000);
      expect(statementAdjustmentOn(const <CardStatementAdjustment>[], 'c1', d(11, 20)), isNull);
    });

    test('the history row is read as the database stores it', () {
      final CardStatementAdjustment a = CardStatementAdjustment.fromMap(<String, dynamic>{
        'id': 'adj-1',
        'card_id': 'c1',
        'statement_date': '2026-11-20',
        'target_balance': '16000.00',
        'calculated_balance': 15000,
        'remarks': '  ',
      });
      expect(a.targetBalance, 16000);
      expect(a.calculatedBalance, 15000);
      expect(a.remarks, isNull);
      expect(statementAdjustmentOn(<CardStatementAdjustment>[a], 'c1', d(11, 20)), same(a));
      expect(statementAdjustmentOn(<CardStatementAdjustment>[a], 'c2', d(11, 20)), isNull);
    });

    test('the sheet says what the typed amount does', () {
      expect(billAdjustmentLine(15000, 16000, money), 'Adds ₹1,000.00 to this bill');
      expect(billAdjustmentLine(15000, 14000, money), 'Lowers this bill by ₹1,000.00');
      expect(billAdjustmentLine(15000, 15000, money), "Matches the app's figure");
      expect(billAdjustedLine(15000, money), 'Calculated by the app: ₹15,000.00 · confirmed from your statement');
    });
  });

  group('dates with their weekday', () {
    final DateTime today = d(11, 22);

    test('this year: day, month and weekday', () {
      expect(Formatters.dayDate(d(11, 22), today: today), '22 Nov · Sunday');
      expect(Formatters.dayDate(d(1, 1), today: today), '1 Jan · Thursday');
      expect(Formatters.dayDate(d(12, 31), today: today), '31 Dec · Thursday');
    });

    test('another year: with the year', () {
      expect(Formatters.dayDate(d(11, 22, 2025), today: today), '22 Nov 2025 · Saturday');
      expect(Formatters.dayDate(d(12, 31, 2025), today: today), '31 Dec 2025 · Wednesday');
      expect(Formatters.dayDate(d(1, 1, 2027), today: today), '1 Jan 2027 · Friday');
    });
  });

  group('screens', () {
    late PreferencesService preferences;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      preferences = await PreferencesService.create();
      SchemaCapabilities.debugReset();
    });

    tearDown(SchemaCapabilities.debugReset);

    Future<void> pump(WidgetTester tester, Widget child) async {
      tester.view.physicalSize = const Size(360 * 2, 720 * 2);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final SupabaseClient client = _client();
      await tester.pumpWidget(MultiProvider(
        providers: <ChangeNotifierProvider<dynamic>>[
          ChangeNotifierProvider<SettingsProvider>(
            create: (_) => SettingsProvider(repository: ProfileRepository(client), preferences: preferences),
          ),
          ChangeNotifierProvider<CreditCardProvider>(
            create: (_) => CreditCardProvider(
              repository: CreditCardRepository(
                client,
                expenses: ExpenseRepository(client),
                ledger: LedgerRepository(client),
              ),
              ledger: LedgerRepository(client),
            ),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: child)),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('no Adjust bill before migration 023', (WidgetTester tester) async {
      SchemaCapabilities.debugOverride(creditCards: true, cardStatementAdjustments: false);
      await pump(
        tester,
        StatementBillAdjustment(card: card, statementEnd: d(11, 20), balance: 15000, onChanged: () {}),
      );
      expect(find.text('Adjust bill'), findsNothing);
    });

    testWidgets('Adjust bill once the migration is in', (WidgetTester tester) async {
      SchemaCapabilities.debugOverride(creditCards: true, cardStatementAdjustments: true);
      await pump(
        tester,
        StatementBillAdjustment(card: card, statementEnd: d(11, 20), balance: 15000, onChanged: () {}),
      );
      expect(find.text('Adjust bill'), findsOneWidget);
      expect(find.text('Adjusted'), findsNothing);
    });

    testWidgets('the sheet shows the calculated bill and what the typed one does', (WidgetTester tester) async {
      SchemaCapabilities.debugOverride(creditCards: true, cardStatementAdjustments: true);
      await pump(
        tester,
        StatementAdjustmentSheet(card: card, statementEnd: d(11, 20), calculated: 15000),
      );
      expect(find.text('Adjust bill'), findsOneWidget);
      expect(find.text('Statement of 20 Nov 2026'), findsOneWidget);
      expect(find.text('Calculated by the app'), findsOneWidget);
      expect(find.text('Use calculated amount'), findsNothing);

      await tester.enterText(find.byKey(const ValueKey<String>('adjust-bill-amount')), '16000');
      await tester.pump();
      expect(find.text('Adds ₹1,000.00 to this bill'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey<String>('adjust-bill-amount')), '14000');
      await tester.pump();
      expect(find.text('Lowers this bill by ₹1,000.00'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey<String>('adjust-bill-amount')), '15000');
      await tester.pump();
      expect(find.text("Matches the app's figure"), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an adjusted bill can go back to the calculated one', (WidgetTester tester) async {
      SchemaCapabilities.debugOverride(creditCards: true, cardStatementAdjustments: true);
      await pump(
        tester,
        StatementAdjustmentSheet(
          card: card,
          statementEnd: d(11, 20),
          calculated: 15000,
          adjustment: CardStatementAdjustment(
            id: 'adj-1',
            cardId: 'c1',
            statementDate: d(11, 20),
            targetBalance: 16000,
            calculatedBalance: 15000,
            remarks: 'As per HDFC statement',
          ),
        ),
      );
      expect(find.text('Adds ₹1,000.00 to this bill'), findsOneWidget);
      expect(find.text('Use calculated amount'), findsOneWidget);
    });
  });
}
