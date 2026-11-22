import '../core/utils/date_utils.dart';
import '../models/analytics.dart';
import '../models/expense.dart';
import '../models/expense_category.dart';
import '../repositories/expense_repository.dart';
import 'async_state.dart';

/// Spending by category for any month — the screens behind the dashboard's
/// "Where it went" card.
///
/// Reads and counts the month exactly as the dashboard does (its expenses,
/// less purchases paid for someone else and non-personal ones, grouped by
/// [buildCategoryBreakdown]), so the two always show the same figures.
/// Months are kept once read, so stepping back and forth does not re-query;
/// [invalidate] drops them after a change.
class CategorySpendingProvider extends AsyncProvider {
  CategorySpendingProvider({required ExpenseRepository expenses})
      : _expenses = expenses;

  final ExpenseRepository _expenses;

  final Map<String, CategoryMonthSpending> _cache =
      <String, CategoryMonthSpending>{};
  String? _userId;
  DateTime? _earliest;
  bool _earliestRead = false;
  DateTime? _requested;

  /// The month's figures once read; null before that.
  CategoryMonthSpending? spendingFor(DateTime month) =>
      _cache[AppDateUtils.monthKey(month)];

  /// The first month with any expense; null until read, or when there is none.
  DateTime? get earliest => _earliest;

  @override
  bool get isEmptyData {
    final DateTime? month = _requested;
    return month == null || spendingFor(month) == null;
  }

  /// Something was added, changed or deleted: every month is read again.
  void invalidate() {
    _cache.clear();
    _earliest = null;
    _earliestRead = false;
  }

  /// Reads [month] unless it is already known (or [force] is set).
  Future<void> load({
    required String userId,
    required DateTime month,
    required List<ExpenseCategory> categories,
    bool force = false,
  }) async {
    if (_userId != userId) {
      _userId = userId;
      invalidate();
    }
    final DateTime first = AppDateUtils.firstDayOf(month);
    _requested = first;
    if (!force && spendingFor(first) != null) {
      setReady();
      return;
    }

    setLoading();
    try {
      final List<Object?> read = await Future.wait(<Future<Object?>>[
        _expenses.fetchPaidForExpenseIds(userId: userId),
        _expenses.fetchForMonth(userId: userId, month: first),
        if (!_earliestRead) _expenses.fetchEarliestDate(userId: userId),
      ]);
      if (_userId != userId) return; // signed out meanwhile
      if (read.length > 2) {
        final DateTime? earliest = read[2] as DateTime?;
        _earliest = earliest == null ? null : AppDateUtils.firstDayOf(earliest);
        _earliestRead = true;
      }
      final List<Expense> own =
          personalSpending(read[1]! as List<Expense>, read[0]! as Set<String>);
      _cache[AppDateUtils.monthKey(first)] =
          buildCategoryMonthSpending(first, own, categories);
      setReady();
    } catch (error) {
      setError(error);
    }
  }

  void reset() {
    _userId = null;
    _requested = null;
    invalidate();
    safeNotify();
  }
}
