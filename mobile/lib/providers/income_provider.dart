import 'dart:async';

import '../core/constants/app_constants.dart';
import '../models/income.dart';
import '../repositories/income_repository.dart';
import 'async_state.dart';

class IncomeProvider extends AsyncProvider {
  IncomeProvider(this._repository);

  final IncomeRepository _repository;

  static const Duration _searchDebounce = Duration(milliseconds: 350);

  List<Income> _items = <Income>[];
  String _search = '';
  String? _userId;

  int _page = 0;
  bool _hasMore = true;
  bool _loadingMore = false;
  Timer? _debounce;
  int _revision = 0;

  List<Income> get items => List<Income>.unmodifiable(_items);
  String get search => _search;
  bool get hasMore => _hasMore;
  bool get loadingMore => _loadingMore;
  int get revision => _revision;

  @override
  bool get isEmptyData => _items.isEmpty;

  bool get showEmptyState => isReady && _items.isEmpty && _search.isEmpty;
  bool get showNoResults => isReady && _items.isEmpty && _search.isNotEmpty;

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
      );
      _items = rows;
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
      final List<Income> rows = await _repository.fetchPage(
        userId: userId,
        page: _page + 1,
        search: _search,
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

  Future<bool> create(Income income) async {
    return guard(() async {
      final Income created = await _repository.create(income);
      _items = <Income>[created, ..._items];
      _revision++;
      safeNotify();
    });
  }

  Future<bool> update(Income income) async {
    return guard(() async {
      final Income updated = await _repository.update(income);
      _items =
          _items.map((Income i) => i.id == updated.id ? updated : i).toList();
      _revision++;
      safeNotify();
    });
  }

  Future<bool> delete(Income income) async {
    final List<Income> snapshot = _items;
    _items = _items.where((Income i) => i.id != income.id).toList();
    safeNotify();

    final bool ok = await guard(() async {
      await _repository.delete(userId: income.userId, id: income.id);
      _revision++;
    });

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
