import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/constants/app_constants.dart';
import '../core/errors/app_exception.dart';
import '../core/errors/retry.dart';
import '../models/profile.dart';

class ProfileRepository {
  const ProfileRepository(this._client);

  final SupabaseClient _client;

  static const String _table = 'profiles';

  /// Reads the signed-in user's profile, creating it if a database trigger
  /// has not already done so.
  ///
  /// Returns a transient in-memory profile if the row cannot be created (for
  /// example if RLS forbids the insert) so the app still renders rather than
  /// blocking the user at launch.
  Future<Profile> fetchOrCreate({
    required String userId,
    String? fallbackName,
  }) async {
    try {
      final Map<String, dynamic>? existing = await retryOnTransientAuth(
        () => _client.from(_table).select().eq('id', userId).maybeSingle(),
      );

      if (existing != null) return Profile.fromMap(existing);

      final Map<String, dynamic> inserted = await _client
          .from(_table)
          .insert(<String, dynamic>{
            'id': userId,
            'full_name': fallbackName,
            'currency': AppConstants.defaultCurrencyCode,
          })
          .select()
          .single();

      return Profile.fromMap(inserted);
    } on PostgrestException {
      return Profile(id: userId, fullName: fallbackName);
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  Future<Profile> update({
    required String userId,
    String? fullName,
    String? currency,
  }) async {
    try {
      final Map<String, dynamic> patch = <String, dynamic>{
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };
      if (fullName != null) patch['full_name'] = fullName.trim();
      if (currency != null) patch['currency'] = currency;

      final Map<String, dynamic> row = await _client
          .from(_table)
          .update(patch)
          .eq('id', userId)
          .select()
          .single();

      return Profile.fromMap(row);
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }
}
