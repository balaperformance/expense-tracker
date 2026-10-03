import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/errors/app_exception.dart';

/// Which kind of row a tag set belongs to (`expense_tags` / `income_tags`).
enum TagKind { expense, income }

extension TagKindWire on TagKind {
  String get wire => this == TagKind.expense ? 'expense' : 'income';
}

/// Writes tags (migration 006, shared with the web app).
///
/// The only write is `set_transaction_tags`, which finds or creates each named
/// tag — reusing an existing one whatever its case, with its own spelling —
/// and makes the row's links exactly that set, in one database transaction.
/// So an imported tag is never created twice, and a failure leaves the row's
/// tags as they were.
class TagRepository {
  const TagRepository(this._client);

  final SupabaseClient _client;

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
