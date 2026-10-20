// Card statements with a known statement date, and EMI plans: a row the bank
// billed on a later statement is filed under that statement, and one plan's
// components in one cycle are one instalment. Ported from the web app's
// cardStatement tests so both apps answer the same way. Nothing touches a
// database.

import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/models/card_statement.dart';
import 'package:expense_tracker/models/credit_card.dart';
import 'package:expense_tracker/models/emi_plan.dart';
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

CardEntry entry(
  String key,
  CardEntryKind kind,
  double amount,
  String date, {
  String? statementDate,
  String? planId,
  String? component,
}) =>
    CardEntry(
      key: key,
      source: kind == CardEntryKind.purchase
          ? CardEntrySource.expense
          : kind == CardEntryKind.payment
              ? CardEntrySource.account
              : CardEntrySource.card,
      id: key,
      cardId: 'c1',
      kind: kind,
      direction: kind == CardEntryKind.purchase ||
              kind == CardEntryKind.fee ||
              kind == CardEntryKind.interest
          ? LedgerDirection.debit
          : LedgerDirection.credit,
      amount: amount,
      date: d(date),
      description: key,
      statementDate: statementDate == null ? null : d(statementDate),
      emiPlanId: planId,
      emiComponent: component,
    );

void main() {
  group('billing cycles with a known statement date', () {
    final CardEntry augEmi = entry('aug-p', CardEntryKind.purchase, 1846, '2025-08-20', statementDate: '2025-09-20');
    final CardEntry augGst = entry('aug-t', CardEntryKind.fee, 24.93, '2025-08-20', statementDate: '2025-09-20');
    // No statement known: the card's rule files it under 20 Aug.
    final CardEntry julyBuy = entry('jul', CardEntryKind.purchase, 500, '2025-08-20');
    final CardEntry sepBuy = entry('sep', CardEntryKind.purchase, 11818, '2025-09-17');
    final BillingCycle sep = cardCycleContaining(card, d('2025-09-20'));

    test('files a row under the statement it was billed on, else under its date', () {
      expect(augEmi.billingDate, d('2025-09-20'));
      expect(cardCycleOf(card, augEmi).end, d('2025-09-20'));
      expect(cardCycleOf(card, julyBuy).end, d('2025-08-20'));
      expect(
        recentCycles(card, d('2025-10-05'), count: 2).map((BillingCycle c) => c.end).toList(),
        <DateTime>[d('2025-09-20'), d('2025-08-20')],
      );
    });

    test('shows the 20 Aug EMI on the September statement with the opening counting everything billed before', () {
      final List<CardEntry> entries = <CardEntry>[augEmi, augGst, julyBuy, sepBuy];
      final CardStatement statement = buildCardStatement(
        openingOutstanding: 0,
        entries: entries,
        from: sep.start,
        to: sep.end,
      );
      expect(statement.rows.map((CardStatementRow r) => r.entry.key).toList(), <String>['sep', 'aug-t', 'aug-p']);
      expect(statement.opening, 500);
      expect(statement.closing, closeTo(500 + 1846 + 24.93 + 11818, 0.001));
      final CardStatement aug = buildCardStatement(
        openingOutstanding: 0,
        entries: entries,
        from: d('2025-07-21'),
        to: d('2025-08-20'),
      );
      expect(aug.rows.map((CardStatementRow r) => r.entry.key).toList(), <String>['jul']);
      expect(aug.closing, 500);
      expect(buildCardStatement(openingOutstanding: 0, entries: entries).closing, statement.closing);
    });

    test('keeps unbilled and the bill in step with the statement date', () {
      final CardSummary summary = summariseCard(
        card,
        <CardEntry>[augEmi, sepBuy, entry('oct', CardEntryKind.purchase, 100, '2025-10-02')],
        d('2025-10-05'),
      );
      expect(summary.unbilled, 100);
      expect(summary.lastStatement.balance, 1846 + 11818);
    });
  });

  group('EMI plans', () {
    const EmiPlan plan = EmiPlan(
      id: 'p1',
      userId: 'u1',
      cardId: 'c1',
      title: 'Laptop',
      person: 'Arun',
      purchaseAmount: 44000,
      monthlyAmount: 2009,
      tenureMonths: 24,
      categoryId: 'shop',
    );
    final EmiPlan dated = EmiPlan(
      id: plan.id,
      userId: plan.userId,
      cardId: plan.cardId,
      title: plan.title,
      person: plan.person,
      purchaseAmount: plan.purchaseAmount,
      monthlyAmount: plan.monthlyAmount,
      tenureMonths: plan.tenureMonths,
      startDate: d('2025-08-20'),
      categoryId: plan.categoryId,
    );
    final List<CardEntry> components = <CardEntry>[
      entry('a-p', CardEntryKind.purchase, 1846, '2025-08-20', statementDate: '2025-09-20', planId: 'p1', component: 'principal'),
      entry('a-i', CardEntryKind.interest, 277, '2025-08-20', statementDate: '2025-09-20', planId: 'p1', component: 'interest'),
      entry('a-t1', CardEntryKind.fee, 24.93, '2025-08-20', statementDate: '2025-09-20', planId: 'p1', component: 'tax'),
      entry('a-t2', CardEntryKind.fee, 24.93, '2025-08-20', statementDate: '2025-09-20', planId: 'p1', component: 'tax'),
      entry('s-p', CardEntryKind.purchase, 1873, '2025-09-20', statementDate: '2025-10-20', planId: 'p1', component: 'principal'),
      entry('s-i', CardEntryKind.interest, 136, '2025-09-20', statementDate: '2025-10-20', planId: 'p1', component: 'interest'),
      entry('other', CardEntryKind.purchase, 885, '2025-09-09'),
    ];

    test('groups a plan’s components by the statement they were billed on', () {
      final List<EmiInstallment> installments = installmentsOf(dated, components, card);
      expect(installments.map((EmiInstallment i) => i.cycle.end).toList(), <DateTime>[d('2025-09-20'), d('2025-10-20')]);
      expect(installments.first.total, closeTo(2172.86, 0.001));
      expect(installments.first.principal, 1846);
      expect(installments.first.interest, 277);
      expect(installments.first.tax, closeTo(49.86, 0.001));
      expect(installments.last.total, 2009);
    });

    test('shows each month’s instalment as one statement line without counting any row twice', () {
      final CardStatement statement = buildCardStatement(openingOutstanding: 0, entries: components);
      final List<StatementLine> lines = statementLines(statement.rows, card);
      expect(
        lines.map((StatementLine l) => switch (l) {
          EntryLine(row: final CardStatementRow row) => row.entry.key,
          InstallmentLine(installment: final EmiInstallment i) => 'emi:${i.cycle.end.day}',
        }).toList(),
        <String>['emi:20', 'other', 'emi:20'],
      );
      final double total = lines.fold<double>(
        0,
        (double s, StatementLine l) => s + switch (l) {
          EntryLine(row: final CardStatementRow row) => row.entry.amount,
          InstallmentLine(installment: final EmiInstallment i) => i.total,
        },
      );
      expect(total, closeTo(statement.closing, 0.001));
      final InstallmentLine sep = lines.whereType<InstallmentLine>().last;
      expect(sep.outstandingAfter, closeTo(2172.86, 0.001));
    });

    test('summarises what someone else owes: everything billed so far, less what they paid back', () {
      const ClaimSummary claim = ClaimSummary(
        receivable: Receivable(id: 'r1', userId: 'u1', person: 'Arun', emiPlanId: 'p1'),
        source: null,
        principal: 4181.86,
        received: 2172.86,
        outstanding: 2009,
        status: ClaimStatus.partial,
        repayments: <ClaimRepayment>[],
        overdue: false,
      );
      final EmiPlanSummary summary = summariseEmiPlan(plan: dated, entries: components, card: card, claim: claim);
      expect(summary.billedMonths, 2);
      expect(summary.billedPrincipal, 3719);
      expect(summary.monthsLeft, 22);
      expect(summary.principalLeft, 44000 - 3719);
      expect(summary.endsOn, DateTime(2027, 7, 1));
      expect(summary.repayment!.expected, closeTo(4181.86, 0.001));
      expect(summary.repayment!.outstanding, closeTo(2009, 0.001));
      expect(summary.repayment!.status, ClaimStatus.partial);
      expect(emiClaimPrincipal(false, installmentsOf(dated, components, card)), 3719);
      expect(emiProgressText(summary), '2 of 24 months billed');
      expect(emiRepaymentText(summary, (double v) => v.toStringAsFixed(0)), 'Arun owes 2009');
    });
  });
}
