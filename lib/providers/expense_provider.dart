import 'dart:async';

import '../core/constants/app_constants.dart';
import '../models/expense.dart';
import '../models/expense_filter.dart';
import '../repositories/expense_repository.dart';
import 'async_state.dart';

/// Paginated, filterable expense list.
///
/// Search input is debounced so typing does not fire a request per keystroke,
/// and a filter change that resolves to the same query is ignored.
class ExpenseProvider extends AsyncProvider {
  ExpenseProvider(this._repository);

  final ExpenseRepository _repository;

  static const Duration _searchDebounce = Duration(milliseconds: 350);

  List<Expense> _expenses = <Expense>[];
  ExpenseFilter _filter = const ExpenseFilter();
  String? _userId;

  int _page = 0;
  bool _hasMore = true;
  bool _loadingMore = false;
  Timer? _debounce;

  /// Incremented on every mutation so dependent screens can tell their cached
  /// aggregates are stale without re-fetching eagerly.
  int _revision = 0;

  List<Expense> get expenses => List<Expense>.unmodifiable(_expenses);
  ExpenseFilter get filter => _filter;
  bool get hasMore => _hasMore;
  bool get loadingMore => _loadingMore;
  int get revision => _revision;

  @override
  bool get isEmptyData => _expenses.isEmpty;

  bool get showEmptyState =>
      isReady && _expenses.isEmpty && !_filter.hasAnyFilter;

  bool get showNoResults =>
      isReady && _expenses.isEmpty && _filter.hasAnyFilter;

  void attachUser(String userId) {
    if (_userId == userId) return;
    _userId = userId;
    unawaited(refresh());
  }

  Future<void> refresh() async {
    final String? userId = _userId;
    if (userId == null) return;

    setLoading();
    _page = 0;
    _hasMore = true;

    try {
      final List<Expense> rows = await _repository.fetchPage(
        userId: userId,
        filter: _filter,
        page: 0,
      );
      _expenses = rows;
      _hasMore = rows.length == AppConstants.pageSize;
      setReady();
    } catch (error) {
      setError(error);
    }
  }

  Future<void> loadMore() async {
    final String? userId = _userId;
    if (userId == null || _loadingMore || !_hasMore || isLoading) return;

    _loadingMore = true;
    safeNotify();

    try {
      final List<Expense> rows = await _repository.fetchPage(
        userId: userId,
        filter: _filter,
        page: _page + 1,
      );
      _page += 1;
      _expenses = <Expense>[..._expenses, ...rows];
      _hasMore = rows.length == AppConstants.pageSize;
    } catch (error) {
      setError(error);
    } finally {
      _loadingMore = false;
      safeNotify();
    }
  }

  void setSearch(String value) {
    if (value == _filter.search) return;
    _filter = _filter.copyWith(search: value);
    safeNotify();

    _debounce?.cancel();
    _debounce = Timer(_searchDebounce, () {
      if (isDisposed) return;
      unawaited(refresh());
    });
  }

  void applyFilter(ExpenseFilter next) {
    if (next == _filter) return;
    _filter = next;
    unawaited(refresh());
  }

  void clearFilters() => applyFilter(_filter.cleared());

  void setSort(ExpenseSort sort) {
    if (sort == _filter.sort) return;
    applyFilter(_filter.copyWith(sort: sort));
  }

  /// Checks whether an expense already on file looks like this one.
  ///
  /// Read-only, and outside [guard] on purpose: this runs while the user is
  /// still reviewing a draft, and a failed lookup must not put the whole
  /// list into an error state over a warning that was only advisory.
  Future<Expense?> findPossibleDuplicate({
    required double amount,
    required DateTime date,
    String? reference,
    String? bankAccountId,
  }) async {
    final String? userId = _userId;
    if (userId == null) return null;
    return _repository.findPossibleDuplicate(
      userId: userId,
      amount: amount,
      date: date,
      reference: reference,
      bankAccountId: bankAccountId,
    );
  }

  Future<bool> create(Expense expense) async {
    final bool ok = await guard(() async {
      final Expense created = await _repository.create(expense);
      if (_matchesCurrentFilter(created)) {
        _expenses = <Expense>[created, ..._expenses];
      }
      _revision++;
      safeNotify();
    });
    return ok;
  }

  Future<bool> update(Expense expense) async {
    return guard(() async {
      final Expense updated = await _repository.update(expense);
      _expenses = _expenses
          .map((Expense e) => e.id == updated.id ? updated : e)
          .toList();
      _revision++;
      safeNotify();
    });
  }

  /// Removes optimistically and restores the row if the delete fails, so the
  /// list never lies about what is stored.
  Future<bool> delete(Expense expense) async {
    final List<Expense> snapshot = _expenses;
    _expenses = _expenses.where((Expense e) => e.id != expense.id).toList();
    safeNotify();

    final bool ok = await guard(() async {
      await _repository.delete(userId: expense.userId, id: expense.id);
      _revision++;
    });

    if (!ok) {
      _expenses = snapshot;
      safeNotify();
    }
    return ok;
  }

  /// Local predicate mirroring the server filter, used to decide whether a
  /// newly created row belongs in the currently displayed list.
  bool _matchesCurrentFilter(Expense expense) {
    if (_filter.categoryIds.isNotEmpty &&
        !_filter.categoryIds.contains(expense.categoryId)) {
      return false;
    }
    if (_filter.paymentMethodIds.isNotEmpty &&
        !_filter.paymentMethodIds.contains(expense.paymentMethodId)) {
      return false;
    }
    final DateTime? from = _filter.from;
    if (from != null && expense.expenseDate.isBefore(from)) return false;
    final DateTime? to = _filter.to;
    if (to != null && expense.expenseDate.isAfter(to)) return false;

    final String term = _filter.search.trim().toLowerCase();
    if (term.isEmpty) return true;
    return <String?>[expense.merchant, expense.description, expense.notes].any(
      (String? field) => (field ?? '').toLowerCase().contains(term),
    );
  }

  void reset() {
    _expenses = <Expense>[];
    _filter = const ExpenseFilter();
    _userId = null;
    _page = 0;
    _hasMore = true;
    safeNotify();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}
