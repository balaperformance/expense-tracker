import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/errors/app_exception.dart';
import '../core/utils/date_utils.dart';
import '../models/budget.dart';

/// Reads and writes `public.budgets`.
///
/// `month` is stored as the first day of the month so lookups are an exact
/// date match rather than a range scan.
class BudgetRepository {
  const BudgetRepository(this._client);

  final SupabaseClient _client;

  static const String _table = 'budgets';
  static const String _select =
      'id, user_id, amount, category_id, month, created_at, categories(*)';

  Future<List<Budget>> fetchForMonth({
    required String userId,
    required DateTime month,
  }) async {
    try {
      final List<Map<String, dynamic>> rows = await _client
          .from(_table)
          .select(_select)
          .eq('user_id', userId)
          .eq('month', AppDateUtils.toDateString(AppDateUtils.firstDayOf(month)))
          .order('created_at', ascending: true);

      return rows.map(Budget.fromMap).toList();
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// The overall (category-less) budget for a month, or null if unset.
  Future<Budget?> fetchOverall({
    required String userId,
    required DateTime month,
  }) async {
    try {
      final Map<String, dynamic>? row = await _client
          .from(_table)
          .select(_select)
          .eq('user_id', userId)
          .eq('month', AppDateUtils.toDateString(AppDateUtils.firstDayOf(month)))
          .isFilter('category_id', null)
          .maybeSingle();

      return row == null ? null : Budget.fromMap(row);
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// Creates or replaces the budget for a (category, month) pair.
  ///
  /// Implemented as find-then-write rather than `upsert` because the table has
  /// no unique constraint to conflict on, and adding one would change the
  /// existing schema.
  Future<Budget> setBudget({
    required String userId,
    required String? categoryId,
    required DateTime month,
    required double amount,
  }) async {
    try {
      final String monthKey =
          AppDateUtils.toDateString(AppDateUtils.firstDayOf(month));

      PostgrestFilterBuilder<List<Map<String, dynamic>>> lookup = _client
          .from(_table)
          .select('id')
          .eq('user_id', userId)
          .eq('month', monthKey);

      lookup = categoryId == null
          ? lookup.isFilter('category_id', null)
          : lookup.eq('category_id', categoryId);

      final List<Map<String, dynamic>> existing = await lookup;

      if (existing.isNotEmpty) {
        final Map<String, dynamic> row = await _client
            .from(_table)
            .update(<String, dynamic>{'amount': amount})
            .eq('id', existing.first['id'] as String)
            .eq('user_id', userId)
            .select(_select)
            .single();
        return Budget.fromMap(row);
      }

      final Map<String, dynamic> row = await _client
          .from(_table)
          .insert(<String, dynamic>{
            'user_id': userId,
            'amount': amount,
            'month': monthKey,
            'category_id': categoryId,
          })
          .select(_select)
          .single();

      return Budget.fromMap(row);
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  Future<void> delete({required String userId, required String id}) async {
    try {
      await _client.from(_table).delete().eq('id', id).eq('user_id', userId);
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// Copies the previous month's budgets forward, skipping any that already
  /// exist for the target month.
  Future<int> copyFromPreviousMonth({
    required String userId,
    required DateTime targetMonth,
  }) async {
    try {
      final DateTime previous = AppDateUtils.addMonths(targetMonth, -1);
      final List<Budget> source =
          await fetchForMonth(userId: userId, month: previous);
      if (source.isEmpty) return 0;

      final List<Budget> target =
          await fetchForMonth(userId: userId, month: targetMonth);
      final Set<String?> taken =
          target.map((Budget b) => b.categoryId).toSet();

      final List<Map<String, dynamic>> rows = source
          .where((Budget b) => !taken.contains(b.categoryId))
          .map((Budget b) => <String, dynamic>{
                'user_id': userId,
                'amount': b.amount,
                'month': AppDateUtils.toDateString(
                  AppDateUtils.firstDayOf(targetMonth),
                ),
                'category_id': b.categoryId,
              })
          .toList();

      if (rows.isEmpty) return 0;
      await _client.from(_table).insert(rows);
      return rows.length;
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }
}
