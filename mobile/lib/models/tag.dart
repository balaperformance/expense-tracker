/// Row of `public.tags` (migration 006, shared with the web app): a label the
/// user puts on expenses and income — "#family", "#carspending".
class Tag {
  const Tag({required this.id, required this.name});

  final String id;
  final String name;

  factory Tag.fromMap(Map<String, dynamic> map) => Tag(
        id: map['id'] as String,
        name: (map['name'] as String?) ?? '',
      );
}

/// How many expenses and income rows carry a tag: a row of the database's
/// `tag_usage()` (migration 020).
class TagUsage {
  const TagUsage({
    required this.tagId,
    this.expenses = 0,
    this.income = 0,
  });

  final String tagId;
  final int expenses;
  final int income;

  /// Transactions that would lose the tag if it were deleted.
  int get total => expenses + income;

  factory TagUsage.fromMap(Map<String, dynamic> map) => TagUsage(
        tagId: map['tag_id'] as String,
        expenses: (map['expense_count'] as num?)?.toInt() ?? 0,
        income: (map['income_count'] as num?)?.toInt() ?? 0,
      );
}
