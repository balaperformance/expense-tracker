import '../core/utils/date_utils.dart';
import 'card_statement.dart';
import 'credit_card.dart';
import 'receivable.dart';
import '../core/utils/money.dart';

/// A purchase converted to EMI on a card (migration 016, shared with the web
/// app). Its monthly instalments are ordinary rows — the principal an
/// expense on the card, the interest and GST card transactions — that name
/// the plan. [person] set means someone else pays the EMI back every month:
/// the plan is then a claim (a receivable of kind 'emi') and its principal
/// never counts as spending. A port of the web app's `domain/emi.ts`.
class EmiPlan {
  const EmiPlan({
    required this.id,
    required this.userId,
    required this.cardId,
    required this.title,
    this.reference,
    this.person,
    this.includeCharges = true,
    this.purchaseAmount,
    this.monthlyAmount,
    this.tenureMonths,
    this.startDate,
    this.categoryId,
    this.notes,
    this.isClosed = false,
    this.createdAt,
  });

  final String id;
  final String userId;
  final String cardId;
  final String title;

  /// The issuer's EMI / loan reference, when known.
  final String? reference;
  final String? person;

  /// For someone else's EMI: whether the interest and GST are owed back too.
  final bool includeCharges;
  final double? purchaseAmount;
  final double? monthlyAmount;
  final int? tenureMonths;
  final DateTime? startDate;

  /// The category the principal instalments are filed under.
  final String? categoryId;
  final String? notes;
  final bool isClosed;
  final String? createdAt;

  /// "Laptop · Arun" for someone else's plan, else the title.
  String get label => person == null ? title : '$title · $person';

  factory EmiPlan.fromMap(Map<String, dynamic> map) {
    final String title = ((map['title'] as String?) ?? '').trim();
    final String person = ((map['person'] as String?) ?? '').trim();
    final String? start = map['start_date'] as String?;
    return EmiPlan(
      id: map['id'] as String,
      userId: (map['user_id'] as String?) ?? '',
      cardId: map['card_id'] as String,
      title: title.isEmpty ? 'EMI' : title,
      reference: map['reference'] as String?,
      person: person.isEmpty ? null : person,
      includeCharges: (map['include_charges'] as bool?) ?? true,
      purchaseAmount: _optNum(map['purchase_amount']),
      monthlyAmount: _optNum(map['monthly_amount']),
      tenureMonths: _optNum(map['tenure_months'])?.toInt(),
      startDate: start == null || start.isEmpty ? null : AppDateUtils.parseDate(start),
      categoryId: map['category_id'] as String?,
      notes: map['notes'] as String?,
      isClosed: (map['is_closed'] as bool?) ?? false,
      createdAt: map['created_at'] as String?,
    );
  }

  /// The columns a save writes — what the web app writes, so both apps read
  /// the plan the same way.
  Map<String, dynamic> toWriteMap() {
    String? blank(String? value) {
      final String? trimmed = value?.trim();
      return trimmed == null || trimmed.isEmpty ? null : trimmed;
    }

    final String? ref = blank(reference);
    return <String, dynamic>{
      'card_id': cardId,
      'title': title.trim(),
      'reference': ref == null ? null : (ref.length > 64 ? ref.substring(0, 64) : ref),
      'person': blank(person),
      'include_charges': includeCharges,
      'purchase_amount': purchaseAmount != null && purchaseAmount! > 0 ? purchaseAmount : null,
      'monthly_amount': monthlyAmount != null && monthlyAmount! > 0 ? monthlyAmount : null,
      'tenure_months': tenureMonths != null && tenureMonths! > 0 ? tenureMonths : null,
      'start_date': startDate == null ? null : AppDateUtils.toDateString(startDate!),
      'category_id': categoryId,
      'notes': blank(notes),
      'is_closed': isClosed,
    };
  }

  /// The plan in the shape the engine (the web domain) expects.
  Map<String, Object?> toEngineMap() => <String, Object?>{
        'id': id,
        'userId': userId,
        'cardId': cardId,
        'title': title,
        'reference': reference,
        'person': person,
        'includeCharges': includeCharges,
        'purchaseAmount': purchaseAmount,
        'monthlyAmount': monthlyAmount,
        'tenureMonths': tenureMonths,
        'startDate': startDate == null ? null : AppDateUtils.toDateString(startDate!),
        'categoryId': categoryId,
        'notes': notes,
        'isClosed': isClosed,
        'createdAt': createdAt,
      };

  EmiPlan copyWith({String? id, String? userId, String? person}) => EmiPlan(
        id: id ?? this.id,
        userId: userId ?? this.userId,
        cardId: cardId,
        title: title,
        reference: reference,
        person: person ?? this.person,
        includeCharges: includeCharges,
        purchaseAmount: purchaseAmount,
        monthlyAmount: monthlyAmount,
        tenureMonths: tenureMonths,
        startDate: startDate,
        categoryId: categoryId,
        notes: notes,
        isClosed: isClosed,
        createdAt: createdAt,
      );
}

double? _optNum(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

/// One part of a monthly instalment.
const Map<String, String> emiComponentLabels = <String, String>{
  'principal': 'Principal',
  'interest': 'Interest',
  'tax': 'GST',
  'fee': 'Fee',
};

/// The component an entry is, for an entry that belongs to a plan.
String componentOf(CardEntry entry) =>
    entry.emiComponent ??
    switch (entry.kind) {
      CardEntryKind.purchase => 'principal',
      CardEntryKind.interest => 'interest',
      _ => 'fee',
    };

double _fromCents(int cents) => cents / 100;

/// What each component does to the figures: a credit of a charge reverses it.
int _signed(CardEntry e) => e.isCharge ? toCents(e.amount) : -toCents(e.amount);

/// One month's instalment: the plan's components billed in one cycle.
class EmiInstallment {
  const EmiInstallment({
    required this.planId,
    required this.cycle,
    required this.date,
    required this.entries,
    required this.principal,
    required this.interest,
    required this.tax,
    required this.fee,
    required this.total,
  });

  final String planId;

  /// The cycle the components were billed in.
  final BillingCycle cycle;

  /// The latest component's date: when the instalment was charged.
  final DateTime date;
  final List<CardEntry> entries;
  final double principal;
  final double interest;
  final double tax;
  final double fee;

  /// Everything billed for the month: what the card's bill includes for this EMI.
  final double total;
}

EmiInstallment _buildInstallment(
  String planId,
  BillingCycle cycle,
  List<CardEntry> entries,
) {
  double sum(String component) => _fromCents(entries
      .where((CardEntry e) => componentOf(e) == component)
      .fold<int>(0, (int s, CardEntry e) => s + _signed(e)));
  final double principal = sum('principal');
  final double interest = sum('interest');
  final double tax = sum('tax');
  final double fee = sum('fee');
  final List<CardEntry> ordered = List<CardEntry>.of(entries)
    ..sort((CardEntry a, CardEntry b) {
      final int byDate = a.date.compareTo(b.date);
      return byDate != 0 ? byDate : a.key.compareTo(b.key);
    });
  return EmiInstallment(
    planId: planId,
    cycle: cycle,
    date: ordered.isEmpty ? cycle.end : ordered.last.date,
    entries: ordered,
    principal: principal,
    interest: interest,
    tax: tax,
    fee: fee,
    total: _fromCents(toCents(principal) + toCents(interest) + toCents(tax) + toCents(fee)),
  );
}

/// The plan's instalments, oldest first: its components grouped by the
/// cycle they were billed in.
List<EmiInstallment> installmentsOf(
  EmiPlan plan,
  Iterable<CardEntry> entries,
  CreditCard card,
) {
  final Map<DateTime, (BillingCycle, List<CardEntry>)> byCycle =
      <DateTime, (BillingCycle, List<CardEntry>)>{};
  for (final CardEntry entry in entries) {
    if (entry.emiPlanId != plan.id) continue;
    final BillingCycle cycle = cardCycleOf(card, entry);
    final (BillingCycle, List<CardEntry>) group =
        byCycle[cycle.end] ??= (cycle, <CardEntry>[]);
    group.$2.add(entry);
  }
  final List<EmiInstallment> out = byCycle.values
      .map(((BillingCycle, List<CardEntry>) g) => _buildInstallment(plan.id, g.$1, g.$2))
      .toList()
    ..sort((EmiInstallment a, EmiInstallment b) => a.cycle.end.compareTo(b.cycle.end));
  return out;
}

/// A statement line: one entry, or one plan's components in one cycle as a
/// single instalment.
sealed class StatementLine {
  const StatementLine();
}

class EntryLine extends StatementLine {
  const EntryLine(this.row);

  final CardStatementRow row;
}

class InstallmentLine extends StatementLine {
  const InstallmentLine({
    required this.installment,
    required this.rows,
    required this.outstandingAfter,
  });

  final EmiInstallment installment;

  /// The components' own lines.
  final List<CardStatementRow> rows;
  final double outstandingAfter;
}

/// Folds the components of one plan billed in one cycle into a single line,
/// placed where the last component was. Everything else is a line of its own.
/// Rows are newest first, as [buildCardStatement] returns them.
List<StatementLine> statementLines(List<CardStatementRow> rows, CreditCard card) {
  String? keyOf(CardStatementRow row) => row.entry.emiPlanId == null
      ? null
      : '${row.entry.emiPlanId}#${AppDateUtils.toDateString(cardCycleOf(card, row.entry).end)}';
  final Map<String, List<CardStatementRow>> groups = <String, List<CardStatementRow>>{};
  for (final CardStatementRow row in rows) {
    final String? key = keyOf(row);
    if (key != null) (groups[key] ??= <CardStatementRow>[]).add(row);
  }
  final Set<String> placed = <String>{};
  final List<StatementLine> lines = <StatementLine>[];
  for (final CardStatementRow row in rows) {
    final String? key = keyOf(row);
    if (key == null) {
      lines.add(EntryLine(row));
      continue;
    }
    if (placed.contains(key)) continue;
    placed.add(key);
    final List<CardStatementRow> members = groups[key] ?? <CardStatementRow>[row];
    if (members.length == 1) {
      lines.add(EntryLine(row));
      continue;
    }
    lines.add(InstallmentLine(
      installment: _buildInstallment(
        row.entry.emiPlanId!,
        cardCycleOf(card, row.entry),
        members.map((CardStatementRow m) => m.entry).toList(),
      ),
      rows: members,
      // Newest first: the first member met is the latest, whose figure closes the instalment.
      outstandingAfter: members.first.outstandingAfter,
    ));
  }
  return lines;
}

/// "Principal ₹1,873 · Interest ₹136 · GST ₹24.93" — the parts that are not zero.
String installmentBreakdown(EmiInstallment i, String Function(double) format) {
  final List<(String, double)> parts = <(String, double)>[
    ('principal', i.principal),
    ('interest', i.interest),
    ('tax', i.tax),
    ('fee', i.fee),
  ];
  return parts
      .where(((String, double) p) => toCents(p.$2) != 0)
      .map(((String, double) p) => '${emiComponentLabels[p.$1]} ${format(p.$2)}')
      .join(' · ');
}

/// Someone else's EMI: what they owe.
class EmiRepayment {
  const EmiRepayment({
    required this.expected,
    required this.received,
    required this.outstanding,
    required this.status,
    required this.allowance,
  });

  /// Billed so far and owed back: the principal, plus the charges when the
  /// plan includes them.
  final double expected;
  final double received;
  final double outstanding;
  final ClaimStatus status;

  /// ₹1 per billed instalment: repaid that far past [expected] is rounding,
  /// and settles it.
  final double allowance;
}

class EmiPlanSummary {
  const EmiPlanSummary({
    required this.plan,
    required this.installments,
    required this.billedMonths,
    required this.billedPrincipal,
    required this.billedCharges,
    required this.billedTotal,
    required this.monthsLeft,
    required this.principalLeft,
    required this.endsOn,
    required this.repayment,
  });

  final EmiPlan plan;
  final List<EmiInstallment> installments;
  final int billedMonths;
  final double billedPrincipal;
  final double billedCharges;
  final double billedTotal;

  /// Tenure minus months billed, when the tenure is known.
  final int? monthsLeft;

  /// Principal still to be billed, when the purchase amount is known.
  final double? principalLeft;

  /// The month the last instalment is due, when the tenure and start are known.
  final DateTime? endsOn;

  /// Null for the user's own EMI.
  final EmiRepayment? repayment;
}

/// What a plan's claim is owed: its billed components, by the plan's rule.
double emiClaimPrincipal(bool includeCharges, List<EmiInstallment> installments) =>
    _fromCents(installments.fold<int>(
      0,
      (int s, EmiInstallment i) =>
          s +
          toCents(i.principal) +
          (includeCharges ? toCents(i.interest) + toCents(i.tax) + toCents(i.fee) : 0),
    ));

/// One plan's figures from its components on the card, and — for someone
/// else's EMI — its claim, read from the same repayments as any other claim.
EmiPlanSummary summariseEmiPlan({
  required EmiPlan plan,
  required Iterable<CardEntry> entries,
  required CreditCard card,
  ClaimSummary? claim,
}) {
  final List<EmiInstallment> installments = installmentsOf(plan, entries, card);
  final double billedPrincipal = _fromCents(
      installments.fold<int>(0, (int s, EmiInstallment i) => s + toCents(i.principal)));
  final double billedCharges = _fromCents(installments.fold<int>(
      0, (int s, EmiInstallment i) => s + toCents(i.interest) + toCents(i.tax) + toCents(i.fee)));
  final int months = installments.length;
  final int? tenure = plan.tenureMonths;
  final DateTime? start = plan.startDate;
  EmiRepayment? repayment;
  if (plan.person != null) {
    final double expected = emiClaimPrincipal(plan.includeCharges, installments);
    final double received = claim?.received ?? 0;
    final double allowance = emiRoundingPerInstallment * installments.length;
    repayment = EmiRepayment(
      expected: expected,
      received: received,
      outstanding: _fromCents(toCents(expected) - toCents(received)),
      status: claimStatus(expected, received, allowance),
      allowance: allowance,
    );
  }
  return EmiPlanSummary(
    plan: plan,
    installments: installments,
    billedMonths: months,
    billedPrincipal: billedPrincipal,
    billedCharges: billedCharges,
    billedTotal: _fromCents(toCents(billedPrincipal) + toCents(billedCharges)),
    monthsLeft: tenure == null ? null : (tenure - months).clamp(0, tenure),
    principalLeft: plan.purchaseAmount == null
        ? null
        : _fromCents((toCents(plan.purchaseAmount!) - toCents(billedPrincipal)).clamp(0, 1 << 62)),
    endsOn: start != null && tenure != null && tenure > 0
        ? DateTime(start.year, start.month + tenure - 1, 1)
        : null,
    repayment: repayment,
  );
}

/// "3 of 12 months billed", "5 months billed".
String emiProgressText(EmiPlanSummary summary) {
  final int months = summary.billedMonths;
  final int? tenure = summary.plan.tenureMonths;
  if (tenure != null && tenure > 0) return '$months of $tenure months billed';
  return '$months ${months == 1 ? 'month' : 'months'} billed';
}

/// "Arun owes ₹2,033", "Arun has paid everything back", "Nothing billed yet".
String? emiRepaymentText(EmiPlanSummary summary, String Function(double) format) {
  final EmiRepayment? r = summary.repayment;
  final String? person = summary.plan.person;
  if (r == null || person == null) return null;
  if (toCents(r.expected) == 0) return 'Nothing billed to $person yet';
  if (!r.status.isOpen) {
    return r.status == ClaimStatus.overpaid
        ? '$person has paid ${format(-r.outstanding)} too much'
        : '$person has paid everything back';
  }
  return '$person owes ${format(r.outstanding < 0 ? 0 : r.outstanding)}';
}
