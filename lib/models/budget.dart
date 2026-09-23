import '../core/utils/date_utils.dart';
import 'expense_category.dart';

/// Row of `public.budgets`.
///
/// `month` is a Postgres `date`; the app always stores the first day of the
/// month so a budget is uniquely addressable by (user, category, month).
/// A null `category_id` means the overall budget for that month.
class Budget {
  const Budget({
    required this.id,
    required this.userId,
    required this.amount,
    required this.month,
    this.categoryId,
    this.createdAt,
    this.category,
  });

  final String id;
  final String userId;
  final double amount;
  final DateTime month;
  final String? categoryId;
  final DateTime? createdAt;
  final ExpenseCategory? category;

  bool get isOverall => categoryId == null;

  String get label => isOverall ? 'Overall budget' : (category?.name ?? 'Category');

  factory Budget.fromMap(Map<String, dynamic> map) {
    final Object? categoryJoin = map['categories'];
    return Budget(
      id: map['id'] as String,
      userId: map['user_id'] as String,
      amount: (map['amount'] as num?)?.toDouble() ?? 0,
      month: AppDateUtils.parseDate(map['month'] as String),
      categoryId: map['category_id'] as String?,
      createdAt: map['created_at'] == null
          ? null
          : DateTime.parse(map['created_at'] as String),
      category: categoryJoin is Map<String, dynamic>
          ? ExpenseCategory.fromMap(categoryJoin)
          : null,
    );
  }

  Map<String, dynamic> toInsertMap() => <String, dynamic>{
        'user_id': userId,
        'amount': amount,
        'month': AppDateUtils.toDateString(AppDateUtils.firstDayOf(month)),
        'category_id': categoryId,
      };

  Map<String, dynamic> toUpdateMap() => <String, dynamic>{
        'amount': amount,
      };
}

/// A budget paired with the spend actually recorded against it.
class BudgetProgress {
  const BudgetProgress({
    required this.budget,
    required this.spent,
  });

  final Budget budget;
  final double spent;

  double get limit => budget.amount;

  double get remaining => limit - spent;

  /// Unclamped so the UI can distinguish "at 100%" from "well over".
  double get ratio => limit <= 0 ? 0 : spent / limit;

  bool get isOver => spent > limit;

  /// Approaching is deliberately below 100% so the warning is actionable.
  bool get isApproaching => !isOver && ratio >= 0.8;
}
