import 'tag.dart';

/// Tag naming rules, ported from the web app's `domain/tags.ts`.
///
/// A tag is a short label the user types once and reuses; names are unique
/// per user ignoring case, so typing "CarSpending" when "carspending" exists
/// picks the existing tag rather than adding another. The database applies
/// the same rules (migration 006, `set_transaction_tags`); these keep a
/// form's list honest before anything is saved.
class TagRules {
  const TagRules._();

  static const int maxLength = 40;
  static const int maxPerTransaction = 20;

  /// A typed tag as it is stored: no leading #, single spaces, trimmed.
  static String normalise(String raw) => raw
      .replaceFirst(RegExp(r'^\s*#+'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// What two spellings of the same tag have in common.
  static String key(String name) => normalise(name).toLowerCase();

  static String _clipped(String raw) {
    final String name = normalise(raw);
    return (name.length > maxLength ? name.substring(0, maxLength) : name)
        .trim();
  }

  /// [tags] with [raw] added. A name that matches an existing tag takes that
  /// tag's spelling; a repeat, a blank or anything past the limit changes
  /// nothing.
  static List<String> add(
    List<String> tags,
    String raw, [
    List<Tag> known = const <Tag>[],
  ]) {
    final String name = _clipped(raw);
    if (name.isEmpty || tags.length >= maxPerTransaction) {
      return List<String>.of(tags);
    }
    final String k = key(name);
    if (tags.any((String t) => key(t) == k)) return List<String>.of(tags);
    String spelling = name;
    for (final Tag tag in known) {
      if (key(tag.name) == k) {
        spelling = tag.name;
        break;
      }
    }
    return <String>[...tags, spelling];
  }

  static List<String> remove(List<String> tags, String name) {
    final String k = key(name);
    return tags.where((String t) => key(t) != k).toList();
  }

  /// Splits text containing commas into the finished tags before the last
  /// comma and what is still being typed.
  static ({List<String> done, String rest}) splitTyped(String text) {
    final List<String> pieces = text.split(',');
    final String rest = pieces.removeLast();
    return (
      done: pieces.map(normalise).where((String p) => p.isNotEmpty).toList(),
      rest: rest,
    );
  }

  /// Existing tags to offer: those not already chosen that contain what is
  /// typed, the ones that start with it first. Everything when nothing is
  /// typed.
  static List<Tag> suggestions(
    List<Tag> known,
    List<String> selected,
    String typed,
  ) {
    final String query = key(typed);
    final Set<String> chosen = selected.map(key).toSet();
    final List<Tag> open = known
        .where((Tag t) =>
            !chosen.contains(key(t.name)) &&
            (query.isEmpty || key(t.name).contains(query)))
        .toList();
    int rank(Tag t) => query.isNotEmpty && key(t.name).startsWith(query) ? 0 : 1;
    open.sort((Tag a, Tag b) {
      final int byRank = rank(a) - rank(b);
      return byRank != 0 ? byRank : a.name.compareTo(b.name);
    });
    return open;
  }

  /// The typed text as a brand-new tag, or null when it is blank, already
  /// chosen, or already exists.
  static String? newTagFor(
    List<Tag> known,
    List<String> selected,
    String typed,
  ) {
    final String name = _clipped(typed);
    if (name.isEmpty) return null;
    final String k = key(name);
    if (selected.any((String t) => key(t) == k) ||
        known.any((Tag t) => key(t.name) == k)) {
      return null;
    }
    return name;
  }

  /// The names of the tags with these ids, in the order of [ids]; ids that
  /// are not known are skipped.
  static List<String> names(List<Tag> known, List<String> ids) {
    final Map<String, String> byId = <String, String>{
      for (final Tag t in known) t.id: t.name,
    };
    return <String>[
      for (final String id in ids)
        if (byId[id] != null) byId[id]!,
    ];
  }
}
