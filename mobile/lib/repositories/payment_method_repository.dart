import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/constants/default_data.dart';
import '../core/errors/app_exception.dart';
import '../models/payment_method.dart';

class PaymentMethodRepository {
  const PaymentMethodRepository(this._client);

  final SupabaseClient _client;

  static const String _table = 'payment_methods';

  Future<List<PaymentMethod>> fetchAll(String userId) async {
    try {
      final List<Map<String, dynamic>> rows = await _client
          .from(_table)
          .select()
          .eq('user_id', userId)
          .order('name', ascending: true);

      return rows.map(PaymentMethod.fromMap).toList();
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// Same idempotent seeding contract as categories.
  Future<List<PaymentMethod>> ensureDefaults(String userId) async {
    try {
      final List<PaymentMethod> existing = await fetchAll(userId);
      final Set<String> taken =
          existing.map((PaymentMethod m) => m.name.toLowerCase()).toSet();

      final List<Map<String, dynamic>> missing = DefaultData.paymentMethods
          .where((String name) => !taken.contains(name.toLowerCase()))
          .map((String name) => <String, dynamic>{
                'user_id': userId,
                'name': name,
              })
          .toList();

      if (missing.isEmpty) return existing;

      await _client.from(_table).insert(missing);
      return fetchAll(userId);
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  Future<PaymentMethod> create({
    required String userId,
    required String name,
  }) async {
    try {
      final List<Map<String, dynamic>> clash = await _client
          .from(_table)
          .select('id')
          .eq('user_id', userId)
          .ilike('name', name.trim());

      if (clash.isNotEmpty) {
        throw const AppException(
          'That payment method already exists.',
        );
      }

      final Map<String, dynamic> row = await _client
          .from(_table)
          .insert(<String, dynamic>{'user_id': userId, 'name': name.trim()})
          .select()
          .single();

      return PaymentMethod.fromMap(row);
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  Future<void> delete({required String userId, required String id}) async {
    try {
      await _client
          .from('expenses')
          .update(<String, dynamic>{'payment_method_id': null})
          .eq('payment_method_id', id)
          .eq('user_id', userId);

      await _client.from(_table).delete().eq('id', id).eq('user_id', userId);
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }
}
