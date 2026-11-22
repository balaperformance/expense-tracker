import 'expense.dart';
import 'expense_category.dart';
import 'income.dart';

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
    this.expenses = const <Expense>[],
  });

  final String? categoryId;
  final String name;
  final String color;
  final String icon;
  final double total;
  final int transactionCount;

  /// The expenses behind [total], newest first — what a tap on the category
  /// lists. Exactly the rows counted, so the list always adds up to [total].
  final List<Expense> expenses;

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
  });

  final DateTime month;
  final double totalExpense;
  final double totalIncome;
  final List<Expense> recentExpenses;
  final List<CategorySpend> categoryBreakdown;
  final List<MonthlyPoint> trend;

  double get balance => totalIncome - totalExpense;

  bool get hasAnyData =>
      totalExpense > 0 || totalIncome > 0 || recentExpenses.isNotEmpty;
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

  bool get isEmpty => totalExpense == 0 && totalIncome == 0;

  double get averagePerTransaction =>
      transactionCount == 0 ? 0 : totalExpense / transactionCount;
}

/// The user's own spending: every expense except purchases paid on someone
/// else's behalf ([paidForIds], migration 005), which are owed back, and
/// non-personal ones spent with someone else's money (migration 019). Every
/// spending figure — Home, budgets, reports, exports — counts this, exactly as
/// the web app does.
List<Expense> personalSpending(List<Expense> expenses, Set<String> paidForIds) =>
    expenses
        .where((Expense e) => e.isPersonal && !paidForIds.contains(e.id))
        .toList();

/// The user's own income: everything except money received for someone else
/// (migration 019). Every income figure counts this.
List<Income> personalIncome(List<Income> income) =>
    income.where((Income i) => i.isPersonal).toList();

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
  final Map<String?, List<Expense>> rows = <String?, List<Expense>>{};

  for (final Expense e in expenses) {
    totals[e.categoryId] = (totals[e.categoryId] ?? 0) + e.amount;
    (rows[e.categoryId] ??= <Expense>[]).add(e);
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
      transactionCount: rows[entry.key]?.length ?? 0,
      expenses: _newestFirst(rows[entry.key] ?? const <Expense>[]),
    );
  }).toList();

  result.sort((CategorySpend a, CategorySpend b) => b.total.compareTo(a.total));
  return result;
}

List<Expense> _newestFirst(List<Expense> expenses) => List<Expense>.of(expenses)
  ..sort((Expense a, Expense b) {
    final int byDate = b.expenseDate.compareTo(a.expenseDate);
    if (byDate != 0) return byDate;
    final DateTime? ac = a.createdAt;
    final DateTime? bc = b.createdAt;
    if (ac == null || bc == null) return 0;
    return bc.compareTo(ac);
  });

/// One month's spending by category: what the dashboard's "Where it went"
/// shows for that month, with every category and its expenses.
class CategoryMonthSpending {
  const CategoryMonthSpending({
    required this.month,
    required this.total,
    required this.breakdown,
  });

  /// The first day of the month.
  final DateTime month;

  /// The month's spending — the sum of every category, as on the dashboard.
  final double total;

  /// Every category with spending, largest first.
  final List<CategorySpend> breakdown;

  bool get isEmpty => breakdown.isEmpty;

  /// The category's figures for the month, or null when it has none. A null
  /// [categoryId] is the uncategorised group.
  CategorySpend? category(String? categoryId) {
    for (final CategorySpend c in breakdown) {
      if (c.categoryId == categoryId) return c;
    }
    return null;
  }
}

/// [personalExpenses] — the month's own spending, already through
/// [personalSpending] — grouped exactly as the dashboard groups them.
CategoryMonthSpending buildCategoryMonthSpending(
  DateTime month,
  List<Expense> personalExpenses,
  List<ExpenseCategory> categories,
) {
  final List<CategorySpend> breakdown =
      buildCategoryBreakdown(personalExpenses, categories);
  return CategoryMonthSpending(
    month: DateTime(month.year, month.month, 1),
    total: breakdown.fold<double>(0, (double sum, CategorySpend c) => sum + c.total),
    breakdown: breakdown,
  );
}
