import '../core/utils/date_utils.dart';
import '../models/analytics.dart';
import '../models/budget.dart';
import '../models/expense.dart';
import '../models/expense_category.dart';
import '../models/income.dart';
import '../repositories/budget_repository.dart';
import '../repositories/expense_repository.dart';
import '../repositories/income_repository.dart';
import 'async_state.dart';

/// Builds everything the dashboard shows in one pass.
///
/// The five underlying reads are issued concurrently, and the result is cached
/// until something invalidates it, so switching tabs does not re-query.
class DashboardProvider extends AsyncProvider {
  DashboardProvider({
    required ExpenseRepository expenses,
    required IncomeRepository income,
    required BudgetRepository budgets,
  })  : _expenses = expenses,
        _income = income,
        _budgets = budgets;

  final ExpenseRepository _expenses;
  final IncomeRepository _income;
  final BudgetRepository _budgets;

  static const int _trendMonths = 6;

  DashboardData? _data;
  bool _stale = true;
  String? _userId;

  DashboardData? get data => _data;

  @override
  bool get isEmptyData => _data == null;

  /// Marks the cache dirty after a mutation elsewhere in the app.
  void invalidate() {
    _stale = true;
  }

  /// Loads only if the cache is dirty, unless [force] is set (pull-to-refresh).
  Future<void> load({
    required String userId,
    required List<ExpenseCategory> categories,
    bool force = false,
  }) async {
    if (_userId != userId) {
      _userId = userId;
      _stale = true;
    }
    if (!_stale && !force && _data != null) return;

    if (_data == null) setLoading();

    final DateTime anchor = DateTime.now();
    final List<DateTime> months =
        AppDateUtils.trailingMonths(anchor, _trendMonths);
    final DateTime trendStart = months.first;
    final DateTime trendEnd = AppDateUtils.addMonths(anchor, 1);

    try {
      final List<Object> results = await Future.wait(<Future<Object>>[
        _expenses.fetchForMonth(userId: userId, month: anchor),
        _income.fetchForMonth(userId: userId, month: anchor),
        _expenses.fetchMonthlyTotals(
          userId: userId,
          from: trendStart,
          toExclusive: trendEnd,
        ),
        _income.fetchMonthlyTotals(
          userId: userId,
          from: trendStart,
          toExclusive: trendEnd,
        ),
        _budgets
            .fetchOverall(userId: userId, month: anchor)
            .then((Budget? b) => <Budget?>[b]),
      ]);

      final List<Expense> monthExpenses = results[0] as List<Expense>;
      final List<Income> monthIncome = results[1] as List<Income>;
      final Map<String, double> expenseTotals =
          results[2] as Map<String, double>;
      final Map<String, double> incomeTotals =
          results[3] as Map<String, double>;
      final Budget? overall = (results[4] as List<Budget?>).first;

      final double totalExpense = monthExpenses.fold<double>(
        0,
        (double sum, Expense e) => sum + e.amount,
      );
      final double totalIncome = monthIncome.fold<double>(
        0,
        (double sum, Income i) => sum + i.amount,
      );

      _data = DashboardData(
        month: AppDateUtils.firstDayOf(anchor),
        totalExpense: totalExpense,
        totalIncome: totalIncome,
        recentExpenses: monthExpenses.take(5).toList(),
        categoryBreakdown: buildCategoryBreakdown(monthExpenses, categories),
        trend: months
            .map((DateTime m) => MonthlyPoint(
                  month: m,
                  expense: expenseTotals[_key(m)] ?? 0,
                  income: incomeTotals[_key(m)] ?? 0,
                ))
            .toList(),
        overallBudget: overall?.amount,
        overallSpent: totalExpense,
      );

      _stale = false;
      setReady();
    } catch (error) {
      setError(error);
    }
  }

  static String _key(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}';

  void reset() {
    _data = null;
    _userId = null;
    _stale = true;
    safeNotify();
  }
}
