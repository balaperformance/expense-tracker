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

  /// The tags the user reaches for most, in the order they are always shown
  /// (compared by [key]). Every other tag follows, alphabetically. The web
  /// app's `TAG_PRIORITY`.
  static const List<String> priority = <String>[
    'famspendings',
    'myownspendings',
    'groceries',
    'famfood',
    'food',
    'famsavings',
    'fuel',
  ];

  static int _rank(String name) {
    final int at = priority.indexOf(key(name));
    return at < 0 ? priority.length : at;
  }

  /// Orders two tag names: the priority tags first, in [priority] order, then
  /// the rest alphabetically ignoring case.
  static int compareNames(String a, String b) {
    final int byRank = _rank(a) - _rank(b);
    if (byRank != 0) return byRank;
    final int byName = a.toLowerCase().compareTo(b.toLowerCase());
    return byName != 0 ? byName : a.compareTo(b);
  }

  /// [items] ordered by [compareNames] of [nameOf], as a new list; items
  /// that compare equal keep their order. For anything that carries a tag
  /// name — a filter option, a count — and must be listed like the tags are.
  static List<T> sortedBy<T>(Iterable<T> items, String Function(T) nameOf) {
    int at = 0;
    final List<(int, T)> indexed = <(int, T)>[
      for (final T item in items) (at++, item),
    ];
    indexed.sort(((int, T) a, (int, T) b) {
      final int byName = compareNames(nameOf(a.$2), nameOf(b.$2));
      return byName != 0 ? byName : a.$1 - b.$1;
    });
    return <T>[for (final (int, T) e in indexed) e.$2];
  }

  /// [tags] in display order: priority tags first, then alphabetical.
  static List<Tag> sortTags(Iterable<Tag> tags) =>
      sortedBy<Tag>(tags, (Tag t) => t.name);

  /// [names] in display order: priority tags first, then alphabetical.
  static List<String> sortNames(Iterable<String> names) =>
      sortedBy<String>(names, (String n) => n);

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

  /// [known] and the names in [extra] — tags typed on rows that are not
  /// saved yet — as one list for a tag field to offer, in display order
  /// ([sortTags]). A name
  /// matching a known tag (ignoring case) adds nothing, so the saved spelling
  /// wins; the first spelling of an unsaved name wins over its repeats.
  /// Unsaved tags get the id `session:<key>`.
  static List<Tag> merge(List<Tag> known, Iterable<String> extra) {
    final Map<String, Tag> byKey = <String, Tag>{
      for (final Tag tag in known) key(tag.name): tag,
    };
    for (final String raw in extra) {
      final String name = _clipped(raw);
      if (name.isEmpty) continue;
      byKey.putIfAbsent(
          key(name), () => Tag(id: 'session:${key(name)}', name: name));
    }
    return sortTags(byKey.values);
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
  /// typed, the ones that start with it first, then in display order
  /// ([sortTags]). Everything, in display order, when nothing is typed.
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
    final List<Tag> ordered = sortTags(open);
    // A stable split keeps the display order inside each group.
    return <Tag>[
      ...ordered.where((Tag t) => rank(t) == 0),
      ...ordered.where((Tag t) => rank(t) != 0),
    ];
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

  /// The names of the tags with these ids, in display order ([sortNames]);
  /// ids that are not known are skipped.
  static List<String> names(List<Tag> known, List<String> ids) {
    final Map<String, String> byId = <String, String>{
      for (final Tag t in known) t.id: t.name,
    };
    return sortNames(<String>[
      for (final String id in ids)
        if (byId[id] != null) byId[id]!,
    ]);
  }
}
