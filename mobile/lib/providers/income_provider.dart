import 'dart:async';

import '../core/constants/app_constants.dart';
import '../core/utils/date_utils.dart';
import '../models/analytics.dart';
import '../models/income.dart';
import '../models/tag.dart';
import '../repositories/income_repository.dart';
import '../repositories/tag_repository.dart';
import '../services/schema_capabilities.dart';
import 'async_state.dart';

class IncomeProvider extends AsyncProvider {
  IncomeProvider(this._repository, {TagRepository? tags}) : _tags = tags;

  final IncomeRepository _repository;

  /// Reads and writes an income row's tags (migration 006). Without it the
  /// form offers no tags.
  final TagRepository? _tags;

  /// Tags can be read and saved with an income entry.
  bool get tagsAvailable => _tags != null && SchemaCapabilities.tags;

  /// Set by [save] when the income was saved but its tags were not.
  String? _saveWarning;
  String? get saveWarning => _saveWarning;

  static const Duration _searchDebounce = Duration(milliseconds: 350);

  List<Income> _items = <Income>[];
  String _search = '';
  String? _userId;

  // The date range the list is narrowed to (both inclusive); null is open.
  DateTime? _from;
  DateTime? _to;

  // What the whole range adds up to, not only the pages loaded so far.
  ({double total, int count})? _rangeSummary;
  int _summaryRequest = 0;

  int _page = 0;
  bool _hasMore = true;
  bool _loadingMore = false;
  Timer? _debounce;
  int _revision = 0;

  List<Income> get items => List<Income>.unmodifiable(_items);
  String get search => _search;
  DateTime? get from => _from;
  DateTime? get to => _to;

  /// A date range is set — the Filter button's badge.
  bool get hasRange => _from != null || _to != null;

  /// For the active range (and search): the personal income received and
  /// how many entries there are. Null without a range, or while it loads.
  ({double total, int count})? get rangeSummary => _rangeSummary;
  bool get hasMore => _hasMore;
  bool get loadingMore => _loadingMore;
  int get revision => _revision;

  @override
  bool get isEmptyData => _items.isEmpty;

  bool get showEmptyState =>
      isReady && _items.isEmpty && _search.isEmpty && !hasRange;
  bool get showNoResults =>
      isReady && _items.isEmpty && (_search.isNotEmpty || hasRange);

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
      final List<Income> rows = await _repository.fetchPage(
        userId: userId,
        page: 0,
        search: _search,
        from: _from,
        to: _to,
      );
      _items = rows;
      _hasMore = rows.length == AppConstants.pageSize;
      setReady();
      unawaited(_loadRangeSummary());
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
      final List<Income> rows = await _repository.fetchPage(
        userId: userId,
        page: _page + 1,
        search: _search,
        from: _from,
        to: _to,
      );
      _page += 1;
      _items = <Income>[..._items, ...rows];
      _hasMore = rows.length == AppConstants.pageSize;
    } catch (error) {
      setError(error);
    } finally {
      _loadingMore = false;
      safeNotify();
    }
  }

  void setSearch(String value) {
    if (value == _search) return;
    _search = value;
    safeNotify();

    _debounce?.cancel();
    _debounce = Timer(_searchDebounce, () {
      if (isDisposed) return;
      unawaited(refresh());
    });
  }

  /// Narrows the list to [from]–[to] (inclusive; either may be null) and
  /// reloads it. Both null shows everything again.
  Future<void> setRange(DateTime? from, DateTime? to) async {
    if (from == _from && to == _to) return;
    _from = from;
    _to = to;
    _rangeSummary = null;
    await refresh();
  }

  Future<void> clearRange() => setRange(null, null);

  /// The range's total, read over every row in it, so it never depends on
  /// how far the list has been scrolled. Money received for someone else is
  /// listed but, as everywhere, not counted.
  Future<void> _loadRangeSummary() async {
    final String? userId = _userId;
    final int request = ++_summaryRequest;
    if (userId == null || !hasRange) {
      _rangeSummary = null;
      return;
    }
    try {
      final List<Income> rows = await _repository.fetchRange(
        userId: userId,
        from: _from ?? DateTime(1970),
        toExclusive: (_to ?? AppDateUtils.today()).add(const Duration(days: 1)),
      );
      final String term = _search.trim().toLowerCase();
      final List<Income> matching = term.isEmpty
          ? rows
          : rows.where((Income i) {
              return (i.source ?? '').toLowerCase().contains(term) ||
                  (i.description ?? '').toLowerCase().contains(term);
            }).toList();
      if (request != _summaryRequest || isDisposed) return;
      _rangeSummary = (
        total: personalIncome(matching)
            .fold<double>(0, (double sum, Income i) => sum + i.amount),
        count: matching.length,
      );
      safeNotify();
    } catch (_) {
      // The list itself is fine; only the total is missing.
      if (request == _summaryRequest) _rangeSummary = null;
    }
  }

  Future<bool> create(Income income) async {
    return guard(() async {
      final Income created = await _repository.create(income);
      _items = <Income>[created, ..._items];
      _revision++;
      safeNotify();
      unawaited(_loadRangeSummary());
    });
  }

  Future<bool> update(Income income) async {
    return guard(() async {
      final Income updated = await _repository.update(income);
      _items =
          _items.map((Income i) => i.id == updated.id ? updated : i).toList();
      _revision++;
      safeNotify();
      unawaited(_loadRangeSummary());
    });
  }

  /// Saves the income form: creates [income] when it has no id yet,
  /// otherwise updates it — then, unless [tags] is null, makes them its
  /// complete set of tags.
  ///
  /// Returns whether the income itself was saved. The tags are a write of
  /// their own after it; if that fails the income stays saved and
  /// [saveWarning] says so, rather than reporting a failure that would
  /// invite a second save of the same income.
  Future<bool> save(Income income, {List<String>? tags}) async {
    _saveWarning = null;
    final bool isNew = income.id.isEmpty;
    Income? saved;
    final bool ok = await guard(() async {
      saved = isNew
          ? await _repository.create(income)
          : await _repository.update(income);
    });
    final Income? row = saved;
    if (!ok || row == null) return false;

    final TagRepository? tagWriter = _tags;
    if (tags != null && tagWriter != null && SchemaCapabilities.tags) {
      try {
        await tagWriter.setTags(kind: TagKind.income, id: row.id, names: tags);
      } catch (_) {
        _saveWarning = 'The income was saved, but its tags were not. '
            'Open it to try again.';
      }
    }

    _items = isNew
        ? <Income>[row, ..._items]
        : _items.map((Income i) => i.id == row.id ? row : i).toList();
    _revision++;
    safeNotify();
    unawaited(_loadRangeSummary());
    return true;
  }

  /// Every tag the user has and the names of those on [incomeId] (none for
  /// a new entry); null when tags are unavailable or could not be read, so
  /// the form neither shows nor changes them. Read-only, outside [guard].
  Future<({List<Tag> known, List<String> names})?> tagsFor({
    required String userId,
    String? incomeId,
  }) async {
    final TagRepository? tags = _tags;
    if (tags == null) return null;
    try {
      final ({List<Tag> known, List<String> names}) read =
          await tags.fetchForRow(
        userId: userId,
        kind: TagKind.income,
        id: incomeId,
      );
      // Resolved by the read: before migration 006 there is nothing to show.
      return SchemaCapabilities.tags ? read : null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> delete(Income income) async {
    final List<Income> snapshot = _items;
    _items = _items.where((Income i) => i.id != income.id).toList();
    safeNotify();

    final bool ok = await guard(() async {
      await _repository.delete(userId: income.userId, id: income.id);
      _revision++;
    });
    if (ok) unawaited(_loadRangeSummary());

    if (!ok) {
      _items = snapshot;
      safeNotify();
    }
    return ok;
  }

  void reset() {
    _items = <Income>[];
    _search = '';
    _userId = null;
    _from = null;
    _to = null;
    _rangeSummary = null;
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
