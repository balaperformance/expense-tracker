import '../core/utils/date_utils.dart';
import '../models/budget.dart';
import '../models/expense.dart';
import '../repositories/budget_repository.dart';
import '../repositories/expense_repository.dart';
import 'async_state.dart';

/// Budgets for a selected month, each paired with actual spend.
///
/// Spend is derived from one month-scoped expense read rather than a query
/// per budget, so adding budgets does not multiply network calls.
class BudgetProvider extends AsyncProvider {
  BudgetProvider({
    required BudgetRepository budgets,
    required ExpenseRepository expenses,
  })  : _budgets = budgets,
        _expenses = expenses;

  final BudgetRepository _budgets;
  final ExpenseRepository _expenses;

  List<BudgetProgress> _progress = <BudgetProgress>[];
  BudgetProgress? _overall;
  DateTime _month = AppDateUtils.firstDayOf(DateTime.now());
  String? _userId;
  bool _stale = true;

  List<BudgetProgress> get categoryBudgets =>
      List<BudgetProgress>.unmodifiable(_progress);

  BudgetProgress? get overall => _overall;
  DateTime get month => _month;

  bool get hasAny => _overall != null || _progress.isNotEmpty;

  @override
  bool get isEmptyData => !hasAny;

  /// Budgets at or over their limit, surfaced as dashboard warnings.
  List<BudgetProgress> get alerts => <BudgetProgress>[
        if (_overall != null && (_overall!.isOver || _overall!.isApproaching))
          _overall!,
        ..._progress.where(
          (BudgetProgress p) => p.isOver || p.isApproaching,
        ),
      ];

  void invalidate() => _stale = true;

  void setMonth(DateTime month) {
    final DateTime normalised = AppDateUtils.firstDayOf(month);
    if (normalised == _month) return;
    _month = normalised;
    _stale = true;
  }

  Future<void> load({required String userId, bool force = false}) async {
    if (_userId != userId) {
      _userId = userId;
      _stale = true;
    }
    if (!_stale && !force && isReady) return;

    if (!hasAny) setLoading();

    try {
      final List<Object> results = await Future.wait(<Future<Object>>[
        _budgets.fetchForMonth(userId: userId, month: _month),
        _expenses.fetchForMonth(userId: userId, month: _month),
      ]);

      final List<Budget> budgets = results[0] as List<Budget>;
      final List<Expense> expenses = results[1] as List<Expense>;

      final Map<String?, double> spendByCategory = <String?, double>{};
      double total = 0;
      for (final Expense e in expenses) {
        spendByCategory[e.categoryId] =
            (spendByCategory[e.categoryId] ?? 0) + e.amount;
        total += e.amount;
      }

      Budget? overallBudget;
      final List<BudgetProgress> categoryProgress = <BudgetProgress>[];

      for (final Budget b in budgets) {
        if (b.isOverall) {
          overallBudget = b;
        } else {
          categoryProgress.add(
            BudgetProgress(
              budget: b,
              spent: spendByCategory[b.categoryId] ?? 0,
            ),
          );
        }
      }

      categoryProgress.sort(
        (BudgetProgress a, BudgetProgress b) => b.ratio.compareTo(a.ratio),
      );

      _overall = overallBudget == null
          ? null
          : BudgetProgress(budget: overallBudget, spent: total);
      _progress = categoryProgress;
      _stale = false;
      setReady();
    } catch (error) {
      setError(error);
    }
  }

  Future<bool> setBudget({
    required String? categoryId,
    required double amount,
  }) async {
    final String? userId = _userId;
    if (userId == null) return false;

    final bool ok = await guard(() async {
      await _budgets.setBudget(
        userId: userId,
        categoryId: categoryId,
        month: _month,
        amount: amount,
      );
    });

    if (ok) {
      _stale = true;
      await load(userId: userId, force: true);
    }
    return ok;
  }

  Future<bool> delete(String budgetId) async {
    final String? userId = _userId;
    if (userId == null) return false;

    final bool ok = await guard(() async {
      await _budgets.delete(userId: userId, id: budgetId);
    });

    if (ok) {
      _stale = true;
      await load(userId: userId, force: true);
    }
    return ok;
  }

  /// Returns how many budgets were carried forward, or -1 on failure.
  Future<int> copyFromPreviousMonth() async {
    final String? userId = _userId;
    if (userId == null) return -1;

    int copied = 0;
    final bool ok = await guard(() async {
      copied = await _budgets.copyFromPreviousMonth(
        userId: userId,
        targetMonth: _month,
      );
    });

    if (!ok) return -1;
    if (copied > 0) {
      _stale = true;
      await load(userId: userId, force: true);
    }
    return copied;
  }

  void reset() {
    _progress = <BudgetProgress>[];
    _overall = null;
    _userId = null;
    _month = AppDateUtils.firstDayOf(DateTime.now());
    _stale = true;
    safeNotify();
  }
}
