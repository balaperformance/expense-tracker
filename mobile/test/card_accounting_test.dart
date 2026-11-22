// Credit card accounting (migration 022): purchases are spending on their
// own dates, a bill payment lowers the bank balance and the card outstanding
// exactly once and is never spending, EMI instalments (charges included from
// the 20 Oct 2026 cycle) are spending while the converted purchase is not,
// and every bill payment stays visible for the record.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/models/analytics.dart';
import 'package:expense_tracker/models/bank_account.dart';
import 'package:expense_tracker/models/card_statement.dart';
import 'package:expense_tracker/models/credit_card.dart';
import 'package:expense_tracker/models/emi_plan.dart';
import 'package:expense_tracker/models/expense.dart';
import 'package:expense_tracker/models/expense_category.dart';
import 'package:expense_tracker/models/ledger_entry.dart';
import 'package:expense_tracker/models/payment_method.dart';
import 'package:expense_tracker/providers/bank_account_provider.dart';
import 'package:expense_tracker/providers/card_import_provider.dart';
import 'package:expense_tracker/providers/credit_card_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/repositories/bank_account_repository.dart';
import 'package:expense_tracker/repositories/credit_card_repository.dart';
import 'package:expense_tracker/repositories/emi_plan_repository.dart';
import 'package:expense_tracker/repositories/expense_repository.dart';
import 'package:expense_tracker/repositories/ledger_repository.dart';
import 'package:expense_tracker/repositories/profile_repository.dart';
import 'package:expense_tracker/repositories/receivable_repository.dart';
import 'package:expense_tracker/repositories/tag_repository.dart';
import 'package:expense_tracker/screens/cards/card_payment_sheet.dart';
import 'package:expense_tracker/services/preferences_service.dart';
import 'package:expense_tracker/services/schema_capabilities.dart';
import 'package:expense_tracker/services/statement_import/statement_engine.dart';
import 'package:expense_tracker/widgets/card_bill_payments.dart';
import 'package:expense_tracker/widgets/expense_fields.dart';
import 'package:expense_tracker/widgets/transaction_tile.dart';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

/// Statement on the 20th, due on the 5th: the 21 Oct – 20 Nov cycle's bill
/// is due 5 Dec.
const CreditCard card = CreditCard(
  id: 'c1',
  userId: 'u1',
  cardName: 'Amazon Pay',
  issuer: 'ICICI',
  last4: '4821',
  creditLimit: 100000,
  statementDay: 20,
  paymentDueDay: 5,
);

const BankAccount salary = BankAccount(
  id: 'a1',
  userId: 'u1',
  bankName: 'HDFC',
  nickname: 'Salary',
  last4: '6459',
  openingBalance: 50000,
);

DateTime d(int month, int day) => DateTime(2026, month, day);

Expense purchase(String id, double amount, DateTime date,
        {String category = 'food', bool personal = true, String? plan, String? component}) =>
    Expense(
      id: id,
      userId: 'u1',
      amount: amount,
      expenseDate: date,
      categoryId: category,
      creditCardId: 'c1',
      isPersonal: personal,
      emiPlanId: plan,
      emiComponent: component,
    );

CardEntry bankPayment(String id, double amount, DateTime date) => CardEntry.fromPayment(LedgerEntry(
      id: id,
      userId: 'u1',
      accountId: 'a1',
      direction: LedgerDirection.debit,
      amount: amount,
      txnDate: date,
      creditCardId: 'c1',
    ))!;

CardEntry cardPayment(String id, double amount, DateTime date) => CardEntry.fromCardTransaction(CardTransaction(
      id: id,
      userId: 'u1',
      cardId: 'c1',
      kind: CardTransactionKind.payment,
      direction: LedgerDirection.credit,
      amount: amount,
      txnDate: date,
    ));

CardEntry spend(Expense e) => CardEntry.fromExpense(e)!;

/// Opening balance plus every ledger movement, in cents — the bank balance.
double balanceOf(BankAccount account, Iterable<LedgerEntry> ledger) {
  int cents = (account.openingBalance * 100).round();
  for (final LedgerEntry e in ledger) {
    final int amount = (e.amount * 100).round();
    cents += e.isDebit ? -amount : amount;
  }
  return cents / 100;
}

const List<ExpenseCategory> categories = <ExpenseCategory>[
  ExpenseCategory(id: 'food', userId: 'u1', name: 'Food'),
  ExpenseCategory(id: 'shop', userId: 'u1', name: 'Shopping'),
];

void main() {
  // -------------------------------------------------------------------------
  // What counts as a card bill payment
  // -------------------------------------------------------------------------
  group('card bill wording', () {
    test('bank narrations, alerts and third-party rails are bill payments', () {
      for (final String text in <String>[
        'Rs.5000 debited from a/c XX6459 towards HDFC Credit Card XX4821',
        'Payment of Rs 5000 to your credit card bill is successful',
        'CC payment of INR 5000 received',
        'UPI/CRED Club/cred.club@axisb/Payment',
        'CRED/4821/NEFT',
        'BillDesk credit card payment ICICI',
        'BBPS credit card bill pay 4821',
        'PAYZAPP CC BILL 4821',
        'Amazon Pay credit card bill',
        'PhonePe credit card payment',
        'CCBILL HDFC 4821',
        'card bill',
        'credit card payment',
      ]) {
        expect(looksLikeCardBillPayment(text), isTrue, reason: text);
      }
    });

    test('spending, rewards and look-alike words are not', () {
      for (final String text in <String>[
        'Rs 500 spent on HDFC Bank Credit Card XX4821 at AMAZON on 03-10-26.',
        'Sent Rs.2900.00 From HDFC Bank A/C *6459 To CHENNAI KEY MAKERS',
        'Credit card cashback of Rs 150 credited',
        'Credence Foods lunch',
        'incredible deals store',
        'EMI conversion credit card 4821',
      ]) {
        expect(looksLikeCardBillPayment(text), isFalse, reason: text);
      }
    });

    test('the rail a bill went through, and bill categories', () {
      expect(cardBillRail('UPI/CRED Club/payment'), 'CRED');
      expect(cardBillRail('BILLDESK*ICICI CC'), 'BillDesk');
      expect(cardBillRail('BBPS bill'), 'BBPS');
      expect(cardBillRail('HDFC CC PAYMENT'), isNull);
      expect(isCardBillCategoryName('Credit card bill'), isTrue);
      expect(isCardBillCategoryName('Card payment'), isTrue);
      expect(isCardBillCategoryName('Groceries'), isFalse);
      expect(
        ExpenseFields.looksLikeBillPayment(description: 'CRED payment'),
        isTrue,
      );
      expect(ExpenseFields.looksLikeBillPayment(categoryName: 'Credit card bill'), isTrue);
      expect(ExpenseFields.looksLikeBillPayment(merchant: 'Big Bazaar', categoryName: 'Food'), isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // Purchases, the bill and the payment
  // -------------------------------------------------------------------------
  group('purchases on their dates, the bill paid next month', () {
    // October 20 – November 20 purchases, the bill paid on 5 December.
    final Expense oct = purchase('e1', 3000, d(10, 25));
    final Expense nov = purchase('e2', 2000, d(11, 10), category: 'shop');
    final LedgerEntry payDebit = LedgerEntry(
      id: 'l1',
      userId: 'u1',
      accountId: 'a1',
      direction: LedgerDirection.debit,
      amount: 5000,
      txnDate: d(12, 5),
      creditCardId: 'c1',
    );

    test('each purchase is spending in its own month; the payment is in none', () {
      final List<Expense> expenses = <Expense>[oct, nov];
      final Map<String, double> byMonth = <String, double>{};
      for (final Expense e in personalSpending(expenses, const <String>{})) {
        final String key = '${e.expenseDate.year}-${e.expenseDate.month}';
        byMonth[key] = (byMonth[key] ?? 0) + e.amount;
      }
      expect(byMonth, <String, double>{'2026-10': 3000, '2026-11': 2000});
      // December has no expense at all: the bill payment is a ledger debit.
      expect(byMonth.containsKey('2026-12'), isFalse);
      final List<CategorySpend> breakdown = buildCategoryBreakdown(expenses, categories);
      expect(breakdown.map((CategorySpend c) => c.total).fold<double>(0, (double s, double v) => s + v), 5000);
    });

    test('the payment lowers the bank balance and the outstanding once', () {
      final List<CardEntry> entries = <CardEntry>[spend(oct), spend(nov)];
      expect(outstandingOf(0, entries), 5000);
      expect(balanceOf(salary, const <LedgerEntry>[]), 50000);

      final List<CardEntry> paid = <CardEntry>[...entries, CardEntry.fromPayment(payDebit)!];
      expect(outstandingOf(0, paid), 0);
      expect(balanceOf(salary, <LedgerEntry>[payDebit]), 45000);
      final CardSummary summary = summariseCard(card, paid, d(12, 6));
      expect(summary.lastStatement.status, DueStatus.paid);
    });

    test('partial, then full: the status follows what the bill still needs', () {
      final List<CardEntry> entries = <CardEntry>[
        spend(oct),
        spend(nov),
        bankPayment('l1', 2000, d(12, 1)),
        cardPayment('t1', 3000, d(12, 4)),
      ];
      final List<CardBillPaymentRow> rows = cardBillPayments(
        entries: entries,
        cards: const <CreditCard>[card],
        accounts: const <BankAccount>[salary],
      );
      expect(rows.map((CardBillPaymentRow r) => r.status), <BillPaymentStatus>[
        BillPaymentStatus.full, // 4 Dec, newest first
        BillPaymentStatus.partial,
      ]);
      expect(rows.first.accountLabel, untrackedPaymentSource);
      expect(rows.last.accountLabel, 'Salary •••• 6459');
      expect(rows.last.cardLabel, 'Amazon Pay •••• 4821');
      expect(rows.every((CardBillPaymentRow r) => !r.possibleDuplicate), isTrue);
      expect(billPaymentsTotal(rows), 5000);
      expect(BillPaymentStatus.partial.label, 'Partially paid');
      expect(BillPaymentStatus.full.label, 'Paid in full');
    });

    test('paid before any bill is due: an advance', () {
      final List<CardBillPaymentRow> rows = cardBillPayments(
        entries: <CardEntry>[spend(nov), bankPayment('l1', 1000, d(11, 12))],
        cards: const <CreditCard>[card],
        accounts: const <BankAccount>[salary],
      );
      expect(rows.single.status, BillPaymentStatus.advance);
      expect(BillPaymentStatus.advance.label, 'Advance payment');
    });

    test('the period filters the record, and only payments are listed', () {
      final List<CardEntry> entries = <CardEntry>[
        spend(oct),
        bankPayment('l1', 3000, d(11, 5)),
        bankPayment('l2', 2000, d(12, 5)),
      ];
      final List<CardBillPaymentRow> dec = cardBillPayments(
        entries: entries,
        cards: const <CreditCard>[card],
        accounts: const <BankAccount>[salary],
        from: d(12, 1),
        to: d(12, 31),
      );
      expect(dec.map((CardBillPaymentRow r) => r.entryId), <String>['l2']);
    });
  });

  // -------------------------------------------------------------------------
  // The same bill stored twice
  // -------------------------------------------------------------------------
  group('duplicate bill payments', () {
    test('a bank-side and a card-side payment of the same bill are flagged both ways', () {
      final List<CardBillPaymentRow> rows = cardBillPayments(
        entries: <CardEntry>[
          bankPayment('l1', 5000, d(12, 5)),
          cardPayment('t1', 5000, d(12, 1)),
          cardPayment('t2', 700, d(12, 2)),
        ],
        cards: const <CreditCard>[card],
        accounts: const <BankAccount>[salary],
      );
      final CardBillPaymentRow bank = rows.firstWhere((CardBillPaymentRow r) => r.entryId == 'l1');
      final CardBillPaymentRow cardSide = rows.firstWhere((CardBillPaymentRow r) => r.entryId == 't1');
      expect(bank.duplicateOfId, 'card:t1');
      expect(cardSide.duplicateOfId, 'account:l1');
      expect(rows.firstWhere((CardBillPaymentRow r) => r.entryId == 't2').possibleDuplicate, isFalse);
    });

    test('recorded payments are found within 10 days, same card and amount, closest first', () {
      final List<CardEntry> entries = <CardEntry>[
        bankPayment('l1', 5000, d(12, 9)),
        cardPayment('t1', 5000, d(12, 4)),
        cardPayment('t2', 5000, d(12, 20)), // 15 days off
        cardPayment('t3', 4999, d(12, 5)), // another amount
        spend(purchase('e1', 5000, d(12, 5))), // a purchase, not a payment
      ];
      final List<CardEntry> found =
          findRecordedPayments(entries, cardId: 'c1', amount: 5000, date: d(12, 5));
      expect(found.map((CardEntry e) => e.id), <String>['t1', 'l1']);
      expect(findRecordedPayments(entries, cardId: 'other', amount: 5000, date: d(12, 5)), isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // EMI
  // -------------------------------------------------------------------------
  group('EMI', () {
    const EmiPlan plan = EmiPlan(id: 'p1', userId: 'u1', cardId: 'c1', title: 'Laptop');
    final Expense converted = purchase('e0', 60000, d(10, 2), category: 'shop', plan: 'p1', component: 'conversion');
    final CardEntry conversionCredit = CardEntry.fromCardTransaction(CardTransaction(
      id: 't0',
      userId: 'u1',
      cardId: 'c1',
      kind: CardTransactionKind.adjustment,
      direction: LedgerDirection.credit,
      amount: 60000,
      txnDate: d(10, 25),
      emiPlanId: 'p1',
      emiComponent: 'conversion',
    ));
    // November's instalment, under the new rules: every part an expense.
    final Expense principal = purchase('e1', 5000, d(11, 15), category: 'shop', plan: 'p1', component: 'principal');
    final Expense interest = purchase('e2', 450, d(11, 15), category: 'shop', plan: 'p1', component: 'interest');
    final Expense gst = purchase('e3', 81, d(11, 15), category: 'shop', plan: 'p1', component: 'tax');

    test('the cutover is the 20 Oct 2026 cycle', () {
      expect(underCardRules(d(10, 19)), isFalse);
      expect(underCardRules(d(10, 20)), isTrue);
      expect(underCardRules(DateTime(2026, 10, 20, 23, 59)), isTrue);
    });

    test('the converted purchase is no instalment and no spending; the instalment is', () {
      final List<CardEntry> entries = <CardEntry>[
        spend(converted),
        conversionCredit,
        spend(principal),
        spend(interest),
        spend(gst),
      ];
      final List<EmiInstallment> installments = installmentsOf(plan, entries, card);
      expect(installments, hasLength(1));
      expect(installments.single.principal, 5000);
      expect(installments.single.interest, 450);
      expect(installments.single.tax, 81);
      expect(installments.single.total, 5531);
      // The card still holds every row once: the purchase and its reversal cancel.
      expect(outstandingOf(0, entries), 5531);

      final EmiPlanSummary summary = summariseEmiPlan(plan: plan, entries: entries, card: card);
      expect(summary.convertedPurchase?.id, 'e0');
      expect(
        emiConvertedFromText(summary, (DateTime x) => '${x.day} Oct'),
        'Converted from ${summary.convertedPurchase!.title} · 2 Oct',
      );

      // Spending: the database's excluded ids name the converted purchase.
      final List<Expense> spent = personalSpending(
        <Expense>[converted, principal, interest, gst],
        <String>{converted.id},
      );
      expect(spent.fold<double>(0, (double s, Expense e) => s + e.amount), 5531);
      expect(converted.isConvertedToEmi, isTrue);
      expect(principal.isConvertedToEmi, isFalse);
    });

    test('statement lines never fold the converted purchase into an instalment', () {
      final List<CardEntry> entries = <CardEntry>[spend(converted), conversionCredit, spend(principal), spend(interest)];
      final CardStatement statement = buildCardStatement(openingOutstanding: 0, entries: entries);
      final List<StatementLine> lines = statementLines(statement.rows, card);
      expect(lines.whereType<InstallmentLine>(), hasLength(1));
      expect(lines.whereType<EntryLine>().map((EntryLine l) => l.row.entry.id), containsAll(<String>['e0', 't0']));
    });

    test('what someone else owes: charges only when the plan includes them, the conversion never', () {
      final List<CardEntry> entries = <CardEntry>[spend(converted), conversionCredit, spend(principal), spend(interest), spend(gst)];
      final List<EmiInstallment> installments = installmentsOf(plan, entries, card);
      expect(emiClaimPrincipal(true, installments), 5531);
      expect(emiClaimPrincipal(false, installments), 5000);
      // The repository reads the same rule off the rows (claim_principal).
      expect(ReceivableRepository.emiExpenseOwed(null, false), isTrue);
      expect(ReceivableRepository.emiExpenseOwed('principal', false), isTrue);
      expect(ReceivableRepository.emiExpenseOwed('interest', false), isFalse);
      expect(ReceivableRepository.emiExpenseOwed('interest', true), isTrue);
      expect(ReceivableRepository.emiExpenseOwed('fee', true), isTrue);
      expect(ReceivableRepository.emiExpenseOwed('conversion', true), isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // Personal, paid for someone, someone else's money
  // -------------------------------------------------------------------------
  group('whose spending', () {
    test('paid for someone and someone else\'s money stay out; own purchases count', () {
      final List<Expense> expenses = <Expense>[
        purchase('own', 1000, d(11, 1)),
        purchase('forArun', 800, d(11, 2)),
        purchase('theirs', 600, d(11, 3), personal: false),
      ];
      final List<Expense> mine = personalSpending(expenses, <String>{'forArun'});
      expect(mine.map((Expense e) => e.id), <String>['own']);
      // On the card, all three are owed to the issuer.
      expect(outstandingOf(0, expenses.map(spend)), 2400);
    });

    test('the excluded-ids function\'s response is read as plain ids or rows', () {
      expect(ExpenseRepository.excludedIdsFromRpc(<Object?>['a', 'b', 'a']), <String>{'a', 'b'});
      expect(
        ExpenseRepository.excludedIdsFromRpc(<Object?>[
          <String, Object?>{'spending_excluded_expense_ids': 'x'},
        ]),
        <String>{'x'},
      );
      expect(ExpenseRepository.excludedIdsFromRpc(null), isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // The card import's writes
  // -------------------------------------------------------------------------
  group('card import writes', () {
    late _Engine engine;
    late _Expenses expenses;
    late _Ledger ledger;
    late CardImportProvider provider;

    setUp(() {
      SchemaCapabilities.debugReset();
      SchemaCapabilities.debugOverride(
        creditCards: true,
        treatments: true,
        emi: true,
        balanceAdjustments: true,
        cardAccounting: true,
      );
      final SupabaseClient client = _client();
      engine = _Engine();
      expenses = _Expenses(client);
      ledger = _Ledger(client);
      provider = CardImportProvider(
        engine: engine,
        expenses: expenses,
        ledger: ledger,
        cards: _Cards(client, expenses: expenses, ledger: ledger),
        plans: EmiPlanRepository(client),
        tags: TagRepository(client),
        receivables: ReceivableRepository(client),
      );
    });

    tearDown(SchemaCapabilities.debugReset);

    Future<void> run(List<Map<String, Object?>> operations) async {
      await provider.start(
        userId: 'u1',
        card: card,
        accounts: const <BankAccount>[salary],
        categories: categories,
        currency: 'INR',
        paymentMethods: const <PaymentMethod>[],
      );
      engine.session = _session(<Map<String, Object?>>[
        for (final Map<String, Object?> op in operations) <String, Object?>{'id': op['itemId'], 'selected': true},
      ]);
      await provider.changeDirection(operations.first['itemId']! as String, 'debit', const <String, Object?>{});
      engine.operations = operations;
      expect(await provider.runImport(), isTrue);
    }

    test('a bill paid from the bank but saved as an expense becomes the payment', () async {
      await run(<Map<String, Object?>>[
        <String, Object?>{'type': 'convertPayment', 'itemId': 'r1', 'cardId': 'c1', 'entryId': 'l9'},
      ]);
      expect(ledger.treatments, hasLength(1));
      expect(ledger.treatments.single.$1, 'l9');
      expect(ledger.treatments.single.$2, <String, Object?>{'type': 'card_payment', 'credit_card_id': 'c1'});
      expect(expenses.created, isEmpty, reason: 'never a new expense');
      expect(provider.result?.importedIds, <String>['r1']);
    });

    test('a purchase already on the card is marked as the one the plan converted', () async {
      await run(<Map<String, Object?>>[
        <String, Object?>{
          'type': 'markConversion',
          'itemId': 'r1',
          'cardId': 'c1',
          'expenseId': 'e0',
          'emi': <String, Object?>{
            'plan': <String, Object?>{'planId': 'p1'},
          },
        },
      ]);
      expect(expenses.conversions, <(String, String?)>[('e0', 'p1')]);
    });

    test('a linked bank debit goes through the ledger link; EMI charges are expenses with their part', () async {
      await run(<Map<String, Object?>>[
        <String, Object?>{'type': 'linkPayment', 'itemId': 'r1', 'cardId': 'c1', 'entryId': 'l1'},
        <String, Object?>{
          'type': 'expense',
          'itemId': 'r2',
          'cardId': 'c1',
          'amount': 450.0,
          'date': '2026-11-15',
          'categoryId': 'shop',
          'merchant': 'EMI interest',
          'notes': 'Imported from card statement',
          'statementDate': '2026-11-20',
          'emi': <String, Object?>{
            'plan': <String, Object?>{'planId': 'p1'},
            'component': 'interest',
          },
        },
      ]);
      expect(ledger.links, <(String, String?)>[('l1', 'c1')]);
      expect(expenses.created.single.emiComponent, 'interest');
      expect(expenses.created.single.emiPlanId, 'p1');
      expect(expenses.created.single.creditCardId, 'c1');
      expect(expenses.created.single.bankAccountId, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // Screens
  // -------------------------------------------------------------------------
  group('screens at 360 x 720', () {
    late PreferencesService preferences;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      preferences = await PreferencesService.create();
      SchemaCapabilities.debugReset();
      SchemaCapabilities.debugOverride(creditCards: true, bankAccounts: true, cardAccounting: true);
    });

    tearDown(SchemaCapabilities.debugReset);

    Future<_FixedCards> pump(WidgetTester tester, Widget child, List<CardEntry> entries,
        {double width = 360}) async {
      tester.view.physicalSize = Size(width * 2, 720 * 2);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final SupabaseClient client = _client();
      final _FixedCards cards = _FixedCards(client, entries);
      await tester.pumpWidget(MultiProvider(
        providers: <ChangeNotifierProvider<dynamic>>[
          ChangeNotifierProvider<SettingsProvider>(
            create: (_) => SettingsProvider(repository: ProfileRepository(client), preferences: preferences),
          ),
          ChangeNotifierProvider<CreditCardProvider>.value(value: cards),
          ChangeNotifierProvider<BankAccountProvider>(create: (_) => _FixedAccounts(client)),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: child)),
        ),
      ));
      await tester.pumpAndSettle();
      return cards;
    }

    testWidgets('bill payments are listed for the record, never as spending', (WidgetTester tester) async {
      await pump(
        tester,
        CardBillPaymentsSection(from: d(12, 1), to: d(12, 31)),
        <CardEntry>[
          spend(purchase('e1', 5000, d(11, 10))),
          bankPayment('l1', 2000, d(12, 1)),
          cardPayment('t1', 3000, d(12, 4)),
        ],
      );
      expect(find.text('Credit card bill payments'), findsOneWidget);
      expect(find.text('Salary •••• 6459 → Amazon Pay •••• 4821'), findsOneWidget);
      expect(find.text('Cash / not tracked → Amazon Pay •••• 4821'), findsOneWidget);
      expect(find.textContaining('Partially paid'), findsOneWidget);
      expect(find.textContaining('Paid in full'), findsOneWidget);
      expect(find.textContaining('Total paid to cards'), findsOneWidget);
      expect(find.textContaining('not counted as spending'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a payment stored twice is merged only on the user\'s say', (WidgetTester tester) async {
      final _FixedCards cards = await pump(
        tester,
        CardBillPaymentsSection(from: d(12, 1), to: d(12, 31)),
        <CardEntry>[bankPayment('l1', 5000, d(12, 5)), cardPayment('t1', 5000, d(12, 2))],
      );
      expect(find.text(possibleDuplicateLabel), findsNWidgets(2));
      await tester.tap(find.text('Merge').first);
      await tester.pumpAndSettle();
      expect(find.text('Merge duplicate payment?'), findsOneWidget);
      expect(cards.merged, isEmpty, reason: 'nothing until confirmed');
      await tester.tap(find.widgetWithText(TextButton, 'Merge').last);
      await tester.pumpAndSettle();
      expect(cards.merged, <(String, String)>[('l1', 't1')]);
    });

    testWidgets('Pay bill asks whether a payment already on the card is this one', (WidgetTester tester) async {
      final _FixedCards cards = await pump(
        tester,
        const SizedBox.shrink(),
        <CardEntry>[spend(purchase('e1', 5000, d(11, 10))), cardPayment('t1', 5000, d(12, 2))],
      );
      final BuildContext context = tester.element(find.byType(SizedBox).first);
      unawaited(showAppSheetForTest(
        context,
        CardPaymentSheet(
          overview: CardOverview(card: card, summary: summariseCard(card, cards.allEntries, d(12, 5))),
          initialAmount: 5000,
          initialAccountId: 'a1',
          initialDate: d(12, 5),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining('is already recorded on the card'), findsOneWidget);
      expect(find.text('Same payment — record it from Salary'), findsOneWidget);
      expect(find.text('Separate payment'), findsOneWidget);

      // Unanswered: nothing is written.
      await tester.tap(find.text('Record payment'));
      await tester.pumpAndSettle();
      expect(find.text('Say whether the payment already on the card is this one.'), findsOneWidget);
      expect(cards.paid, isEmpty);

      await tester.tap(find.text('Same payment — record it from Salary'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Record payment'));
      await tester.pumpAndSettle();
      expect(cards.paid, <(String?, String?)>[('a1', 't1')],
          reason: 'recorded from the account, in place of the card-only record');
    });

    testWidgets('typing a card bill into an expense says it is not one', (WidgetTester tester) async {
      final TextEditingController description = TextEditingController();
      bool recorded = false;
      await pump(
        tester,
        ExpenseFields(
          categories: categories,
          categoryId: 'food',
          onCategory: (_) {},
          description: description,
          onRecordBillPayment: () => recorded = true,
        ),
        const <CardEntry>[],
      );
      expect(find.textContaining("A bill payment isn't an expense"), findsNothing);
      await tester.enterText(find.byType(TextFormField).first, 'CRED credit card bill');
      await tester.pumpAndSettle();
      expect(find.textContaining("A bill payment isn't an expense"), findsOneWidget);
      await tester.tap(find.text('Record as bill payment'));
      expect(recorded, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a converted purchase is badged and not shown as spending', (WidgetTester tester) async {
      await pump(
        tester,
        ExpenseTile(
          expense: purchase('e0', 60000, d(10, 2), plan: 'p1', component: 'conversion'),
          currency: 'INR',
        ),
        const <CardEntry>[],
        // The test font's glyphs are far wider than a phone's; the badge is
        // what is checked here.
        width: 480,
      );
      expect(find.text('Converted to EMI'), findsOneWidget);
    });
  });
}

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

SupabaseClient _client() => SupabaseClient(
      'http://localhost:54321',
      'test-anon-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );

Map<String, Object?> _session(List<Map<String, Object?>> items) => <String, Object?>{
      'cardId': 'c1',
      'cycle': <String, Object?>{'start': '2026-10-21', 'end': '2026-11-20'},
      'items': items,
      'groups': <Object?>[],
    };

class _Engine implements StatementEngine {
  Map<String, Object?> session = _session(const <Map<String, Object?>>[]);
  List<Map<String, Object?>> operations = <Map<String, Object?>>[];

  @override
  Future<Object?> call(String name, Map<String, Object?> args) async => switch (name) {
        'cardCycles' => <Object?>[
            <String, Object?>{
              'cycle': <String, Object?>{'start': '2026-10-21', 'end': '2026-11-20'},
              'label': 'Nov 2026',
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

  @override
  Future<PickedStatementFile?> pickFile() async => null;

  @override
  Future<void> release(String token) async {}
}

class _Expenses extends ExpenseRepository {
  _Expenses(super.client);

  final List<Expense> created = <Expense>[];
  final List<(String, String?)> conversions = <(String, String?)>[];

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

  @override
  Future<void> setEmiConversion({
    required String userId,
    required String expenseId,
    required String? planId,
  }) async =>
      conversions.add((expenseId, planId));
}

class _Ledger extends LedgerRepository {
  _Ledger(super.client);

  final List<(String, Map<String, Object?>)> treatments = <(String, Map<String, Object?>)>[];
  final List<(String, String?)> links = <(String, String?)>[];

  @override
  Future<String> applyBankTreatment({
    required String entryId,
    required Map<String, Object?> treatment,
  }) async {
    treatments.add((entryId, treatment));
    return entryId;
  }

  @override
  Future<void> linkToCard({
    required String userId,
    required String entryId,
    required String? cardId,
    String? replaces,
  }) async =>
      links.add((entryId, cardId));
}

class _Cards extends CreditCardRepository {
  _Cards(super.client, {required super.expenses, required super.ledger});

  @override
  Future<List<CardEntry>> fetchEntries({required String userId, String? cardId}) async => <CardEntry>[];
}

/// The card provider with its entries fixed, and merges recorded.
class _FixedCards extends CreditCardProvider {
  _FixedCards(SupabaseClient client, this._fixed)
      : super(
          repository: CreditCardRepository(
            client,
            expenses: ExpenseRepository(client),
            ledger: LedgerRepository(client),
          ),
          ledger: LedgerRepository(client),
        );

  final List<CardEntry> _fixed;
  final List<(String, String)> merged = <(String, String)>[];
  final List<(String?, String?)> paid = <(String?, String?)>[];

  @override
  List<CardEntry> get allEntries => _fixed;

  @override
  List<CardEntry> recordedPayments({
    required String cardId,
    required double amount,
    required DateTime date,
  }) =>
      findRecordedPayments(_fixed, cardId: cardId, amount: amount, date: date);

  @override
  Future<List<LedgerEntry>?> nearbyDebits({required String accountId, required DateTime date}) async =>
      const <LedgerEntry>[];

  @override
  Future<bool> payBill({
    required CreditCard card,
    required BankAccount? account,
    required double? amount,
    required DateTime date,
    String? note,
    String currencyCode = 'INR',
    String? replaces,
  }) async {
    paid.add((account?.id, replaces));
    return true;
  }

  @override
  Future<void> load({required String userId, bool force = false}) async {}

  @override
  bool get hasCards => true;

  @override
  List<CardBillPaymentRow> billPayments({
    required Iterable<BankAccount> accounts,
    DateTime? from,
    DateTime? to,
    String? accountId,
  }) =>
      cardBillPayments(
        entries: _fixed,
        cards: const <CreditCard>[card],
        accounts: accounts,
        from: from,
        to: to,
      );

  @override
  Future<bool> mergePayments({required String bankEntryId, required String cardTransactionId}) async {
    merged.add((bankEntryId, cardTransactionId));
    return true;
  }
}

class _FixedAccounts extends BankAccountProvider {
  _FixedAccounts(SupabaseClient client)
      : super(accounts: BankAccountRepository(client), ledger: LedgerRepository(client));

  @override
  List<BankAccount> get accounts => const <BankAccount>[salary];

  @override
  List<BankAccountBalance> get balances => const <BankAccountBalance>[
        BankAccountBalance(account: salary, totalCredits: 0, totalDebits: 0),
      ];
}

/// Opens a sheet the way the app does, for a test to drive.
Future<T?> showAppSheetForTest<T>(BuildContext context, Widget sheet) => showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      builder: (_) => sheet,
    );
