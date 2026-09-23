import '../core/utils/date_utils.dart';
import 'expense_category.dart';
import 'payment_method.dart';

/// Row of `public.expenses`, optionally with its joined category and
/// payment method.
///
/// `merchant` requires the additive migration documented in the setup notes
/// (`alter table public.expenses add column if not exists merchant text`).
class Expense {
  const Expense({
    required this.id,
    required this.userId,
    required this.amount,
    required this.expenseDate,
    this.categoryId,
    this.paymentMethodId,
    this.bankAccountId,
    this.merchant,
    this.description,
    this.notes,
    this.createdAt,
    this.updatedAt,
    this.category,
    this.paymentMethod,
  });

  final String id;
  final String userId;
  final double amount;
  final DateTime expenseDate;
  final String? categoryId;
  final String? paymentMethodId;

  /// Bank account the money left. Null means Cash: no ledger movement is
  /// created, so cash spending can never change a bank balance.
  final String? bankAccountId;

  final String? merchant;
  final String? description;
  final String? notes;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// Populated when the query selects the embedded relations.
  final ExpenseCategory? category;
  final PaymentMethod? paymentMethod;

  String get categoryName => category?.name ?? 'Uncategorised';

  /// Primary line in a transaction row: merchant, else description,
  /// else category.
  String get title {
    final String? m = merchant?.trim();
    if (m != null && m.isNotEmpty) return m;
    final String? d = description?.trim();
    if (d != null && d.isNotEmpty) return d;
    return categoryName;
  }

  /// Secondary line, suppressed when it would repeat [title].
  String? get subtitle {
    final String? d = description?.trim();
    if (d != null && d.isNotEmpty && d != title) return d;
    return null;
  }

  factory Expense.fromMap(Map<String, dynamic> map) {
    final Object? categoryJoin = map['categories'];
    final Object? paymentJoin = map['payment_methods'];

    return Expense(
      id: map['id'] as String,
      userId: map['user_id'] as String,
      amount: (map['amount'] as num?)?.toDouble() ?? 0,
      expenseDate: AppDateUtils.parseDate(map['expense_date'] as String),
      categoryId: map['category_id'] as String?,
      paymentMethodId: map['payment_method_id'] as String?,
      bankAccountId: map['bank_account_id'] as String?,
      merchant: map['merchant'] as String?,
      description: map['description'] as String?,
      notes: map['notes'] as String?,
      createdAt: map['created_at'] == null
          ? null
          : DateTime.parse(map['created_at'] as String),
      updatedAt: map['updated_at'] == null
          ? null
          : DateTime.parse(map['updated_at'] as String),
      category: categoryJoin is Map<String, dynamic>
          ? ExpenseCategory.fromMap(categoryJoin)
          : null,
      paymentMethod: paymentJoin is Map<String, dynamic>
          ? PaymentMethod.fromMap(paymentJoin)
          : null,
    );
  }

  /// Optional columns are included only when the migration that adds them has
  /// been applied, so the same code works before and after.
  Map<String, dynamic> toInsertMap({
    required bool includeMerchant,
    required bool includeBankLink,
  }) {
    final Map<String, dynamic> map = <String, dynamic>{
      'user_id': userId,
      'amount': amount,
      'expense_date': AppDateUtils.toDateString(expenseDate),
      'category_id': categoryId,
      'payment_method_id': paymentMethodId,
      'description': _blankToNull(description),
      'notes': _blankToNull(notes),
    };
    if (includeMerchant) map['merchant'] = _blankToNull(merchant);
    if (includeBankLink) map['bank_account_id'] = bankAccountId;
    return map;
  }

  Map<String, dynamic> toUpdateMap({
    required bool includeMerchant,
    required bool includeBankLink,
  }) {
    final Map<String, dynamic> map = <String, dynamic>{
      'amount': amount,
      'expense_date': AppDateUtils.toDateString(expenseDate),
      'category_id': categoryId,
      'payment_method_id': paymentMethodId,
      'description': _blankToNull(description),
      'notes': _blankToNull(notes),
    };
    if (includeMerchant) map['merchant'] = _blankToNull(merchant);
    if (includeBankLink) map['bank_account_id'] = bankAccountId;
    return map;
  }

  static String? _blankToNull(String? value) {
    final String? trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  Expense copyWith({
    double? amount,
    DateTime? expenseDate,
    String? categoryId,
    String? paymentMethodId,
    String? bankAccountId,
    String? merchant,
    String? description,
    String? notes,
  }) {
    return Expense(
      id: id,
      userId: userId,
      amount: amount ?? this.amount,
      expenseDate: expenseDate ?? this.expenseDate,
      categoryId: categoryId ?? this.categoryId,
      paymentMethodId: paymentMethodId ?? this.paymentMethodId,
      bankAccountId: bankAccountId ?? this.bankAccountId,
      merchant: merchant ?? this.merchant,
      description: description ?? this.description,
      notes: notes ?? this.notes,
      createdAt: createdAt,
      updatedAt: updatedAt,
      category: category,
      paymentMethod: paymentMethod,
    );
  }
}
