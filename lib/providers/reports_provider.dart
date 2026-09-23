import '../core/utils/date_utils.dart';
import '../models/analytics.dart';
import '../models/expense.dart';
import '../models/expense_category.dart';
import '../models/income.dart';
import '../repositories/expense_repository.dart';
import '../repositories/income_repository.dart';
import 'async_state.dart';

/// Report figures for a user-selected month.
///
/// Results are memoised per month so stepping back and forth through recent
/// months does not re-query what was already fetched.
class ReportsProvider extends AsyncProvider {
  ReportsProvider({
    required ExpenseRepository expenses,
    required IncomeRepository income,
  })  : _expenses = expenses,
        _income = income;

  final ExpenseRepository _expenses;
  final IncomeRepository _income;

  static const int _trendMonths = 6;

  final Map<String, ReportData> _cache = <String, ReportData>{};
  DateTime _month = AppDateUtils.firstDayOf(DateTime.now());
  String? _userId;

  DateTime get month => _month;
  ReportData? get report => _cache[_key(_month)];

  @override
  bool get isEmptyData => report == null;

  /// Future months have no data to show, so the UI disables stepping forward.
  bool get canGoForward {
    final DateTime current = AppDateUtils.firstDayOf(DateTime.now());
    return _month.isBefore(current);
  }

  void invalidate() => _cache.clear();

  Future<void> setMonth(DateTime month, List<ExpenseCategory> categories) async {
    final DateTime normalised = AppDateUtils.firstDayOf(month);
    if (normalised == _month && report != null) return;
    _month = normalised;
    await load(categories: categories);
  }

  Future<void> stepMonth(int delta, List<ExpenseCategory> categories) =>
      setMonth(AppDateUtils.addMonths(_month, delta), categories);

  Future<void> load({
    String? userId,
    required List<ExpenseCategory> categories,
    bool force = false,
  }) async {
    if (userId != null && userId != _userId) {
      _userId = userId;
      _cache.clear();
    }
    final String? id = _userId;
    if (id == null) return;

    if (!force && _cache.containsKey(_key(_month))) {
      setReady();
      return;
    }

    setLoading();

    final List<DateTime> months =
        AppDateUtils.trailingMonths(_month, _trendMonths);

    try {
      final List<Object> results = await Future.wait(<Future<Object>>[
        _expenses.fetchForMonth(userId: id, month: _month),
        _income.fetchForMonth(userId: id, month: _month),
        _expenses.fetchMonthlyTotals(
          userId: id,
          from: months.first,
          toExclusive: AppDateUtils.addMonths(_month, 1),
        ),
        _income.fetchMonthlyTotals(
          userId: id,
          from: months.first,
          toExclusive: AppDateUtils.addMonths(_month, 1),
        ),
      ]);

      final List<Expense> monthExpenses = results[0] as List<Expense>;
      final List<Income> monthIncome = results[1] as List<Income>;
      final Map<String, double> expenseTotals =
          results[2] as Map<String, double>;
      final Map<String, double> incomeTotals =
          results[3] as Map<String, double>;

      final List<CategorySpend> breakdown =
          buildCategoryBreakdown(monthExpenses, categories);

      _cache[_key(_month)] = ReportData(
        month: _month,
        totalExpense: monthExpenses.fold<double>(
          0,
          (double sum, Expense e) => sum + e.amount,
        ),
        totalIncome: monthIncome.fold<double>(
          0,
          (double sum, Income i) => sum + i.amount,
        ),
        categoryBreakdown: breakdown,
        trend: months
            .map((DateTime m) => MonthlyPoint(
                  month: m,
                  expense: expenseTotals[_key(m)] ?? 0,
                  income: incomeTotals[_key(m)] ?? 0,
                ))
            .toList(),
        transactionCount: monthExpenses.length,
        topCategory: breakdown.isEmpty ? null : breakdown.first,
      );

      setReady();
    } catch (error) {
      setError(error);
    }
  }

  static String _key(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}';

  void reset() {
    _cache.clear();
    _userId = null;
    _month = AppDateUtils.firstDayOf(DateTime.now());
    safeNotify();
  }
}
