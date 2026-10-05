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
