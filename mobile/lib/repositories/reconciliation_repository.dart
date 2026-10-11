import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/errors/app_exception.dart';
import '../services/schema_capabilities.dart';
import 'paging.dart';

/// `public.reconciliation_decisions` (migration 015, shared with the web app):
/// what the user decided while reconciling a statement — this statement row
/// IS that transaction (link), is NOT that transaction (separate), or the
/// discrepancy is accepted as it is (dismiss).
///
/// A decision never changes money: expenses, income, the ledger and balances
/// are only ever changed by the user, through the app's own screens. The same
/// reads and writes as the web app's `services/reconciliation.ts`.
///
/// Decisions travel in the engine's JSON shape:
/// `{scope: 'account:<id>' | 'card:<id>', itemKey, action, entryId, note}`.
class ReconciliationRepository {
  const ReconciliationRepository(this._client);

  final SupabaseClient _client;

  static const String _table = 'reconciliation_decisions';
  static const String _select =
      'id, scope_type, scope_id, item_key, action, entry_id, note';

  static ({String type, String id})? _scope(String key) {
    final int at = key.indexOf(':');
    if (at <= 0) return null;
    final String type = key.substring(0, at);
    if (type != 'account' && type != 'card') return null;
    return (type: type, id: key.substring(at + 1));
  }

  /// The user's decisions for [scopes]. Empty before migration 015.
  Future<List<Map<String, Object?>>> fetchDecisions({
    required String userId,
    required List<String> scopes,
  }) async {
    await SchemaCapabilities.resolve(_client);
    if (!SchemaCapabilities.reconciliation || scopes.isEmpty) {
      return const <Map<String, Object?>>[];
    }
    final List<String> ids = scopes
        .map(_scope)
        .whereType<({String type, String id})>()
        .map((({String type, String id}) s) => s.id)
        .toList();
    try {
      final List<Map<String, dynamic>> rows =
          await fetchAllPages(postgrestPages(() => _client
              .from(_table)
              .select(_select)
              .eq('user_id', userId)
              .inFilter('scope_id', ids)
              .order('id')));
      final Set<String> wanted = scopes.toSet();
      return <Map<String, Object?>>[
        for (final Map<String, dynamic> row in rows)
          if (wanted.contains('${row['scope_type']}:${row['scope_id']}'))
            <String, Object?>{
              'scope': '${row['scope_type']}:${row['scope_id']}',
              'itemKey': row['item_key'],
              'action': row['action'],
              'entryId': row['entry_id'],
              'note': row['note'],
            },
      ];
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// Stores [decision]. A link replaces any other link of the same statement
  /// row or the same transaction; "not the same" takes back a link between
  /// the two. Never touches a transaction.
  Future<void> saveDecision({
    required String userId,
    required Map<String, Object?> decision,
  }) async {
    final ({String type, String id})? scope = _scope(decision['scope']! as String);
    if (scope == null) return;
    final String itemKey = decision['itemKey']! as String;
    final String action = decision['action']! as String;
    final String? entryId = decision['entryId'] as String?;
    PostgrestFilterBuilder<dynamic> base() => _client
        .from(_table)
        .delete()
        .eq('user_id', userId)
        .eq('scope_type', scope.type)
        .eq('scope_id', scope.id);
    try {
      if (action == 'link' && entryId != null) {
        await base().eq('action', 'link').eq('item_key', itemKey);
        await base().eq('action', 'link').eq('entry_id', entryId);
        await base()
            .eq('action', 'separate')
            .eq('item_key', itemKey)
            .eq('entry_id', entryId);
      } else if (action == 'separate' && entryId != null) {
        await base().eq('item_key', itemKey).eq('entry_id', entryId);
      } else {
        await base().eq('action', 'dismiss').eq('item_key', itemKey);
      }
      final String? note = (decision['note'] as String?)?.trim();
      await _client.from(_table).insert(<String, dynamic>{
        'user_id': userId,
        'scope_type': scope.type,
        'scope_id': scope.id,
        'item_key': itemKey,
        'action': action,
        'entry_id': action == 'dismiss' ? null : entryId,
        'note': note == null || note.isEmpty
            ? null
            : note.substring(0, note.length > 500 ? 500 : note.length),
      });
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// Takes a decision back: the item is reconciled as if it had never been made.
  Future<void> removeDecision({
    required String userId,
    required Map<String, Object?> decision,
  }) async {
    final ({String type, String id})? scope = _scope(decision['scope']! as String);
    if (scope == null) return;
    final String? entryId = decision['entryId'] as String?;
    try {
      PostgrestFilterBuilder<dynamic> query = _client
          .from(_table)
          .delete()
          .eq('user_id', userId)
          .eq('scope_type', scope.type)
          .eq('scope_id', scope.id)
          .eq('item_key', decision['itemKey']! as String)
          .eq('action', decision['action']! as String);
      if (entryId != null) query = query.eq('entry_id', entryId);
      await query;
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }
}
