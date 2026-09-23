import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/errors/app_exception.dart';
import '../models/bank_account.dart';
import '../services/schema_capabilities.dart';

class BankAccountRepository {
  const BankAccountRepository(this._client);

  final SupabaseClient _client;

  static const String _table = 'bank_accounts';

  /// Re-probes the schema.
  ///
  /// Capabilities are cached for the life of the process, so a migration
  /// applied while the app is running would otherwise stay invisible until a
  /// restart. Callers use this to let the feature appear as soon as the
  /// tables exist.
  Future<void> refreshCapabilities() =>
      SchemaCapabilities.resolve(_client, force: true);

  static const String _select =
      'id, user_id, bank_name, nickname, last4, opening_balance, '
      'is_active, created_at';

  Future<List<BankAccount>> fetchAll(String userId) async {
    try {
      final List<Map<String, dynamic>> rows = await _client
          .from(_table)
          .select(_select)
          .eq('user_id', userId)
          .order('created_at', ascending: true);

      return rows.map(BankAccount.fromMap).toList();
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// Derives every account balance from the ledger in two requests, rather
  /// than one aggregate query per account.
  ///
  /// The balance is never read from a stored column: it is
  /// `opening_balance + credits - debits` over the whole ledger history.
  Future<List<BankAccountBalance>> fetchWithBalances(String userId) async {
    try {
      final List<Object> results = await Future.wait(<Future<Object>>[
        fetchAll(userId),
        _client
            .from('account_transactions')
            .select('account_id, direction, amount')
            .eq('user_id', userId),
      ]);

      final List<BankAccount> accounts = results[0] as List<BankAccount>;
      final List<Map<String, dynamic>> movements =
          results[1] as List<Map<String, dynamic>>;

      final Map<String, double> credits = <String, double>{};
      final Map<String, double> debits = <String, double>{};

      for (final Map<String, dynamic> row in movements) {
        final String accountId = row['account_id'] as String;
        final double amount = (row['amount'] as num?)?.toDouble() ?? 0;
        if (row['direction'] == 'credit') {
          credits[accountId] = (credits[accountId] ?? 0) + amount;
        } else {
          debits[accountId] = (debits[accountId] ?? 0) + amount;
        }
      }

      return accounts
          .map((BankAccount account) => BankAccountBalance(
                account: account,
                totalCredits: credits[account.id] ?? 0,
                totalDebits: debits[account.id] ?? 0,
              ))
          .toList();
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  Future<BankAccount> create(BankAccount account) async {
    try {
      final Map<String, dynamic> row = await _client
          .from(_table)
          .insert(account.toInsertMap())
          .select(_select)
          .single();
      return BankAccount.fromMap(row);
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  Future<BankAccount> update(BankAccount account) async {
    try {
      final Map<String, dynamic> row = await _client
          .from(_table)
          .update(account.toUpdateMap())
          .eq('id', account.id)
          .eq('user_id', account.userId)
          .select(_select)
          .single();
      return BankAccount.fromMap(row);
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// Deletes an account.
  ///
  /// The database cascades its ledger rows away and nulls `bank_account_id`
  /// on any expense or income that referenced it, so those records survive
  /// and simply revert to Cash / untracked.
  Future<void> delete({required String userId, required String id}) async {
    try {
      await _client.from(_table).delete().eq('id', id).eq('user_id', userId);
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// How many movements an account holds, so the delete confirmation can
  /// state what will be removed.
  Future<int> movementCount({
    required String userId,
    required String accountId,
  }) async {
    try {
      final PostgrestResponse<List<Map<String, dynamic>>> response =
          await _client
              .from('account_transactions')
              .select('id')
              .eq('user_id', userId)
              .eq('account_id', accountId)
              .count(CountOption.exact);
      return response.count;
    } catch (_) {
      return 0;
    }
  }
}
