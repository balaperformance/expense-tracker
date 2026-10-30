import '../core/utils/date_utils.dart';
import '../core/utils/text.dart';

/// Row of `public.income`.
///
/// The table has no `notes` or `updated_at` column, so the income form
/// deliberately exposes fewer fields than the expense form.
class Income {
  const Income({
    required this.id,
    required this.userId,
    required this.amount,
    required this.incomeDate,
    this.source,
    this.description,
    this.bankAccountId,
    this.isPersonal = true,
    this.createdAt,
  });

  final String id;
  final String userId;
  final double amount;
  final DateTime incomeDate;
  final String? source;
  final String? description;

  /// Account this income was paid into. Null means it is recorded as income
  /// but not tracked against any bank account, so no ledger credit is made.
  final String? bankAccountId;

  /// False: received for someone else (migration 019). Listed, but never
  /// counted as income. True before 019.
  final bool isPersonal;

  final DateTime? createdAt;

  String get title {
    final String? s = source?.trim();
    if (s != null && s.isNotEmpty) return s;
    final String? d = description?.trim();
    if (d != null && d.isNotEmpty) return d;
    return 'Income';
  }

  String? get subtitle {
    final String? d = description?.trim();
    if (d != null && d.isNotEmpty && d != title) return d;
    return null;
  }

  factory Income.fromMap(Map<String, dynamic> map) {
    return Income(
      id: map['id'] as String,
      userId: map['user_id'] as String,
      amount: (map['amount'] as num?)?.toDouble() ?? 0,
      incomeDate: AppDateUtils.parseDate(map['income_date'] as String),
      source: map['source'] as String?,
      description: map['description'] as String?,
      bankAccountId: map['bank_account_id'] as String?,
      // Only an explicit false is non-personal (see Expense.fromMap).
      isPersonal: map['is_personal'] != false,
      createdAt: map['created_at'] == null
          ? null
          : DateTime.parse(map['created_at'] as String),
    );
  }

  /// [includePersonal]: migration 019 is in place, so [isPersonal] is written.
  Map<String, dynamic> toInsertMap({
    required bool includeBankLink,
    bool includePersonal = false,
  }) {
    final Map<String, dynamic> map = <String, dynamic>{
      'user_id': userId,
      'amount': amount,
      'income_date': AppDateUtils.toDateString(incomeDate),
      'source': blankToNull(source),
      'description': blankToNull(description),
    };
    if (includeBankLink) map['bank_account_id'] = bankAccountId;
    if (includePersonal) map['is_personal'] = isPersonal;
    return map;
  }

  Map<String, dynamic> toUpdateMap({
    required bool includeBankLink,
    bool includePersonal = false,
  }) {
    final Map<String, dynamic> map = <String, dynamic>{
      'amount': amount,
      'income_date': AppDateUtils.toDateString(incomeDate),
      'source': blankToNull(source),
      'description': blankToNull(description),
    };
    if (includeBankLink) map['bank_account_id'] = bankAccountId;
    if (includePersonal) map['is_personal'] = isPersonal;
    return map;
  }

  Income copyWith({
    double? amount,
    DateTime? incomeDate,
    String? source,
    String? description,
    String? bankAccountId,
    bool? isPersonal,
  }) {
    return Income(
      id: id,
      userId: userId,
      amount: amount ?? this.amount,
      incomeDate: incomeDate ?? this.incomeDate,
      source: source ?? this.source,
      description: description ?? this.description,
      bankAccountId: bankAccountId ?? this.bankAccountId,
      isPersonal: isPersonal ?? this.isPersonal,
      createdAt: createdAt,
    );
  }
}
