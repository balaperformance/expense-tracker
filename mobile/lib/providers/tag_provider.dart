import '../models/tag.dart';
import '../repositories/tag_repository.dart';
import 'async_state.dart';

/// A tag with the transactions that carry it.
typedef TagEntry = ({Tag tag, int uses});

/// The user's hashtags and where they are used, for the screen that deletes
/// them (migration 020).
///
/// Deleting a tag moves every expense and income row that had it to "Others"
/// in one database call, so nothing is ever left half-untagged.
class TagProvider extends AsyncProvider {
  TagProvider(this._repository);

  final TagRepository _repository;

  List<TagEntry> _entries = <TagEntry>[];
  String? _userId;

  List<TagEntry> get entries => List<TagEntry>.unmodifiable(_entries);

  @override
  bool get isEmptyData => _entries.isEmpty;

  Future<void> load({required String userId, bool force = false}) async {
    if (_userId != userId) {
      _userId = userId;
      _entries = <TagEntry>[];
    } else if (isReady && !force) {
      return;
    }
    if (_entries.isEmpty) setLoading();
    try {
      final List<Object> read = await Future.wait<Object>(<Future<Object>>[
        _repository.fetchTags(userId),
        _repository.fetchUsage(),
      ]);
      final Map<String, TagUsage> usage = read[1] as Map<String, TagUsage>;
      _entries = <TagEntry>[
        for (final Tag tag in read[0] as List<Tag>)
          (tag: tag, uses: usage[tag.id]?.total ?? 0),
      ];
      setReady();
    } catch (error) {
      setError(error);
    }
  }

  /// How many transactions carry [tag] right now — read afresh, so the
  /// confirmation never quotes a stale number; the listed figure when the
  /// read fails.
  Future<int> usesNow(TagEntry entry) async {
    try {
      return (await _repository.fetchUsage())[entry.tag.id]?.total ?? 0;
    } catch (_) {
      return entry.uses;
    }
  }

  /// Deletes [tag]; resolves to how many transactions moved to "Others", or
  /// null when it could not be deleted ([errorMessage] says why).
  Future<int?> delete(Tag tag) async {
    final String? userId = _userId;
    if (userId == null) return null;
    int? moved;
    final bool ok = await guard(() async {
      moved = await _repository.deleteTag(tag.id);
    });
    if (!ok) return null;
    // "Others" may be new, and every count has changed.
    await load(userId: userId, force: true);
    return moved;
  }

  void reset() {
    _entries = <TagEntry>[];
    _userId = null;
    safeNotify();
  }
}
