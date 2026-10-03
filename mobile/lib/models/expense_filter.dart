/// Query parameters for the expenses list.
///
/// Immutable so the provider can compare old and new filters and skip
/// redundant network calls.
enum ExpenseSort { newestFirst, oldestFirst, highestAmount, lowestAmount }

extension ExpenseSortLabel on ExpenseSort {
  String get label => switch (this) {
        ExpenseSort.newestFirst => 'Newest first',
        ExpenseSort.oldestFirst => 'Oldest first',
        ExpenseSort.highestAmount => 'Highest amount',
        ExpenseSort.lowestAmount => 'Lowest amount',
      };

  String get column => switch (this) {
        ExpenseSort.newestFirst || ExpenseSort.oldestFirst => 'expense_date',
        ExpenseSort.highestAmount || ExpenseSort.lowestAmount => 'amount',
      };

  bool get ascending => switch (this) {
        ExpenseSort.oldestFirst || ExpenseSort.lowestAmount => true,
        ExpenseSort.newestFirst || ExpenseSort.highestAmount => false,
      };
}

class ExpenseFilter {
  const ExpenseFilter({
    this.search = '',
    this.categoryIds = const <String>{},
    this.paymentMethodIds = const <String>{},
    this.from,
    this.to,
    this.sort = ExpenseSort.newestFirst,
  });

  final String search;
  final Set<String> categoryIds;
  final Set<String> paymentMethodIds;
  final DateTime? from;
  final DateTime? to;
  final ExpenseSort sort;

  /// Number of active constraints, shown as a badge on the filter button.
  int get activeCount {
    int count = 0;
    if (categoryIds.isNotEmpty) count++;
    if (paymentMethodIds.isNotEmpty) count++;
    if (from != null || to != null) count++;
    return count;
  }

  bool get hasAnyFilter => activeCount > 0 || search.trim().isNotEmpty;

  ExpenseFilter copyWith({
    String? search,
    Set<String>? categoryIds,
    Set<String>? paymentMethodIds,
    DateTime? from,
    DateTime? to,
    ExpenseSort? sort,
    bool clearFrom = false,
    bool clearTo = false,
  }) {
    return ExpenseFilter(
      search: search ?? this.search,
      categoryIds: categoryIds ?? this.categoryIds,
      paymentMethodIds: paymentMethodIds ?? this.paymentMethodIds,
      from: clearFrom ? null : (from ?? this.from),
      to: clearTo ? null : (to ?? this.to),
      sort: sort ?? this.sort,
    );
  }

  ExpenseFilter cleared() => ExpenseFilter(search: search, sort: sort);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ExpenseFilter &&
        other.search == search &&
        other.sort == sort &&
        other.from == from &&
        other.to == to &&
        _setEquals(other.categoryIds, categoryIds) &&
        _setEquals(other.paymentMethodIds, paymentMethodIds);
  }

  @override
  int get hashCode => Object.hash(
        search,
        sort,
        from,
        to,
        Object.hashAllUnordered(categoryIds),
        Object.hashAllUnordered(paymentMethodIds),
      );

  static bool _setEquals(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);
}
