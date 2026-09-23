import '../models/expense_category.dart';
import '../repositories/category_repository.dart';
import 'async_state.dart';

/// Categories are read constantly (every list row, every form) and change
/// rarely, so they are loaded once per session and kept in memory.
class CategoryProvider extends AsyncProvider {
  CategoryProvider(this._repository);

  final CategoryRepository _repository;

  List<ExpenseCategory> _categories = <ExpenseCategory>[];
  String? _userId;

  List<ExpenseCategory> get categories => List<ExpenseCategory>.unmodifiable(_categories);

  bool get isEmpty => _categories.isEmpty;

  @override
  bool get isEmptyData => _categories.isEmpty;

  ExpenseCategory? byId(String? id) {
    if (id == null) return null;
    for (final ExpenseCategory c in _categories) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// Loads categories, seeding the defaults on first use.
  Future<void> initialise(String userId) async {
    _userId = userId;
    setLoading();
    try {
      _categories = await _repository.ensureDefaults(userId);
      setReady();
    } catch (error) {
      setError(error);
    }
  }

  Future<void> refresh() async {
    final String? userId = _userId;
    if (userId == null) return;
    try {
      _categories = await _repository.fetchAll(userId);
      setReady();
    } catch (error) {
      setError(error);
    }
  }

  Future<bool> create({
    required String name,
    required String icon,
    required String color,
  }) async {
    final String? userId = _userId;
    if (userId == null) return false;

    return guard(() async {
      final ExpenseCategory created = await _repository.create(
        userId: userId,
        name: name,
        icon: icon,
        color: color,
      );
      _categories = <ExpenseCategory>[..._categories, created]..sort(_byName);
      safeNotify();
    });
  }

  Future<bool> update({
    required String id,
    required String name,
    required String icon,
    required String color,
  }) async {
    final String? userId = _userId;
    if (userId == null) return false;

    return guard(() async {
      final ExpenseCategory updated = await _repository.update(
        userId: userId,
        id: id,
        name: name,
        icon: icon,
        color: color,
      );
      _categories = _categories
          .map((ExpenseCategory c) => c.id == id ? updated : c)
          .toList()
        ..sort(_byName);
      safeNotify();
    });
  }

  Future<bool> delete(String id) async {
    final String? userId = _userId;
    if (userId == null) return false;

    return guard(() async {
      await _repository.delete(userId: userId, id: id);
      _categories =
          _categories.where((ExpenseCategory c) => c.id != id).toList();
      safeNotify();
    });
  }

  /// How many expenses would be detached by deleting this category, so the
  /// confirmation dialog can state the consequence.
  Future<int> usageCount(String categoryId) async {
    final String? userId = _userId;
    if (userId == null) return 0;
    try {
      return await _repository.countExpensesUsing(
        userId: userId,
        categoryId: categoryId,
      );
    } catch (_) {
      return 0;
    }
  }

  void reset() {
    _categories = <ExpenseCategory>[];
    _userId = null;
    safeNotify();
  }

  static int _byName(ExpenseCategory a, ExpenseCategory b) =>
      a.name.toLowerCase().compareTo(b.name.toLowerCase());
}
