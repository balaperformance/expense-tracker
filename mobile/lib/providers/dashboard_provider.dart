import '../core/utils/date_utils.dart';
import '../models/analytics.dart';
import '../models/expense.dart';
import '../models/expense_category.dart';
import '../models/income.dart';
import '../repositories/expense_repository.dart';
import '../repositories/income_repository.dart';
import 'async_state.dart';

/// Builds everything the dashboard shows in one pass.
///
/// The underlying reads are issued concurrently, and the result is cached
/// until something invalidates it, so switching tabs does not re-query.
class DashboardProvider extends AsyncProvider {
  DashboardProvider({
    required ExpenseRepository expenses,
    required IncomeRepository income,
  })  : _expenses = expenses,
        _income = income;

  final ExpenseRepository _expenses;
  final IncomeRepository _income;

  static const int _trendMonths = 6;

  DashboardData? _data;
  bool _stale = true;
  String? _userId;
  DateTime _month = AppDateUtils.firstDayOf(DateTime.now());
  DateTime? _earliest;

  DashboardData? get data => _data;

  /// The month the dashboard shows; the current one until the user picks.
  DateTime get month => _month;

  /// Whether [month] is the month in progress.
  bool get isCurrentMonth =>
      _month == AppDateUtils.firstDayOf(DateTime.now());

  /// Chooses the month every figure is for; the next [load] reads it.
  /// Nothing after the current month can be chosen.
  void setMonth(DateTime month) {
    final DateTime current = AppDateUtils.firstDayOf(DateTime.now());
    DateTime next = AppDateUtils.firstDayOf(month);
    if (next.isAfter(current)) next = current;
    if (next == _month) return;
    _month = next;
    _stale = true;
    safeNotify();
  }

  /// The first month with any expense or income, for the month picker;
  /// read once and kept. Null when there is nothing yet.
  Future<DateTime?> earliestMonth({required String userId}) async {
    final DateTime? known = _earliest;
    if (known != null) return known;
    final List<DateTime?> firsts = await Future.wait(<Future<DateTime?>>[
      _expenses.fetchEarliestDate(userId: userId),
      _income.fetchEarliestDate(userId: userId),
    ]);
    DateTime? first;
    for (final DateTime? d in firsts) {
      if (d != null && (first == null || d.isBefore(first))) first = d;
    }
    _earliest = first == null ? null : AppDateUtils.firstDayOf(first);
    return _earliest;
  }

  @override
  bool get isEmptyData => _data == null;

  /// Marks the cache dirty after a mutation elsewhere in the app. An older
  /// entry may have been added, so the picker's first month is read again.
  void invalidate() {
    _stale = true;
    _earliest = null;
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

    final DateTime anchor = _month;
    final List<DateTime> months =
        AppDateUtils.trailingMonths(anchor, _trendMonths);
    final DateTime trendStart = months.first;
    final DateTime trendEnd = AppDateUtils.addMonths(anchor, 1);

    try {
      // Purchases paid for someone else are owed back, not spending. Only the
      // expense trend needs them, so every other read starts at once.
      final Future<Set<String>> paidForRead =
          _expenses.fetchPaidForExpenseIds(userId: userId);
      final List<Object> results = await Future.wait(<Future<Object>>[
        paidForRead,
        _expenses.fetchForMonth(userId: userId, month: anchor),
        _income.fetchForMonth(userId: userId, month: anchor),
        paidForRead.then((Set<String> paidFor) => _expenses.fetchMonthlyTotals(
              userId: userId,
              from: trendStart,
              toExclusive: trendEnd,
              exclude: paidFor,
            )),
        _income.fetchMonthlyTotals(
          userId: userId,
          from: trendStart,
          toExclusive: trendEnd,
        ),
      ]);

      final Set<String> paidFor = results[0] as Set<String>;
      final List<Expense> allMonthExpenses = results[1] as List<Expense>;
      final List<Expense> monthExpenses =
          personalSpending(allMonthExpenses, paidFor);
      // Received for someone else: listed, never income.
      final List<Income> monthIncome =
          personalIncome(results[2] as List<Income>);
      final Map<String, double> expenseTotals =
          results[3] as Map<String, double>;
      final Map<String, double> incomeTotals =
          results[4] as Map<String, double>;

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
        // Non-personal purchases are still recent activity — marked as such
        // in the row — though never spending.
        recentExpenses: allMonthExpenses
            .where((Expense e) => !paidFor.contains(e.id))
            .take(5)
            .toList(),
        categoryBreakdown: buildCategoryBreakdown(monthExpenses, categories),
        trend: months
            .map((DateTime m) => MonthlyPoint(
                  month: m,
                  expense: expenseTotals[AppDateUtils.monthKey(m)] ?? 0,
                  income: incomeTotals[AppDateUtils.monthKey(m)] ?? 0,
                ))
            .toList(),
      );

      _stale = false;
      setReady();
    } catch (error) {
      setError(error);
    }
  }

  void reset() {
    _data = null;
    _userId = null;
    _stale = true;
    _month = AppDateUtils.firstDayOf(DateTime.now());
    _earliest = null;
    safeNotify();
  }
}
