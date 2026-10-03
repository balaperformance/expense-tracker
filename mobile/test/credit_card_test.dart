// Credit cards: the maths that decides what is owed, when it is due and
// whether a bank debit was a bill payment.
//
// Ported from the web app's creditCards tests so both apps answer the same
// questions the same way. Every figure here is invented; nothing touches a
// database.

import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/models/bank_account.dart';
import 'package:expense_tracker/models/card_statement.dart';
import 'package:expense_tracker/models/credit_card.dart';
import 'package:expense_tracker/models/expense.dart';
import 'package:expense_tracker/models/ledger_entry.dart';
import 'package:expense_tracker/models/money_transfer.dart';
import 'package:expense_tracker/repositories/paging.dart';

DateTime d(String iso) => DateTime.parse(iso);

CreditCard card({
  double creditLimit = 100000,
  double openingOutstanding = 0,
  String? last4 = '4821',
  bool isActive = true,
}) =>
    CreditCard(
      id: 'c1',
      userId: 'u1',
      cardName: 'Regalia',
      issuer: 'Test Bank',
      network: CardNetwork.visa,
      last4: last4,
      creditLimit: creditLimit,
      openingOutstanding: openingOutstanding,
      statementDay: 15,
      paymentDueDay: 5,
      isActive: isActive,
    );

int _seq = 0;

CardEntry entry(
  CardEntryKind kind,
  double amount,
  String date, {
  String cardId = 'c1',
  String? key,
  DateTime? createdAt,
}) {
  _seq += 1;
  final bool debit = kind == CardEntryKind.purchase ||
      kind == CardEntryKind.fee ||
      kind == CardEntryKind.interest;
  return CardEntry(
    key: key ?? 't:${_seq.toString().padLeft(4, '0')}',
    source: kind == CardEntryKind.purchase
        ? CardEntrySource.expense
        : CardEntrySource.card,
    id: 'e$_seq',
    cardId: cardId,
    kind: kind,
    direction: debit ? LedgerDirection.debit : LedgerDirection.credit,
    amount: amount,
    date: d(date),
    createdAt: createdAt,
  );
}

CardEntry purchase(double amount, String date, {String cardId = 'c1'}) =>
    entry(CardEntryKind.purchase, amount, date, cardId: cardId);

CardEntry payment(double amount, String date) =>
    entry(CardEntryKind.payment, amount, date);

LedgerEntry ledger(
  String id, {
  LedgerDirection direction = LedgerDirection.debit,
  double amount = 5000,
  String date = '2026-10-03',
  String? expenseId,
  String? incomeId,
  String? transferGroupId,
  String? creditCardId,
  String? description = 'CC PAYMENT',
}) =>
    LedgerEntry(
      id: id,
      userId: 'u1',
      accountId: 'a1',
      direction: direction,
      amount: amount,
      txnDate: d(date),
      description: description,
      expenseId: expenseId,
      incomeId: incomeId,
      transferGroupId: transferGroupId,
      creditCardId: creditCardId,
    );

void main() {
  group('billing cycle dates', () {
    test('clamps a day to the month', () {
      expect(dayInMonth(d('2026-02-10'), 31), d('2026-02-28'));
      expect(dayInMonth(d('2028-02-10'), 30), d('2028-02-29'));
      expect(dayInMonth(d('2026-04-01'), 31), d('2026-04-30'));
      expect(dayInMonth(d('2026-09-01'), 15), d('2026-09-15'));
    });

    test('puts the due date on the first due day after the statement', () {
      expect(dueDateAfter(d('2026-09-15'), 5), d('2026-10-05'));
      expect(dueDateAfter(d('2026-09-01'), 20), d('2026-09-20'));
      // Due on the statement day itself means the following month.
      expect(dueDateAfter(d('2026-09-20'), 20), d('2026-10-20'));
      expect(dueDateAfter(d('2026-01-31'), 31), d('2026-02-28'));
    });

    void expectCycle(BillingCycle c, String start, String end, String due) {
      expect(c.start, d(start));
      expect(c.end, d(end));
      expect(c.dueDate, d(due));
    }

    test('finds the cycle a date falls in, statement day inclusive', () {
      expectCycle(cycleContaining(d('2026-10-02'), 15, 5), '2026-09-16',
          '2026-10-15', '2026-11-05');
      expectCycle(cycleContaining(d('2026-10-15'), 15, 5), '2026-09-16',
          '2026-10-15', '2026-11-05');
      expectCycle(cycleContaining(d('2026-10-16'), 15, 5), '2026-10-16',
          '2026-11-15', '2026-12-05');
    });

    test('handles month-end statement days without gaps or overlaps', () {
      expectCycle(cycleContaining(d('2026-02-10'), 31, 20), '2026-02-01',
          '2026-02-28', '2026-03-20');
      expectCycle(cycleContaining(d('2026-03-01'), 31, 20), '2026-03-01',
          '2026-03-31', '2026-04-20');
      expectCycle(cycleContaining(d('2026-03-31'), 30, 20), '2026-03-31',
          '2026-04-30', '2026-05-20');
      expectCycle(cycleContaining(d('2026-01-05'), 1, 20), '2026-01-02',
          '2026-02-01', '2026-02-20');
    });
  });

  group('card entries', () {
    test('maps a card purchase, and nothing for an expense not on a card', () {
      final CardEntry? mapped = CardEntry.fromExpense(Expense(
        id: 'x1',
        userId: 'u1',
        amount: 1200,
        expenseDate: d('2026-09-20'),
        creditCardId: 'c1',
        merchant: 'Amazon',
      ));
      expect(mapped, isNotNull);
      expect(mapped!.key, 'expense:x1');
      expect(mapped.kind, CardEntryKind.purchase);
      expect(mapped.direction, LedgerDirection.debit);
      expect(mapped.outstandingDelta, 1200);

      expect(
        CardEntry.fromExpense(Expense(
          id: 'x2',
          userId: 'u1',
          amount: 5,
          expenseDate: d('2026-09-20'),
          bankAccountId: 'a1',
        )),
        isNull,
      );
    });

    test('maps a bank debit that paid the card as a credit on the card', () {
      final CardEntry? mapped =
          CardEntry.fromPayment(ledger('l1', creditCardId: 'c1'));
      expect(mapped, isNotNull);
      expect(mapped!.key, 'account:l1');
      expect(mapped.source, CardEntrySource.account);
      expect(mapped.kind, CardEntryKind.payment);
      expect(mapped.direction, LedgerDirection.credit);
      expect(mapped.accountId, 'a1');
      expect(mapped.outstandingDelta, -5000);
      expect(CardEntry.fromPayment(ledger('l2')), isNull);
    });

    test('maps card-only transactions as stored', () {
      final CardTransaction fee = CardTransaction.fromMap(<String, dynamic>{
        'id': 't1',
        'user_id': 'u1',
        'card_id': 'c1',
        'kind': 'fee',
        'direction': 'debit',
        'amount': 590,
        'txn_date': '2026-09-16',
        'description': 'Annual fee',
        'reference': 'REF1',
      });
      final CardEntry mapped = CardEntry.fromCardTransaction(fee);
      expect(mapped.key, 'card:t1');
      expect(mapped.kind, CardEntryKind.fee);
      expect(mapped.direction, LedgerDirection.debit);
      expect(mapped.reference, 'REF1');
    });

    test('pairs each kind with the direction the database requires', () {
      expect(directionForKind(CardTransactionKind.refund),
          LedgerDirection.credit);
      expect(directionForKind(CardTransactionKind.cashback),
          LedgerDirection.credit);
      expect(directionForKind(CardTransactionKind.payment),
          LedgerDirection.credit);
      expect(
          directionForKind(CardTransactionKind.fee), LedgerDirection.debit);
      expect(directionForKind(CardTransactionKind.interest),
          LedgerDirection.debit);
      expect(
        directionForKind(CardTransactionKind.adjustment,
            adjustment: LedgerDirection.credit),
        LedgerDirection.credit,
      );
      expect(directionForKind(CardTransactionKind.adjustment),
          LedgerDirection.debit);
    });

    test('orders by date, then creation time, then key', () {
      final CardEntry a = entry(CardEntryKind.purchase, 1, '2026-09-20',
          key: 'b', createdAt: DateTime.utc(2026, 9, 20, 9));
      final CardEntry b = entry(CardEntryKind.payment, 1, '2026-09-20',
          key: 'a', createdAt: DateTime.utc(2026, 9, 20, 18));
      final CardEntry c =
          entry(CardEntryKind.purchase, 1, '2026-09-19', key: 'z');
      expect(orderEntries(<CardEntry>[b, a, c]).map((CardEntry e) => e.key),
          <String>['z', 'b', 'a']);
    });

    test('derives the outstanding in whole cents', () {
      expect(
        outstandingOf(0, <CardEntry>[
          purchase(0.1, '2026-09-01'),
          purchase(0.2, '2026-09-02'),
        ]),
        0.3,
      );
      expect(
        outstandingOf(1000, <CardEntry>[
          purchase(500, '2026-09-01'),
          payment(1200, '2026-09-02'),
        ]),
        300,
      );
    });

    test('sums thousands of decimal amounts without drifting', () {
      final List<CardEntry> many = <CardEntry>[
        for (int i = 0; i < 3000; i++) purchase(0.1, '2026-09-01'),
      ];
      expect(outstandingOf(0, many), 300);
      final List<CardEntry> settled = <CardEntry>[
        purchase(1000.03, '2026-09-01'),
        for (int i = 0; i < 100; i++) payment(10.0003, '2026-09-02'),
      ];
      // Each part rounds to whole cents before it is added.
      expect(outstandingOf(0, settled), 0.03);
    });
  });

  group('buildCardStatement', () {
    final List<CardEntry> history = <CardEntry>[
      purchase(2000, '2026-08-20'),
      purchase(1000, '2026-09-01'),
      payment(2000, '2026-09-05'),
      entry(CardEntryKind.fee, 500, '2026-09-10'),
      purchase(300, '2026-09-20'),
      entry(CardEntryKind.refund, 100, '2026-09-25'),
    ];

    test('walks the whole history from the opening outstanding', () {
      final CardStatement s =
          buildCardStatement(openingOutstanding: 500, entries: history);
      expect(s.opening, 500);
      expect(s.closing, 2200);
      expect(s.rows.map((CardStatementRow r) => r.outstandingAfter),
          <double>[2200, 2300, 2000, 1500, 3500, 2500],
          reason: 'newest first, as on the statement screen');
    });

    test('carries earlier history into a cycle and stops at its end', () {
      final CardStatement s = buildCardStatement(
        openingOutstanding: 500,
        entries: history,
        from: d('2026-08-16'),
        to: d('2026-09-15'),
      );
      expect(s.opening, 500);
      expect(s.rows, hasLength(4));
      expect(s.closing, 2000);
      expect(s.purchases, 3000);
      expect(s.payments, 2000);
      expect(s.charges, 500);
      expect(s.credits, 0);

      final CardStatement next = buildCardStatement(
        openingOutstanding: 500,
        entries: history,
        from: d('2026-09-16'),
        to: d('2026-10-15'),
      );
      expect(next.opening, 2000);
      expect(next.closing, 2200);
      expect(next.purchases, 300);
      expect(next.credits, 100);
      expect(next.payments, 0);
      expect(next.charges, 0);
    });

    test('filters after the walk, so running figures stay right', () {
      final CardStatement charges = buildCardStatement(
        openingOutstanding: 0,
        entries: history,
        filter: CardStatementFilter.charges,
      );
      expect(charges.rows.map((CardStatementRow r) => r.entry.kind),
          everyElement(anyOf(CardEntryKind.purchase, CardEntryKind.fee)));
      expect(charges.rows, hasLength(4));
      expect(charges.rows.first.outstandingAfter, 1800);
      expect(charges.payments, 0);
      // The running figure still includes the payment and refund it hides.
      expect(charges.closing, 1700);

      final CardStatement credits = buildCardStatement(
        openingOutstanding: 0,
        entries: history,
        filter: CardStatementFilter.credits,
      );
      expect(credits.rows.map((CardStatementRow r) => r.entry.kind).toSet(),
          <CardEntryKind>{CardEntryKind.refund, CardEntryKind.payment});
    });
  });

  group('summariseCard', () {
    final CreditCard c = card();

    test('reports the bill on the last statement and what is left to pay',
        () {
      final CardSummary s = summariseCard(
        c,
        <CardEntry>[
          purchase(4000, '2026-09-01'),
          purchase(1000, '2026-09-20'),
          payment(1500, '2026-09-25'),
        ],
        d('2026-10-02'),
      );
      expect(s.outstanding, 3500);
      expect(s.available, 96500);
      expect(s.utilisation, closeTo(0.035, 1e-9));
      expect(s.currentCycle.start, d('2026-09-16'));
      expect(s.currentCycle.end, d('2026-10-15'));
      expect(s.currentCycle.dueDate, d('2026-11-05'));
      expect(s.unbilled, 1000);
      expect(s.lastStatement.balance, 4000);
      expect(s.lastStatement.credited, 1500);
      expect(s.lastStatement.remaining, 2500);
      expect(s.lastStatement.status, DueStatus.due);
      expect(s.lastStatement.daysToDue, 3);
      expect(s.lastStatement.cycle.dueDate, d('2026-10-05'));
      expect(s.lastStatement.statusText, 'Due in 3 days');
    });

    test('paid once credits cover it, overdue after the due date otherwise',
        () {
      final List<CardEntry> bill = <CardEntry>[purchase(4000, '2026-09-01')];
      expect(
        summariseCard(c, <CardEntry>[...bill, payment(4000, '2026-10-01')],
                d('2026-10-02'))
            .lastStatement
            .status,
        DueStatus.paid,
      );
      final StatementDue late = summariseCard(
        c,
        <CardEntry>[...bill, payment(1000, '2026-10-01')],
        d('2026-10-07'),
      ).lastStatement;
      expect(late.remaining, 3000);
      expect(late.status, DueStatus.overdue);
      expect(late.daysToDue, -2);
      expect(late.statusText, 'Overdue by 2 days');
      expect(summariseCard(c, bill, d('2026-10-05')).lastStatement.statusText,
          'Due today');
    });

    test('counts the opening outstanding as already billed', () {
      final CardSummary s = summariseCard(
          card(openingOutstanding: 12000), const <CardEntry>[], d('2026-10-02'));
      expect(s.lastStatement.balance, 12000);
      expect(s.lastStatement.remaining, 12000);
      expect(s.lastStatement.status, DueStatus.due);
      expect(s.outstanding, 12000);
    });

    test('nothing due without a billed balance, including a credit balance',
        () {
      expect(
        summariseCard(c, <CardEntry>[purchase(900, '2026-09-20')],
                d('2026-10-02'))
            .lastStatement
            .status,
        DueStatus.nothingDue,
      );
      final CardSummary credit = summariseCard(
        c,
        <CardEntry>[purchase(100, '2026-09-01'), payment(300, '2026-09-02')],
        d('2026-10-02'),
      );
      expect(credit.outstanding, -200);
      expect(credit.lastStatement.status, DueStatus.nothingDue);
      expect(credit.utilisation, 0);
      expect(credit.available, 100200);
    });

    test('reports how far a card is over its limit', () {
      final CardSummary s = summariseCard(card(creditLimit: 1000),
          <CardEntry>[purchase(1250, '2026-09-20')], d('2026-10-02'));
      expect(s.available, 0);
      expect(s.overLimit, 250);
      expect(s.utilisation, 1.25);
    });

    test("ignores other cards' entries", () {
      final CardSummary s = summariseCard(
        c,
        <CardEntry>[purchase(500, '2026-09-20', cardId: 'other')],
        d('2026-10-02'),
      );
      expect(s.outstanding, 0);
    });

    test('a fee and interest raise the outstanding; a refund lowers it', () {
      final CardSummary s = summariseCard(
        c,
        <CardEntry>[
          purchase(1000, '2026-09-20'),
          entry(CardEntryKind.fee, 590, '2026-09-21'),
          entry(CardEntryKind.interest, 45.5, '2026-09-22'),
          entry(CardEntryKind.refund, 300, '2026-09-23'),
          entry(CardEntryKind.cashback, 10.25, '2026-09-24'),
        ],
        d('2026-10-02'),
      );
      expect(s.outstanding, 1325.25);
    });
  });

  group('bill payment', () {
    CardPaymentDraft draft({
      String? cardId = 'c1',
      bool hasSource = true,
      String? accountId = 'a1',
      double? amount = 5000,
    }) =>
        CardPaymentDraft(
          cardId: cardId,
          hasSource: hasSource,
          accountId: accountId,
          amount: amount,
          date: d('2026-10-03'),
        );

    test('checks shape first, then funds in whole cents', () {
      expect(checkCardPayment(draft(cardId: null), null),
          CardPaymentProblem.noCard);
      expect(checkCardPayment(draft(hasSource: false), null),
          CardPaymentProblem.noSource);
      expect(checkCardPayment(draft(amount: 0), null),
          CardPaymentProblem.invalidAmount);
      expect(checkCardPayment(draft(amount: double.nan), null),
          CardPaymentProblem.invalidAmount);
      expect(checkCardPayment(draft(amount: null), null),
          CardPaymentProblem.invalidAmount);
      expect(
        checkCardPayment(
            draft(amount: TransferValidation.maxAmount + 1), null),
        CardPaymentProblem.amountTooLarge,
      );
      expect(checkCardPayment(draft(), 4999.99),
          CardPaymentProblem.insufficientFunds);
      expect(checkCardPayment(draft(amount: 0.3), 0.1 + 0.2), isNull);
      expect(checkCardPayment(draft(), null), isNull);
    });

    test('never checks a balance for cash', () {
      expect(checkCardPayment(draft(accountId: null), 0), isNull);
    });

    test('describes the payment by the note, else by the card', () {
      expect(cardPaymentDescription(card(), '  October bill '), 'October bill');
      expect(cardPaymentDescription(card(), null),
          'Regalia •••• 4821 bill payment');
    });
  });

  group('reconciliation with the bank ledger', () {
    test('only plain, unlinked debits can become a payment', () {
      expect(isLinkableDebit(ledger('a')), isTrue);
      expect(
          isLinkableDebit(ledger('b', direction: LedgerDirection.credit)),
          isFalse);
      expect(isLinkableDebit(ledger('c', expenseId: 'x')), isFalse);
      expect(isLinkableDebit(ledger('d', incomeId: 'i')), isFalse);
      expect(isLinkableDebit(ledger('e', transferGroupId: 'g')), isFalse);
      expect(isLinkableDebit(ledger('f', creditCardId: 'c1')), isFalse,
          reason: 'an already-linked debit can never pay a second card');
    });

    test('finds same-amount debits nearby, closest first', () {
      final List<LedgerEntry> entries = <LedgerEntry>[
        ledger('far', date: '2026-10-08'),
        ledger('two', date: '2026-10-05'),
        ledger('same'),
        ledger('other', amount: 5000.01),
        ledger('linked', creditCardId: 'c2'),
      ];
      expect(
        findLinkableDebits(entries, 5000, d('2026-10-03'))
            .map((LedgerEntry e) => e.id),
        <String>['same', 'two'],
      );
    });

    test('warns of a same-amount expense near the date', () {
      final List<LedgerEntry> entries = <LedgerEntry>[
        ledger('spent', expenseId: 'x1', date: '2026-10-04'),
        ledger('plain'),
      ];
      expect(
        findExpenseDebits(entries, 5000, d('2026-10-03'))
            .map((LedgerEntry e) => e.id),
        <String>['spent'],
      );
    });

    test('labels a card payment on the bank statement', () {
      final LedgerEntry paid =
          ledger('p', creditCardId: 'c1', description: null);
      expect(paid.isCardPayment, isTrue);
      expect(paid.categoryLabel, cardPaymentLabel);
      expect(paid.title, cardPaymentLabel);
    });
  });

  group('matching a bank SMS to a card', () {
    const BankAccount savings = BankAccount(
      id: 'a1',
      userId: 'u1',
      bankName: 'Test Bank',
      nickname: 'Savings',
      last4: '4821',
    );

    test('matches the one active card ending in the digits', () {
      expect(
        matchSmsCard(
          text: 'Rs 10 spent on card ending 4821',
          last4: '4821',
          cards: <CreditCard>[card()],
          accounts: const <BankAccount>[],
        )?.id,
        'c1',
      );
    });

    test('defers to a bank account with the same digits unless it says credit '
        'card', () {
      expect(
        matchSmsCard(
          text: 'Rs 10 spent on card ending 4821',
          last4: '4821',
          cards: <CreditCard>[card()],
          accounts: const <BankAccount>[savings],
        ),
        isNull,
      );
      expect(
        matchSmsCard(
          text: 'Rs 10 spent on your Credit Card ending 4821',
          last4: '4821',
          cards: <CreditCard>[card()],
          accounts: const <BankAccount>[savings],
        )?.id,
        'c1',
      );
    });

    test('never guesses', () {
      expect(
        matchSmsCard(
          text: 'credit card',
          last4: null,
          cards: <CreditCard>[card()],
          accounts: const <BankAccount>[],
        ),
        isNull,
      );
      expect(
        matchSmsCard(
          text: 'credit card',
          last4: '4821',
          cards: <CreditCard>[card(isActive: false)],
          accounts: const <BankAccount>[],
        ),
        isNull,
        reason: 'an inactive card is not offered',
      );
    });

    test('spots bill-payment wording, but not ordinary card spending', () {
      expect(looksLikeCardBillPayment('Credit card payment of Rs 5000 received'),
          isTrue);
      expect(looksLikeCardBillPayment('Rs 5000 debited towards your CC'),
          isTrue);
      expect(looksLikeCardBillPayment('Card bill paid'), isTrue);
      expect(
          looksLikeCardBillPayment(
              'Rs 120 spent on your Credit Card ending 4821 at CAFE'),
          isFalse);
    });
  });

  group('expense funding', () {
    Expense purchaseOn({String? creditCardId, String? bankAccountId}) =>
        Expense(
          id: '',
          userId: 'u1',
          amount: 100,
          expenseDate: d('2026-10-01'),
          bankAccountId: bankAccountId,
          creditCardId: creditCardId,
        );

    test('a card purchase never also debits a bank account', () {
      final Map<String, dynamic> map =
          purchaseOn(creditCardId: 'c1', bankAccountId: 'a1').toInsertMap(
        includeMerchant: true,
        includeBankLink: true,
        includeCardLink: true,
      );
      expect(map['credit_card_id'], 'c1');
      expect(map['bank_account_id'], isNull);
    });

    test('an account purchase clears any card', () {
      final Map<String, dynamic> map =
          purchaseOn(bankAccountId: 'a1').toUpdateMap(
        includeMerchant: true,
        includeBankLink: true,
        includeCardLink: true,
      );
      expect(map['bank_account_id'], 'a1');
      expect(map.containsKey('credit_card_id'), isTrue);
      expect(map['credit_card_id'], isNull);
    });

    test('without migration 004 the card column is never written', () {
      final Map<String, dynamic> map = purchaseOn(creditCardId: 'c1')
          .toInsertMap(includeMerchant: true, includeBankLink: true);
      expect(map.containsKey('credit_card_id'), isFalse);
    });

    test('reads the card from a row', () {
      final Expense e = Expense.fromMap(<String, dynamic>{
        'id': 'x1',
        'user_id': 'u1',
        'amount': 10,
        'expense_date': '2026-10-01',
        'credit_card_id': 'c1',
      });
      expect(e.creditCardId, 'c1');
      expect(e.copyWith(amount: 20).creditCardId, 'c1');
    });
  });

  group('reading every row past the server page cap', () {
    PageFetch server(int total, {int cap = 1000, bool count = true}) {
      final List<Map<String, dynamic>> all = <Map<String, dynamic>>[
        for (int i = 0; i < total; i++) <String, dynamic>{'i': i},
      ];
      return (int from, int to, bool withCount) async {
        final int end = (to + 1).clamp(0, total);
        final int limited = (from + cap).clamp(0, end);
        final List<Map<String, dynamic>> rows =
            from >= total ? <Map<String, dynamic>>[] : all.sublist(from, limited);
        return (rows, withCount && count ? total : null);
      };
    }

    test('keeps reading past a 1000-row cap', () async {
      expect(await fetchAllPages(server(2500)), hasLength(2500));
    });

    test('keeps reading past a smaller cap than it asked for', () async {
      final List<Map<String, dynamic>> rows =
          await fetchAllPages(server(2500, cap: 300));
      expect(rows, hasLength(2500));
      expect(rows.last['i'], 2499);
    });

    test('reads to the end without a count, and stops at a maximum',
        () async {
      expect(await fetchAllPages(server(1700, count: false)), hasLength(1700));
      expect(await fetchAllPages(server(5000), max: 1200), hasLength(1200));
    });

    test('surfaces an error instead of a short total', () async {
      Future<(List<Map<String, dynamic>>, int?)> failing(
              int from, int to, bool withCount) async =>
          from == 0
              ? (<Map<String, dynamic>>[<String, dynamic>{}], 3000)
              : throw StateError('network');
      await expectLater(fetchAllPages(failing), throwsStateError);
    });

    test('nets a ledger and totals months in whole cents', () {
      expect(
        netOfRows(<Map<String, dynamic>>[
          for (int i = 0; i < 1000; i++)
            <String, dynamic>{'amount': 0.1, 'direction': 'credit'},
          <String, dynamic>{'amount': 0.3, 'direction': 'debit'},
        ]),
        99.7,
      );
      expect(
        monthlyTotals(<Map<String, dynamic>>[
          <String, dynamic>{'amount': 0.1, 'expense_date': '2026-09-01'},
          <String, dynamic>{'amount': 0.2, 'expense_date': '2026-09-30'},
          <String, dynamic>{'amount': 5, 'expense_date': '2026-10-01'},
        ], 'expense_date'),
        <String, double>{'2026-09': 0.3, '2026-10': 5},
      );
    });
  });
}
