import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/errors/app_exception.dart';
import '../models/tag.dart';
import '../models/tag_rules.dart';
import '../services/schema_capabilities.dart';
import 'paging.dart';

/// Which kind of row a tag set belongs to (`expense_tags` / `income_tags`).
enum TagKind { expense, income }

extension TagKindWire on TagKind {
  String get wire => this == TagKind.expense ? 'expense' : 'income';
}

/// Reads and writes tags (migration 006, shared with the web app).
///
/// The only write is `set_transaction_tags`, which finds or creates each named
/// tag — reusing an existing one whatever its case, with its own spelling —
/// and makes the row's links exactly that set, in one database transaction.
/// So an imported tag is never created twice, and a failure leaves the row's
/// tags as they were.
class TagRepository {
  const TagRepository(this._client);

  final SupabaseClient _client;

  /// The user's tags in display order ([TagRules.sortTags]); empty before
  /// migration 006.
  Future<List<Tag>> fetchTags(String userId) async {
    await SchemaCapabilities.resolve(_client);
    if (!SchemaCapabilities.tags) return const <Tag>[];
    try {
      final List<Map<String, dynamic>> rows =
          await fetchAllPages(postgrestPages(() => _client
              .from('tags')
              .select('id, name')
              .eq('user_id', userId)
              .order('name')
              .order('id')));
      return TagRules.sortTags(rows.map(Tag.fromMap));
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// Every expense's tags, as expense id → tag ids.
  Future<Map<String, List<String>>> fetchExpenseTagLinks(String userId) async {
    await SchemaCapabilities.resolve(_client);
    if (!SchemaCapabilities.tags) return const <String, List<String>>{};
    try {
      final List<Map<String, dynamic>> rows =
          await fetchAllPages(postgrestPages(() => _client
              .from('expense_tags')
              .select('expense_id, tag_id')
              .eq('user_id', userId)
              .order('expense_id')
              .order('tag_id')));
      final Map<String, List<String>> links = <String, List<String>>{};
      for (final Map<String, dynamic> row in rows) {
        (links[row['expense_id'] as String] ??= <String>[])
            .add(row['tag_id'] as String);
      }
      return links;
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// The ids of the tags on one expense or income row, in the order they
  /// were added; empty before migration 006.
  Future<List<String>> fetchTagIdsFor({
    required String userId,
    required TagKind kind,
    required String id,
  }) async {
    await SchemaCapabilities.resolve(_client);
    if (!SchemaCapabilities.tags) return const <String>[];
    final String table =
        kind == TagKind.expense ? 'expense_tags' : 'income_tags';
    final String column = kind == TagKind.expense ? 'expense_id' : 'income_id';
    try {
      final List<Map<String, dynamic>> rows = await _client
          .from(table)
          .select('tag_id, created_at')
          .eq('user_id', userId)
          .eq(column, id)
          .order('created_at')
          .order('tag_id');
      return rows.map((Map<String, dynamic> r) => r['tag_id'] as String).toList();
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// What a form's tag field needs: every tag the user has (offered as
  /// suggestions), and the names of those already on row [id] — none for a
  /// new row.
  Future<({List<Tag> known, List<String> names})> fetchForRow({
    required String userId,
    required TagKind kind,
    String? id,
  }) async {
    // Future.wait rethrows the first failure as it is, so the caller sees the
    // database's own message.
    final List<Object> read = await Future.wait<Object>(<Future<Object>>[
      fetchTags(userId),
      if (id != null) fetchTagIdsFor(userId: userId, kind: kind, id: id),
    ]);
    final List<Tag> known = read.first as List<Tag>;
    final List<String> ids =
        read.length > 1 ? read[1] as List<String> : const <String>[];
    return (known: known, names: TagRules.names(known, ids));
  }

  /// How many expenses and income rows use each tag, by tag id (migration
  /// 020); a tag nothing uses is simply absent.
  Future<Map<String, TagUsage>> fetchUsage() async {
    await _requireDelete();
    try {
      final List<dynamic> rows =
          await _client.rpc<List<dynamic>>('tag_usage');
      return <String, TagUsage>{
        for (final Map<String, dynamic> row in rows.cast<Map<String, dynamic>>())
          row['tag_id'] as String: TagUsage.fromMap(row),
      };
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// Deletes the tag. Every expense and income row that had it moves to the
  /// tag "Others" in the same transaction; returns how many moved
  /// (migration 020).
  Future<int> deleteTag(String id) async {
    await _requireDelete();
    try {
      final Object? moved = await _client
          .rpc<Object?>('delete_tag', params: <String, dynamic>{'p_tag': id});
      return (moved as num?)?.toInt() ?? 0;
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  Future<void> _requireDelete() async {
    await SchemaCapabilities.resolve(_client);
    if (!SchemaCapabilities.tagDelete) {
      throw const AppException(
        'Run ui/supabase/020_emi_bank_accounts_and_tag_delete.sql, then try '
        'again.',
      );
    }
  }

  /// Makes [names] the complete set of tags on the expense or income row [id].
  Future<void> setTags({
    required TagKind kind,
    required String id,
    required List<String> names,
  }) async {
    try {
      await _client.rpc<void>(
        'set_transaction_tags',
        params: <String, dynamic>{
          'p_kind': kind.wire,
          'p_id': id,
          'p_names': names,
        },
      );
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }
}
