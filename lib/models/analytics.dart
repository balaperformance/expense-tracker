import 'expense.dart';
import 'expense_category.dart';

/// Aggregates computed from raw rows. These are plain value types with no
/// Supabase dependency, so a future AI service can consume them directly.

class CategorySpend {
  const CategorySpend({
    required this.categoryId,
    required this.name,
    required this.color,
    required this.icon,
    required this.total,
    required this.transactionCount,
  });

  final String? categoryId;
  final String name;
  final String color;
  final String icon;
  final double total;
  final int transactionCount;

  /// Share of the period total, assigned by the caller that knows the total.
  double shareOf(double periodTotal) =>
      periodTotal <= 0 ? 0 : total / periodTotal;
}

class MonthlyPoint {
  const MonthlyPoint({
    required this.month,
    required this.expense,
    required this.income,
  });

  final DateTime month;
  final double expense;
  final double income;
}

/// Everything the dashboard renders, resolved in a single provider pass.
class DashboardData {
  const DashboardData({
    required this.month,
    required this.totalExpense,
    required this.totalIncome,
    required this.recentExpenses,
    required this.categoryBreakdown,
    required this.trend,
    required this.overallBudget,
    required this.overallSpent,
  });

  final DateTime month;
  final double totalExpense;
  final double totalIncome;
  final List<Expense> recentExpenses;
  final List<CategorySpend> categoryBreakdown;
  final List<MonthlyPoint> trend;

  /// Null when no overall budget is set for the month.
  final double? overallBudget;
  final double overallSpent;

  double get balance => totalIncome - totalExpense;

  bool get hasAnyData =>
      totalExpense > 0 || totalIncome > 0 || recentExpenses.isNotEmpty;

  double? get budgetRatio {
    final double? limit = overallBudget;
    if (limit == null || limit <= 0) return null;
    return overallSpent / limit;
  }

  double? get budgetRemaining {
    final double? limit = overallBudget;
    return limit == null ? null : limit - overallSpent;
  }

  static DashboardData emptyFor(DateTime month) => DashboardData(
        month: month,
        totalExpense: 0,
        totalIncome: 0,
        recentExpenses: const <Expense>[],
        categoryBreakdown: const <CategorySpend>[],
        trend: const <MonthlyPoint>[],
        overallBudget: null,
        overallSpent: 0,
      );
}

/// Report figures for an arbitrary month.
class ReportData {
  const ReportData({
    required this.month,
    required this.totalExpense,
    required this.totalIncome,
    required this.categoryBreakdown,
    required this.trend,
    required this.transactionCount,
    required this.topCategory,
  });

  final DateTime month;
  final double totalExpense;
  final double totalIncome;
  final List<CategorySpend> categoryBreakdown;
  final List<MonthlyPoint> trend;
  final int transactionCount;
  final CategorySpend? topCategory;

  double get net => totalIncome - totalExpense;

  double get savingsRate =>
      totalIncome <= 0 ? 0 : (totalIncome - totalExpense) / totalIncome;

  bool get isEmpty => totalExpense == 0 && totalIncome == 0;

  double get averagePerTransaction =>
      transactionCount == 0 ? 0 : totalExpense / transactionCount;
}

/// Groups expenses by category. Shared by the dashboard and reports so the
/// two can never disagree.
List<CategorySpend> buildCategoryBreakdown(
  List<Expense> expenses,
  List<ExpenseCategory> categories,
) {
  final Map<String, ExpenseCategory> byId = <String, ExpenseCategory>{
    for (final ExpenseCategory c in categories) c.id: c,
  };

  final Map<String?, double> totals = <String?, double>{};
  final Map<String?, int> counts = <String?, int>{};

  for (final Expense e in expenses) {
    totals[e.categoryId] = (totals[e.categoryId] ?? 0) + e.amount;
    counts[e.categoryId] = (counts[e.categoryId] ?? 0) + 1;
  }

  final List<CategorySpend> result = totals.entries.map((
    MapEntry<String?, double> entry,
  ) {
    final ExpenseCategory? category =
        entry.key == null ? null : byId[entry.key];
    return CategorySpend(
      categoryId: entry.key,
      name: category?.name ?? 'Uncategorised',
      color: category?.color ?? '#78909C',
      icon: category?.icon ?? 'category',
      total: entry.value,
      transactionCount: counts[entry.key] ?? 0,
    );
  }).toList();

  result.sort((CategorySpend a, CategorySpend b) => b.total.compareTo(a.total));
  return result;
}
