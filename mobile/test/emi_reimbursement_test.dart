// "Credit card EMI reimbursement (paid by someone else)": what can be paid
// back and how much, what stops a save, and the income screen's separate
// line. Ported from the web app's emiReimbursement tests so both apps answer
// the same way. Nothing touches a database.

import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/models/card_statement.dart';
import 'package:expense_tracker/models/credit_card.dart';
import 'package:expense_tracker/models/emi_plan.dart';
import 'package:expense_tracker/models/emi_reimbursement.dart';
import 'package:expense_tracker/models/ledger_entry.dart';
import 'package:expense_tracker/models/receivable.dart';

DateTime d(String iso) => DateTime.parse(iso);

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

EmiPlan plan({
  String id = 'p1',
  String title = 'Laptop',
  String? person = 'Arun',
  bool includeCharges = true,
  bool isClosed = false,
}) =>
    EmiPlan(
      id: id,
      userId: 'u1',
      cardId: 'c1',
      title: title,
      person: person,
      includeCharges: includeCharges,
      purchaseAmount: 44000,
      monthlyAmount: 2009,
      tenureMonths: 24,
      startDate: d('2026-08-20'),
      isClosed: isClosed,
    );

CardEntry entry(String key, CardEntryKind kind, double amount, String date,
        String statementDate, String component, [String planId = 'p1']) =>
    CardEntry(
      key: key,
      source: kind == CardEntryKind.purchase ? CardEntrySource.expense : CardEntrySource.card,
      id: key,
      cardId: 'c1',
      kind: kind,
      direction: LedgerDirection.debit,
      amount: amount,
      date: d(date),
      description: key,
      statementDate: d(statementDate),
      emiPlanId: planId,
      emiComponent: component,
    );

/// August and September instalments of the laptop EMI.
final List<CardEntry> entries = <CardEntry>[
  entry('a-p', CardEntryKind.purchase, 1846, '2026-08-20', '2026-09-20', 'principal'),
  entry('a-i', CardEntryKind.interest, 277, '2026-08-20', '2026-09-20', 'interest'),
  entry('a-t', CardEntryKind.fee, 49.86, '2026-08-20', '2026-09-20', 'tax'),
  entry('s-p', CardEntryKind.purchase, 1873, '2026-09-20', '2026-10-20', 'principal'),
  entry('s-i', CardEntryKind.interest, 136, '2026-09-20', '2026-10-20', 'interest'),
];

List<ClaimSummary> claimsWith(List<double> received) => summariseClaims(
      receivables: <Receivable>[
        const Receivable(id: 'r1', userId: 'u1', person: 'Arun', emiPlanId: 'p1'),
      ],
      sources: <String, ClaimSource>{
        'r1': ClaimSource(
          date: d('2026-08-20'),
          amount: 4181.86,
          title: 'EMI · Laptop',
          cardId: 'c1',
          emiPlanId: 'p1',
          installments: <EmiClaimInstallment>[
            EmiClaimInstallment(date: d('2026-08-20'), amount: 2172.86),
            EmiClaimInstallment(date: d('2026-09-20'), amount: 2009),
          ],
        ),
      },
      repayments: <ClaimRepayment>[
        for (int i = 0; i < received.length; i++)
          ClaimRepayment(
            entryId: 'l$i',
            receivableId: 'r1',
            accountId: 'a1',
            amount: received[i],
            date: d('2026-09-05'),
          ),
      ],
      today: d('2026-10-20'),
    );

String format(double n) => '₹${n == n.roundToDouble() ? n.toInt() : n}';

void main() {
  group('EMIs a reimbursement can pay back', () {
    test('reads what is owed from the card’s own rows, by the plan’s rule, less what came back', () {
      final EmiReimbursementOption option = emiReimbursementOptions(
        plans: <EmiPlan>[plan()],
        claims: claimsWith(<double>[2172.86]),
        cards: <CreditCard>[card],
        entries: entries,
      ).single;
      expect(option.expected, 4181.86);
      expect(option.received, 2172.86);
      expect(option.left, 2009);
      expect(option.status, ClaimStatus.partial);
      expect(option.lastInstallment?.date, d('2026-09-20'));
      expect(option.lastInstallment?.amount, 2009);

      final EmiReimbursementOption principalOnly = emiReimbursementOptions(
        plans: <EmiPlan>[plan(includeCharges: false)],
        claims: const <ClaimSummary>[],
        cards: <CreditCard>[card],
        entries: entries,
      ).single;
      expect(principalOnly.expected, 3719);
      expect(principalOnly.left, 3719);
      expect(principalOnly.lastInstallment?.amount, 1873);
    });

    test('falls back to the claim when the card’s rows are not loaded, and lists someone else’s EMIs first', () {
      final List<EmiReimbursementOption> options = emiReimbursementOptions(
        plans: <EmiPlan>[
          plan(id: 'own', title: 'Phone', person: null),
          plan(),
          plan(id: 'old', isClosed: true),
        ],
        claims: claimsWith(const <double>[]),
        cards: <CreditCard>[card],
        entries: null,
      );
      expect(options.map((EmiReimbursementOption o) => o.plan.id).toList(), <String>['p1', 'own']);
      expect(options.first.expected, 4181.86);
      expect(options.first.lastInstallment?.amount, 2009);
      expect(
        options.map((EmiReimbursementOption o) => emiOptionLabel(o, format)).toList(),
        <String>['Laptop · Arun · ₹4181.86 left', 'Phone · your own EMI'],
      );
    });

    test('refuses a save without an EMI, a payer, an account, an amount, a billed instalment — or for more than is owed', () {
      final EmiReimbursementOption option = emiReimbursementOptions(
        plans: <EmiPlan>[plan()],
        claims: claimsWith(<double>[2172.86]),
        cards: <CreditCard>[card],
        entries: entries,
      ).single;
      EmiReimbursementProblem? problem({
        EmiReimbursementOption? o,
        bool noOption = false,
        String person = '',
        String? account = 'a1',
        double? amount = 2009,
      }) =>
          emiReimbursementProblem(
            option: noOption ? null : (o ?? option),
            person: person,
            accountId: account,
            amount: amount,
          );
      expect(problem(), isNull);
      expect(problem(noOption: true), EmiReimbursementProblem.plan);
      expect(problem(account: null), EmiReimbursementProblem.account);
      expect(problem(amount: 0), EmiReimbursementProblem.amount);
      // Two instalments billed: up to ₹2 past what is left is rounding; beyond that it is refused.
      expect(problem(amount: 2011), isNull);
      expect(problem(amount: 2011.01), EmiReimbursementProblem.tooMuch);

      final EmiReimbursementOption own = emiReimbursementOptions(
        plans: <EmiPlan>[plan(person: null)],
        claims: const <ClaimSummary>[],
        cards: <CreditCard>[card],
        entries: entries,
      ).single;
      expect(problem(o: own), EmiReimbursementProblem.person);
      expect(problem(o: own, person: 'Meena'), isNull);

      final EmiReimbursementOption unbilled = emiReimbursementOptions(
        plans: <EmiPlan>[plan(id: 'new')],
        claims: const <ClaimSummary>[],
        cards: <CreditCard>[card],
        entries: entries,
      ).single;
      expect(problem(o: unbilled), EmiReimbursementProblem.nothingBilled);
      expect(
        emiReimbursementProblemMessage(EmiReimbursementProblem.tooMuch, option, format),
        contains('Only ₹2009 is still owed'),
      );
      expect(
        emiReimbursementProblemMessage(EmiReimbursementProblem.tooMuch, option, format),
        contains('up to ₹2011 is accepted for rounding'),
      );
    });

    test('names the repayment after the person and the EMI, and shows what is left after it', () {
      expect(
        emiRepaymentDescription(plan(), ' Arun ', 'Sep instalment'),
        'EMI repayment from Arun · Laptop · Sep instalment',
      );
      final EmiReimbursementOption option = emiReimbursementOptions(
        plans: <EmiPlan>[plan()],
        claims: claimsWith(<double>[2172.86]),
        cards: <CreditCard>[card],
        entries: entries,
      ).single;
      final ({double received, double left, ClaimStatus status, double rounding}) after =
          afterReimbursement(option, 2009);
      expect(after.received, 4181.86);
      expect(after.left, 0);
      expect(after.status, ClaimStatus.settled);
      expect(after.rounding, 0);
    });

    test('totals the month’s reimbursements apart from income', () {
      final ({double received, int count, double owed, int people}) sep =
          emiReimbursementTotals(claimsWith(<double>[2172.86, 500]), d('2026-09-01'), d('2026-10-01'));
      expect(sep.received, 2672.86);
      expect(sep.count, 2);
      expect(sep.owed, 1509);
      expect(sep.people, 1);
      final ({double received, int count, double owed, int people}) oct =
          emiReimbursementTotals(claimsWith(<double>[2172.86]), d('2026-10-01'), d('2026-11-01'));
      expect(oct.received, 0);
      expect(oct.count, 0);
    });
  });

  group('round-rupee reimbursements of a paisa-billed EMI', () {
    // The iPhone EMI on the ICICI card: one instalment of ₹9,907.34 billed, nothing received yet.
    final EmiPlan iphone = plan(id: 'p2', title: 'Iphone17', person: 'Princy');
    final List<CardEntry> billed = <CardEntry>[
      entry('i-p', CardEntryKind.purchase, 9309.99, '2026-08-01', '2026-08-01', 'principal', 'p2'),
      entry('i-i', CardEntryKind.interest, 506.23, '2026-08-01', '2026-08-01', 'interest', 'p2'),
      entry('i-t', CardEntryKind.fee, 91.12, '2026-08-01', '2026-08-01', 'tax', 'p2'),
    ];
    List<ClaimSummary> claimOf(List<double> received, {int months = 1}) => summariseClaims(
          receivables: <Receivable>[
            const Receivable(id: 'r2', userId: 'u1', person: 'Princy', emiPlanId: 'p2'),
          ],
          sources: <String, ClaimSource>{
            'r2': ClaimSource(
              date: d('2026-08-01'),
              amount: (990734 * months) / 100,
              title: 'EMI · Iphone17',
              cardId: 'c1',
              emiPlanId: 'p2',
              installments: <EmiClaimInstallment>[
                for (int m = 0; m < months; m++)
                  EmiClaimInstallment(date: DateTime(2026, 8 + m, 1), amount: 9907.34),
              ],
            ),
          },
          repayments: <ClaimRepayment>[
            for (int i = 0; i < received.length; i++)
              ClaimRepayment(
                entryId: 'x$i',
                receivableId: 'r2',
                accountId: 'a1',
                amount: received[i],
                date: d('2026-10-20'),
              ),
          ],
          today: d('2026-10-20'),
        );

    test('accepts ₹9,908 for ₹9,907.34 and marks the EMI fully reimbursed, nothing left owed', () {
      final EmiReimbursementOption option = emiReimbursementOptions(
        plans: <EmiPlan>[iphone],
        claims: claimOf(const <double>[]),
        cards: <CreditCard>[card],
        entries: billed,
      ).single;
      expect(option.expected, 9907.34);
      expect(option.left, 9907.34);
      expect(option.allowance, 1);
      EmiReimbursementProblem? problem(double amount) => emiReimbursementProblem(
            option: option,
            person: '',
            accountId: 'a1',
            amount: amount,
          );
      expect(problem(9908), isNull);
      final ({double received, double left, ClaimStatus status, double rounding}) after =
          afterReimbursement(option, 9908);
      expect(after.status, ClaimStatus.settled);
      expect(after.left, -0.66);
      expect(after.rounding, 0.66);
      // More than rounding is still refused: it may be the same reimbursement twice.
      expect(problem(9908.35), EmiReimbursementProblem.tooMuch);
      expect(problem(19815), EmiReimbursementProblem.tooMuch);
    });

    test('reads as settled once saved, with no amount still owed and no overpayment', () {
      final ClaimSummary claim = claimOf(<double>[9908]).single;
      expect(claim.status, ClaimStatus.settled);
      expect(claim.allowance, 1);
      expect(amountLeft(claim), 0);
      expect(claim.outstanding, closeTo(-0.66, 0.001));
      expect(repaymentProblem(claim, 1), RepaymentProblem.settled);
      final ({double received, int count, double owed, int people}) totals =
          emiReimbursementTotals(claimOf(<double>[9908]), d('2026-10-01'), d('2026-11-01'));
      expect(totals.received, 9908);
      expect(totals.owed, 0);
      expect(claimOf(<double>[9908.35]).single.status, ClaimStatus.overpaid);
    });

    test('keeps the rounding from adding up: each new instalment brings its own rupee', () {
      final ClaimSummary twoMonths = claimOf(<double>[9908, 9908], months: 2).single;
      expect(twoMonths.principal, 19814.68);
      expect(twoMonths.received, 19816);
      expect(twoMonths.allowance, 2);
      expect(twoMonths.status, ClaimStatus.settled);
    });

    test('a repayment of an open EMI claim may round up, other claims stay exact', () {
      final ClaimSummary open = claimOf(const <double>[]).single;
      expect(repaymentProblem(open, 9908), isNull);
      expect(repaymentProblem(open, 9908.35), RepaymentProblem.tooMuch);
      final ClaimSummary purchase = summariseClaims(
        receivables: <Receivable>[
          const Receivable(id: 'r3', userId: 'u1', person: 'Ravi', expenseId: 'e3'),
        ],
        sources: <String, ClaimSource>{
          'r3': ClaimSource(date: d('2026-08-01'), amount: 9907.34, title: 'Purchase'),
        },
        repayments: const <ClaimRepayment>[],
        today: d('2026-10-20'),
      ).single;
      expect(purchase.allowance, 0);
      expect(repaymentProblem(purchase, 9908), RepaymentProblem.tooMuch);
    });
  });
}
