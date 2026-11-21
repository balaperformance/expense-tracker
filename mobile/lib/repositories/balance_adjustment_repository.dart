import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/errors/app_exception.dart';
import '../core/utils/date_utils.dart';
import '../models/balance_adjustment.dart';
import '../services/schema_capabilities.dart';

/// `public.balance_adjustments` (migration 021, shared with the web app).
///
/// An adjustment is made through `adjust_account_balance`, which records the
/// app's balance at that point and lets the database write the ledger row for
/// the difference; removing one deletes the row, and its ledger row and the
/// rest of the account's adjustments follow in the same database
/// transaction. The app never writes the ledger row itself.
class BalanceAdjustmentRepository {
  const BalanceAdjustmentRepository(this._client);

  final SupabaseClient _client;

  static const String _table = 'balance_adjustments';
  static const String _select =
      'id, account_id, adjusted_on, adjusted_at, target_balance, previous_balance, remarks';

  /// The account's adjustments, newest first; empty before migration 021.
  Future<List<BalanceAdjustment>> fetchForAccount({
    required String userId,
    required String accountId,
  }) async {
    if (!SchemaCapabilities.balanceAdjustments) return const <BalanceAdjustment>[];
    try {
      final List<Map<String, dynamic>> rows = await _client
          .from(_table)
          .select(_select)
          .eq('user_id', userId)
          .eq('account_id', accountId)
          .order('adjusted_on', ascending: false)
          .order('adjusted_at', ascending: false);
      return rows.map(BalanceAdjustment.fromMap).toList();
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// Sets the account's balance on [date] to [balance]. Returns the
  /// adjustment's id.
  Future<String> adjust({
    required String accountId,
    required double balance,
    required DateTime date,
    String? remarks,
  }) async {
    try {
      final Object? id = await _client.rpc<Object?>(
        'adjust_account_balance',
        params: <String, dynamic>{
          'p_account': accountId,
          'p_balance': balance,
          'p_date': AppDateUtils.toDateString(date),
          'p_remarks': remarks == null || remarks.trim().isEmpty ? null : remarks.trim(),
        },
      );
      return id?.toString() ?? '';
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// Removes an adjustment. The balance goes back to what the recorded
  /// movements add up to (or to the adjustment before it).
  Future<void> remove({required String userId, required String id}) async {
    try {
      await _client.from(_table).delete().eq('id', id).eq('user_id', userId);
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }
}
