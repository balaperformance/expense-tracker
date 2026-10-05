import 'dart:async';

import '../core/constants/app_constants.dart';
import '../core/utils/date_utils.dart';
import '../models/expense.dart';
import '../models/expense_filter.dart';
import '../models/frequent_expense.dart';
import '../models/receivable.dart';
import '../models/tag.dart';
import '../repositories/expense_repository.dart';
import '../repositories/receivable_repository.dart';
import '../repositories/tag_repository.dart';
import '../services/schema_capabilities.dart';
import 'async_state.dart';

/// What Quick add reads: recent purchases, and the ids of those paid for
/// someone else (owed back, so not the user's own habits).
typedef QuickAddHistory = ({List<Expense> expenses, Set<String> paidForIds});

/// Paginated, filterable expense list.
///
/// Search input is debounced so typing does not fire a request per keystroke,
/// and a filter change that resolves to the same query is ignored.
class ExpenseProvider extends AsyncProvider {
  ExpenseProvider(
    this._repository, {
    TagRepository? tags,
    ReceivableRepository? receivables,
  })  : _tags = tags,
        _receivables = receivables;

  final ExpenseRepository _repository;

  /// Reads and writes an expense's tags (migration 006). Without it the form
  /// offers no tags.
  final TagRepository? _tags;

  /// Marks an expense as paid for someone else (migration 005). Without it
  /// the form offers no "Paid for someone else".
  final ReceivableRepository? _receivables;

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

  static const Duration _quickAddFresh = Duration(minutes: 5);
  QuickAddHistory? _quickAdd;
  String? _quickAddKey;
  DateTime? _quickAddAt;

  List<Expense> get expenses => List<Expense>.unmodifiable(_expenses);
  ExpenseFilter get filter => _filter;
  bool get hasMore => _hasMore;
  bool get loadingMore => _loadingMore;
  int get revision => _revision;

  /// Tags can be read and saved with an expense.
  bool get tagsAvailable => _tags != null && SchemaCapabilities.tags;

  /// An expense can be marked as paid for someone else.
  bool get paidForAvailable =>
      _receivables != null && SchemaCapabilities.treatments;

  /// Set by [save] when the expense was saved but who it was paid for or its
  /// tags were not — said once, so the user is never invited to save the
  /// same expense twice.
  String? _saveWarning;
  String? get saveWarning => _saveWarning;

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
    String? creditCardId,
  }) async {
    final String? userId = _userId;
    if (userId == null) return null;
    return _repository.findPossibleDuplicate(
      userId: userId,
      amount: amount,
      date: date,
      reference: reference,
      bankAccountId: bankAccountId,
      creditCardId: creditCardId,
    );
  }

  /// The history behind Quick add on a new expense.
  ///
  /// Reused until an expense changes here, the day turns, or a few minutes
  /// pass (imports write elsewhere), so opening the form again costs nothing.
  /// Read-only and outside [guard], like [findPossibleDuplicate]: a failed
  /// read only means no suggestions, never an error on the list.
  Future<QuickAddHistory?> quickAddHistory({required String userId}) async {
    final DateTime today = AppDateUtils.today();
    final String key =
        '$userId|$_revision|${AppDateUtils.toDateString(today)}';
    final DateTime now = DateTime.now();
    final QuickAddHistory? cached = _quickAdd;
    final DateTime? at = _quickAddAt;
    if (cached != null &&
        _quickAddKey == key &&
        at != null &&
        now.difference(at) < _quickAddFresh) {
      return cached;
    }
    try {
      final (List<Expense>, Set<String>) read = await (
        _repository.fetchRecent(
          userId: userId,
          from: DateTime(
            today.year,
            today.month,
            today.day - (frequentWindowDays - 1),
          ),
          toExclusive: DateTime(today.year, today.month, today.day + 1),
          limit: frequentHistoryRows,
        ),
        _repository.fetchPaidForExpenseIds(userId: userId),
      ).wait;
      final QuickAddHistory history = (expenses: read.$1, paidForIds: read.$2);
      _quickAdd = history;
      _quickAddKey = key;
      _quickAddAt = now;
      return history;
    } catch (_) {
      return null;
    }
  }

  Future<bool> create(Expense expense) async {
    final bool ok = await guard(() async {
      _keepCreated(await _repository.create(expense));
      _revision++;
      safeNotify();
    });
    return ok;
  }

  Future<bool> update(Expense expense) async {
    return guard(() async {
      _keepUpdated(await _repository.update(expense));
      _revision++;
      safeNotify();
    });
  }

  void _keepCreated(Expense created) {
    if (_matchesCurrentFilter(created)) {
      _expenses = <Expense>[created, ..._expenses];
    }
  }

  void _keepUpdated(Expense updated) {
    _expenses = _expenses
        .map((Expense e) => e.id == updated.id ? updated : e)
        .toList();
  }

  /// Saves the expense form: creates [expense] when it has no id yet,
  /// otherwise updates it — then applies [paidFor] and, unless [tags] is
  /// null, makes them its complete set of tags.
  ///
  /// Returns whether the expense itself was saved. Who it was paid for and
  /// its tags are each one write of their own after it; if either fails the
  /// expense stays saved (as the user's own spending, with the tags it had)
  /// and [saveWarning] says what was not, rather than reporting a failure
  /// that would invite a second save of the same expense.
  Future<bool> save(
    Expense expense, {
    PaidForChange paidFor = const PaidForChange.keep(),
    List<String>? tags,
  }) async {
    _saveWarning = null;
    final bool isNew = expense.id.isEmpty;
    Expense? saved;
    final bool ok = await guard(() async {
      saved = isNew
          ? await _repository.create(expense)
          : await _repository.update(expense);
    });
    final Expense? row = saved;
    if (!ok || row == null) return false;

    final List<String> problems = <String>[];
    final ReceivableRepository? receivables = _receivables;
    if (!paidFor.keeps &&
        receivables != null &&
        SchemaCapabilities.treatments) {
      try {
        await receivables.setExpensePaidFor(
          userId: row.userId,
          expenseId: row.id,
          paidFor: paidFor.draft,
        );
      } catch (_) {
        problems.add(paidFor.clears
            ? 'it is still marked as paid for someone else'
            : 'it could not be marked as paid for someone else');
      }
    }
    final TagRepository? tagWriter = _tags;
    if (tags != null && tagWriter != null && SchemaCapabilities.tags) {
      try {
        await tagWriter.setTags(kind: TagKind.expense, id: row.id, names: tags);
      } catch (_) {
        problems.add('its tags were not');
      }
    }
    if (problems.isNotEmpty) {
      _saveWarning = 'The expense was saved, but ${problems.join(', and ')}. '
          'Open it to try again.';
    }

    if (isNew) {
      _keepCreated(row);
    } else {
      _keepUpdated(row);
    }
    // Once, after every write, so what depends on the revision re-reads the
    // paid-for exclusions and tags too.
    _revision++;
    safeNotify();
    return true;
  }

  /// Every tag the user has and the names of those on [expenseId] (none for
  /// a new expense); null when tags are unavailable or could not be read, so
  /// the form neither shows nor changes them. Read-only, outside [guard].
  Future<({List<Tag> known, List<String> names})?> tagsFor({
    required String userId,
    String? expenseId,
  }) async {
    final TagRepository? tags = _tags;
    if (tags == null) return null;
    try {
      final ({List<Tag> known, List<String> names}) read =
          await tags.fetchForRow(
        userId: userId,
        kind: TagKind.expense,
        id: expenseId,
      );
      // Resolved by the read: before migration 006 there is nothing to show.
      return SchemaCapabilities.tags ? read : null;
    } catch (_) {
      return null;
    }
  }

  /// One saved expense, to open it from elsewhere; null when it has been
  /// deleted since. Read-only, outside [guard].
  Future<Expense?> fetchById({required String userId, required String id}) =>
      _repository.fetchById(userId: userId, id: id);

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
    _quickAdd = null;
    _quickAddKey = null;
    _quickAddAt = null;
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
