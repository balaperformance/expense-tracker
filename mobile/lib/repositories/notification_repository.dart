import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/errors/app_exception.dart';
import '../models/notification_prefs.dart';

/// Push notifications in the database: the four switches
/// (`notification_preferences`, migration 008, shared with the web app) and
/// this phone's FCM token (`mobile_push_tokens`, migration 009).
///
/// The server does everything else — the `push-notify` Edge Function works
/// out each user's 10 PM, sums their spending with the app's own rules and
/// sends to every device they have.
class NotificationRepository {
  const NotificationRepository(this._client);

  final SupabaseClient _client;

  static const String _prefs = 'notification_preferences';
  static const String _tokens = 'mobile_push_tokens';

  Future<NotificationPrefs> fetchPrefs(String userId) async {
    try {
      final Map<String, dynamic>? row = await _client
          .from(_prefs)
          .select('daily_reminder, spending_summary, low_balance, card_due')
          .eq('user_id', userId)
          .maybeSingle();
      return NotificationPrefs.fromMap(row);
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// One switch, for every device of the user's. A first save creates the row.
  Future<void> savePref(String userId, NotificationPref pref, bool value) async {
    try {
      await _client.from(_prefs).upsert(
        <String, dynamic>{
          'user_id': userId,
          pref.column: value,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        onConflict: 'user_id',
      );
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// Tells the server this phone can receive the signed-in user's
  /// notifications, and in which time zone. A token that belonged to another
  /// account on this phone moves to this one.
  Future<void> registerToken({
    required String token,
    required String timezone,
    String? appVersion,
    String? device,
  }) async {
    try {
      await _client.rpc<void>(
        'register_mobile_push_token',
        params: <String, dynamic>{
          'p_token': token,
          'p_platform': 'android',
          'p_timezone': timezone,
          'p_app_version': appVersion,
          'p_device': device,
        },
      );
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// Removes this phone's token while the user is still signed in.
  Future<void> unregisterToken({required String userId, required String token}) async {
    try {
      await _client
          .from(_tokens)
          .delete()
          .eq('user_id', userId)
          .eq('token', token);
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }
}
