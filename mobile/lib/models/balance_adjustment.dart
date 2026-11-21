import '../core/utils/date_utils.dart';
import '../core/utils/money.dart';

/// Row of `public.balance_adjustments` (migration 021, shared with the web
/// app): on [adjustedOn] the account's real balance was [targetBalance].
///
/// From that point on it is the account's reference balance. The database
/// backs it with one ledger row for the difference and keeps that row right
/// when earlier movements change, so every balance in the app — computed as
/// opening balance plus the ledger — follows without any special case.
class BalanceAdjustment {
  const BalanceAdjustment({
    required this.id,
    required this.accountId,
    required this.adjustedOn,
    required this.targetBalance,
    required this.previousBalance,
    this.adjustedAt,
    this.remarks,
  });

  final String id;
  final String accountId;

  /// The day the bank showed [targetBalance].
  final DateTime adjustedOn;

  /// When the adjustment was made: same-day movements recorded after it count
  /// from the new balance.
  final DateTime? adjustedAt;

  /// The balance the user set.
  final double targetBalance;

  /// The app's balance just before the adjustment, as it was when it was made.
  final double previousBalance;

  final String? remarks;

  /// What the adjustment changed the balance by when it was made.
  double get difference => (toCents(targetBalance) - toCents(previousBalance)) / 100;

  factory BalanceAdjustment.fromMap(Map<String, dynamic> map) {
    final String remarks = ((map['remarks'] as String?) ?? '').trim();
    final String? at = map['adjusted_at'] as String?;
    return BalanceAdjustment(
      id: map['id'] as String,
      accountId: map['account_id'] as String,
      adjustedOn: AppDateUtils.parseDate(map['adjusted_on'] as String),
      adjustedAt: at == null ? null : DateTime.parse(at),
      targetBalance: _num(map['target_balance']),
      previousBalance: _num(map['previous_balance']),
      remarks: remarks.isEmpty ? null : remarks,
    );
  }
}

double _num(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
}

/// The most remarks an adjustment keeps (the database's limit).
const int balanceAdjustmentRemarksMax = 200;

/// Newest first: by date, then by when it was made.
List<BalanceAdjustment> newestFirst(Iterable<BalanceAdjustment> adjustments) =>
    List<BalanceAdjustment>.of(adjustments)
      ..sort((BalanceAdjustment a, BalanceAdjustment b) {
        final int byDay = b.adjustedOn.compareTo(a.adjustedOn);
        if (byDay != 0) return byDay;
        final DateTime aAt = a.adjustedAt ?? DateTime(1970);
        final DateTime bAt = b.adjustedAt ?? DateTime(1970);
        return bAt.compareTo(aAt);
      });

/// The live line under the amount on the Adjust balance sheet:
/// "Adds ₹500 as a balance adjustment", "Removes ₹120 as a balance
/// adjustment", "Already matches — recorded with no change".
String adjustmentEffectText(double difference, String Function(double) format) {
  final int cents = toCents(difference);
  if (cents == 0) return 'Already matches — recorded with no change';
  final String amount = format(cents.abs() / 100);
  return cents > 0
      ? 'Adds $amount as a balance adjustment'
      : 'Removes $amount as a balance adjustment';
}

/// "+₹500", "−₹120", "₹0" — a difference with its sign.
String signedDifference(double difference, String Function(double) format) {
  final int cents = toCents(difference);
  if (cents == 0) return format(0);
  return '${cents > 0 ? '+' : '−'}${format(cents.abs() / 100)}';
}

/// A history row's subtitle: "21 Nov 2026 · was ₹7,320.67 · −₹5,320.67 ·
/// Matched with the bank app".
String adjustmentHistorySubtitle(
  BalanceAdjustment adjustment, {
  required String Function(double) format,
  required String Function(DateTime) date,
}) =>
    <String>[
      date(adjustment.adjustedOn),
      'was ${format(adjustment.previousBalance)}',
      signedDifference(adjustment.difference, format),
      if (adjustment.remarks != null) adjustment.remarks!,
    ].join(' · ');
