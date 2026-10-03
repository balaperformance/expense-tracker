import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/constants/default_data.dart';
import '../core/errors/app_exception.dart';
import '../models/expense_category.dart';

class CategoryRepository {
  const CategoryRepository(this._client);

  final SupabaseClient _client;

  static const String _table = 'categories';

  Future<List<ExpenseCategory>> fetchAll(String userId) async {
    try {
      final List<Map<String, dynamic>> rows = await _client
          .from(_table)
          .select()
          .eq('user_id', userId)
          .order('name', ascending: true);

      return rows.map(ExpenseCategory.fromMap).toList();
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// Inserts any missing default categories and returns the full list.
  ///
  /// Comparison is case-insensitive on name, so re-running this (or a database
  /// trigger having seeded already) never produces duplicates.
  Future<List<ExpenseCategory>> ensureDefaults(String userId) async {
    try {
      final List<ExpenseCategory> existing = await fetchAll(userId);
      final Set<String> taken =
          existing.map((ExpenseCategory c) => c.name.toLowerCase()).toSet();

      final List<Map<String, dynamic>> missing = DefaultData.categories
          .where((DefaultCategory d) => !taken.contains(d.name.toLowerCase()))
          .map((DefaultCategory d) => <String, dynamic>{
                'user_id': userId,
                'name': d.name,
                'icon': d.icon,
                'color': d.color,
                'is_default': true,
              })
          .toList();

      if (missing.isEmpty) return existing;

      await _client.from(_table).insert(missing);
      return fetchAll(userId);
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// Rejects a duplicate name before hitting the database so the user gets a
  /// precise message instead of a constraint error.
  Future<ExpenseCategory> create({
    required String userId,
    required String name,
    required String icon,
    required String color,
  }) async {
    try {
      await _assertNameAvailable(userId: userId, name: name);

      final Map<String, dynamic> row = await _client
          .from(_table)
          .insert(<String, dynamic>{
            'user_id': userId,
            'name': name.trim(),
            'icon': icon,
            'color': color,
            'is_default': false,
          })
          .select()
          .single();

      return ExpenseCategory.fromMap(row);
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  Future<ExpenseCategory> update({
    required String userId,
    required String id,
    required String name,
    required String icon,
    required String color,
  }) async {
    try {
      await _assertNameAvailable(userId: userId, name: name, excludeId: id);

      final Map<String, dynamic> row = await _client
          .from(_table)
          .update(<String, dynamic>{
            'name': name.trim(),
            'icon': icon,
            'color': color,
          })
          .eq('id', id)
          .eq('user_id', userId)
          .select()
          .single();

      return ExpenseCategory.fromMap(row);
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// Deletes a category. Expenses referencing it are detached first so a
  /// foreign-key restriction cannot block the delete and orphan the UI.
  Future<void> delete({required String userId, required String id}) async {
    try {
      await _client
          .from('expenses')
          .update(<String, dynamic>{'category_id': null})
          .eq('category_id', id)
          .eq('user_id', userId);

      await _client.from(_table).delete().eq('id', id).eq('user_id', userId);
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  Future<int> countExpensesUsing({
    required String userId,
    required String categoryId,
  }) async {
    try {
      final PostgrestResponse<List<Map<String, dynamic>>> response =
          await _client
              .from('expenses')
              .select('id')
              .eq('user_id', userId)
              .eq('category_id', categoryId)
              .count(CountOption.exact);
      return response.count;
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  Future<void> _assertNameAvailable({
    required String userId,
    required String name,
    String? excludeId,
  }) async {
    final List<Map<String, dynamic>> matches = await _client
        .from(_table)
        .select('id, name')
        .eq('user_id', userId)
        .ilike('name', name.trim());

    final bool clash = matches.any(
      (Map<String, dynamic> row) => row['id'] != excludeId,
    );

    if (clash) {
      throw const AppException('A category with that name already exists.');
    }
  }
}
