import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/constants/app_constants.dart';
import '../core/errors/app_exception.dart';
import '../core/utils/date_utils.dart';
import '../models/income.dart';
import '../services/schema_capabilities.dart';
import 'ledger_repository.dart';

class IncomeRepository {
  IncomeRepository(this._client) : _ledger = LedgerRepository(_client);

  final SupabaseClient _client;

  /// Writes the credit that mirrors income paid into a tracked account.
  final LedgerRepository _ledger;

  static const String _table = 'income';

  static String get _select {
    final String bank =
        SchemaCapabilities.incomeBankLink ? ', bank_account_id' : '';
    return 'id, user_id, amount, source, income_date, description, '
        'created_at$bank';
  }

  Future<List<Income>> fetchPage({
    required String userId,
    required int page,
    String search = '',
    int pageSize = AppConstants.pageSize,
  }) async {
    try {
      PostgrestFilterBuilder<List<Map<String, dynamic>>> query =
          _client.from(_table).select(_select).eq('user_id', userId);

      final String term = search.trim().replaceAll(RegExp(r'[,()*%\\]'), '');
      if (term.isNotEmpty) {
        query = query.or('source.ilike.%$term%,description.ilike.%$term%');
      }

      final int from = page * pageSize;
      final List<Map<String, dynamic>> rows = await query
          .order('income_date', ascending: false)
          .order('created_at', ascending: false)
          .range(from, from + pageSize - 1);

      return rows.map(Income.fromMap).toList();
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  Future<List<Income>> fetchForMonth({
    required String userId,
    required DateTime month,
  }) async {
    try {
      final MonthRange range = AppDateUtils.monthRange(month);
      final List<Map<String, dynamic>> rows = await _client
          .from(_table)
          .select(_select)
          .eq('user_id', userId)
          .gte('income_date', AppDateUtils.toDateString(range.start))
          .lt('income_date', AppDateUtils.toDateString(range.endExclusive))
          .order('income_date', ascending: false)
          .limit(AppConstants.monthlyAggregateLimit);

      return rows.map(Income.fromMap).toList();
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// Every income entry in an arbitrary day range, oldest first.
  ///
  /// The export counterpart of [fetchForMonth], which stays untouched for the
  /// dashboard and reports.
  Future<List<Income>> fetchRange({
    required String userId,
    required DateTime from,
    required DateTime toExclusive,
    int limit = AppConstants.exportRowLimit,
  }) async {
    try {
      final List<Map<String, dynamic>> rows = await _client
          .from(_table)
          .select(_select)
          .eq('user_id', userId)
          .gte('income_date', AppDateUtils.toDateString(from))
          .lt('income_date', AppDateUtils.toDateString(toExclusive))
          .order('income_date', ascending: true)
          .order('created_at', ascending: true)
          .limit(limit);

      return rows.map(Income.fromMap).toList();
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  Future<Map<String, double>> fetchMonthlyTotals({
    required String userId,
    required DateTime from,
    required DateTime toExclusive,
  }) async {
    try {
      final List<Map<String, dynamic>> rows = await _client
          .from(_table)
          .select('amount, income_date')
          .eq('user_id', userId)
          .gte('income_date', AppDateUtils.toDateString(from))
          .lt('income_date', AppDateUtils.toDateString(toExclusive))
          .limit(AppConstants.monthlyAggregateLimit * 12);

      final Map<String, double> totals = <String, double>{};
      for (final Map<String, dynamic> row in rows) {
        final String bucket = (row['income_date'] as String).substring(0, 7);
        totals[bucket] =
            (totals[bucket] ?? 0) + ((row['amount'] as num?)?.toDouble() ?? 0);
      }
      return totals;
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  Future<Income> create(Income income) async {
    try {
      await SchemaCapabilities.resolve(_client);
      final Map<String, dynamic> row = await _client
          .from(_table)
          .insert(income.toInsertMap(
            includeBankLink: SchemaCapabilities.incomeBankLink,
          ))
          .select(_select)
          .single();

      final Income created = Income.fromMap(row);
      await _syncLedger(created);
      return created;
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  Future<Income> update(Income income) async {
    try {
      await SchemaCapabilities.resolve(_client);
      final Map<String, dynamic> row = await _client
          .from(_table)
          .update(income.toUpdateMap(
            includeBankLink: SchemaCapabilities.incomeBankLink,
          ))
          .eq('id', income.id)
          .eq('user_id', income.userId)
          .select(_select)
          .single();

      final Income updated = Income.fromMap(row);
      await _syncLedger(updated);
      return updated;
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// The matching ledger row is removed by `ON DELETE CASCADE`.
  Future<void> delete({required String userId, required String id}) async {
    try {
      await _client.from(_table).delete().eq('id', id).eq('user_id', userId);
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  Future<void> _syncLedger(Income income) async {
    if (!SchemaCapabilities.bankAccounts ||
        !SchemaCapabilities.incomeBankLink) {
      return;
    }
    await _ledger.syncForIncome(
      userId: income.userId,
      incomeId: income.id,
      accountId: income.bankAccountId,
      amount: income.amount,
      date: income.incomeDate,
      description: income.title,
    );
  }
}
