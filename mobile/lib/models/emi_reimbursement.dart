/// "Credit card EMI reimbursement (paid by someone else)" — money in that
/// pays back an EMI someone else owes on the user's card (migration 016).
///
/// It is never income. It is stored as a repayment: one ledger credit on the
/// account it arrived in, naming the EMI's claim (`receivables` kind 'emi'),
/// saved with `record_bank_movement` — or, for something already recorded as
/// income, turned into one with `apply_bank_treatment`. The bank balance
/// moves as it always did; the card's outstanding is untouched; what the
/// person owes goes down. A port of the web app's `domain/emiReimbursement.ts`,
/// with the same rules and the same wording.
library;

import '../core/utils/formatters.dart';
import 'card_statement.dart';
import 'credit_card.dart';
import 'emi_plan.dart';
import 'receivable.dart';
import '../core/utils/money.dart';

double _fromCents(int cents) => cents / 100;

/// One EMI a reimbursement can be recorded against.
class EmiReimbursementOption {
  const EmiReimbursementOption({
    required this.plan,
    required this.card,
    required this.claim,
    required this.expected,
    required this.received,
    required this.left,
    required this.status,
    required this.allowance,
    required this.lastInstallment,
  });

  final EmiPlan plan;
  final CreditCard? card;

  /// The claim, once the plan names who pays it back. Null for the user's
  /// own EMI (not shared yet).
  final ClaimSummary? claim;

  /// Billed so far and owed back — by the plan's rule.
  final double expected;
  final double received;

  /// Below zero when more came back than was billed.
  final double left;
  final ClaimStatus status;

  /// ₹1 per instalment billed: how far past [left] a reimbursement may go
  /// and still settle the EMI — rounding, as when ₹9,907.34 is paid back as
  /// ₹9,908.
  final double allowance;

  /// The latest instalment as owed back: what a monthly reimbursement usually is.
  final EmiClaimInstallment? lastInstallment;
}

/// Every EMI a reimbursement can be recorded against: open plans, those
/// someone else pays first (most still owed first), then the user's own
/// EMIs, which can be marked as someone else's from the same form.
/// [entries]: the card entries the figures are read from; null falls back to
/// the claims.
List<EmiReimbursementOption> emiReimbursementOptions({
  required List<EmiPlan> plans,
  required List<ClaimSummary> claims,
  required List<CreditCard> cards,
  required List<CardEntry>? entries,
  String? keepPlanId,
}) {
  final List<EmiReimbursementOption> out = <EmiReimbursementOption>[];
  for (final EmiPlan plan in plans) {
    if (plan.isClosed && plan.id != keepPlanId) continue;
    // The first match, as the web's `find` takes it.
    CreditCard? card;
    for (final CreditCard c in cards) {
      if (c.id == plan.cardId) {
        card = c;
        break;
      }
    }
    ClaimSummary? claim;
    for (final ClaimSummary c in claims) {
      if (c.source?.emiPlanId == plan.id) {
        claim = c;
        break;
      }
    }
    final List<EmiInstallment>? installments =
        card != null && entries != null ? installmentsOf(plan, entries, card) : null;
    // The card's own rows when they were read; else what the claim says.
    final double expected = installments != null
        ? emiClaimPrincipal(plan.includeCharges, installments)
        : (claim?.principal ?? 0);
    final double received = claim?.received ?? 0;
    final EmiInstallment? last =
        installments != null && installments.isNotEmpty ? installments.last : null;
    final List<EmiClaimInstallment> fromClaim =
        claim?.source?.installments ?? const <EmiClaimInstallment>[];
    final double allowance = installments != null
        ? emiRoundingPerInstallment * installments.length
        : (claim?.allowance ?? emiRoundingPerInstallment * fromClaim.length);
    out.add(EmiReimbursementOption(
      plan: plan,
      card: card,
      claim: claim,
      expected: expected,
      received: received,
      left: _fromCents(toCents(expected) - toCents(received)),
      status: claimStatus(expected, received, allowance),
      allowance: allowance,
      lastInstallment: last != null
          ? EmiClaimInstallment(
              date: last.date,
              amount: plan.includeCharges ? last.total : last.principal,
            )
          : (fromClaim.isEmpty ? null : fromClaim.last),
    ));
  }
  out.sort((EmiReimbursementOption a, EmiReimbursementOption b) {
    final int shared =
        (b.plan.person != null ? 1 : 0) - (a.plan.person != null ? 1 : 0);
    if (shared != 0) return shared;
    final int left = b.left.compareTo(a.left);
    if (left != 0) return left;
    return a.plan.title.compareTo(b.plan.title);
  });
  return out;
}

/// "Laptop · Arun · ₹2,009 left", "Phone · your own EMI".
String emiOptionLabel(EmiReimbursementOption option, String Function(double) format) {
  final String who = option.plan.person ?? 'your own EMI';
  final String? owed = option.plan.person == null
      ? null
      : option.status.isOpen
          ? '${format(option.left)} left'
          : option.status == ClaimStatus.overpaid
              ? 'paid ahead'
              : 'settled';
  return <String>[option.plan.title, who, if (owed != null) owed].join(' · ');
}

enum EmiReimbursementProblem { plan, person, account, amount, nothingBilled, tooMuch }

/// The first thing stopping the reimbursement from being saved, or null.
/// The database refuses the same over-repayment, so two devices cannot both
/// record it.
EmiReimbursementProblem? emiReimbursementProblem({
  required EmiReimbursementOption? option,
  required String person,
  required String? accountId,
  required double? amount,
}) {
  if (option == null) return EmiReimbursementProblem.plan;
  if ((option.plan.person ?? person).trim().isEmpty) {
    return EmiReimbursementProblem.person;
  }
  if (accountId == null) return EmiReimbursementProblem.account;
  if (amount == null || !amount.isFinite || toCents(amount) <= 0) {
    return EmiReimbursementProblem.amount;
  }
  if (toCents(option.expected) <= 0) return EmiReimbursementProblem.nothingBilled;
  // Rounding up to whole rupees is fine: up to the allowance past what is left.
  if (toCents(amount) > toCents(option.left) + toCents(option.allowance)) {
    return EmiReimbursementProblem.tooMuch;
  }
  return null;
}

String emiReimbursementProblemMessage(
  EmiReimbursementProblem problem,
  EmiReimbursementOption? option,
  String Function(double) format,
) =>
    switch (problem) {
      EmiReimbursementProblem.plan => 'Choose the EMI this pays back.',
      EmiReimbursementProblem.person => 'Add who pays this EMI back.',
      EmiReimbursementProblem.account =>
        'Choose the account the money arrived in. A reimbursement always '
            'lands in an account (or your cash).',
      EmiReimbursementProblem.amount => 'Enter an amount greater than 0.',
      EmiReimbursementProblem.nothingBilled =>
        'No instalment of this EMI has been billed yet. Import the card '
            'statement first, then record the reimbursement.',
      EmiReimbursementProblem.tooMuch => option != null && toCents(option.left) > 0
          ? 'Only ${format(option.left)} is still owed on this EMI '
              '(instalments billed so far; up to '
              '${format(option.left + option.allowance)} is accepted for '
              'rounding). The reimbursement may already be recorded.'
          : 'Everything billed on this EMI is already paid back. The '
              'reimbursement may already be recorded.',
    };

/// What the reimbursement's ledger row is called: "EMI repayment from Arun · Laptop".
String emiRepaymentDescription(EmiPlan plan, String person, [String? note]) {
  final String base = 'EMI repayment from ${person.trim()} · ${plan.title}';
  final String? extra = note?.trim();
  return extra == null || extra.isEmpty ? base : '$base · $extra';
}

/// The figures after this reimbursement, for the form's summary line.
/// [rounding]: settled with a little extra — the rounding, not money owed
/// back to them.
({double received, double left, ClaimStatus status, double rounding}) afterReimbursement(
  EmiReimbursementOption option,
  double? amount,
) {
  final double received = _fromCents(toCents(option.received) + toCents(amount ?? 0));
  final double left = _fromCents(toCents(option.expected) - toCents(received));
  final ClaimStatus status = claimStatus(option.expected, received, option.allowance);
  return (
    received: received,
    left: left,
    status: status,
    rounding: status == ClaimStatus.settled && left < 0 ? -left : 0,
  );
}

/// EMI reimbursements received — every repayment on an EMI claim — for the
/// income screen's separate line. Never part of the income figures.
/// [toExclusive] bounds the range by date.
({double received, int count, double owed, int people}) emiReimbursementTotals(
  List<ClaimSummary> claims,
  DateTime from,
  DateTime toExclusive,
) {
  final List<ClaimSummary> emi =
      claims.where((ClaimSummary c) => c.source?.emiPlanId != null).toList();
  final List<ClaimRepayment> inRange = <ClaimRepayment>[
    for (final ClaimSummary c in emi)
      for (final ClaimRepayment r in c.repayments)
        if (!r.date.isBefore(from) && r.date.isBefore(toExclusive)) r,
  ];
  final List<ClaimSummary> open =
      emi.where((ClaimSummary c) => c.status.isOpen).toList();
  return (
    received: _fromCents(
        inRange.fold<int>(0, (int s, ClaimRepayment r) => s + toCents(r.amount))),
    count: inRange.length,
    owed: _fromCents(open.fold<int>(
        0,
        (int s, ClaimSummary c) =>
            s + toCents(c.outstanding < 0 ? 0 : c.outstanding))),
    people: open.map((ClaimSummary c) => c.receivable.person.trim().toLowerCase()).toSet().length,
  );
}

/// "₹2,009" with the user's currency — the form's default formatter.
String Function(double) emiMoney(String currency) =>
    (double amount) => Formatters.currency(amount, currencyCode: currency);
