import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/errors/app_exception.dart';
import '../models/notification_item.dart';
import '../models/notification_prefs.dart';
import '../services/schema_capabilities.dart';

/// Push notifications in the database: the four switches
/// (`notification_preferences`, migration 008, shared with the web app),
/// this phone's FCM token (`mobile_push_tokens`, migration 009) and the
/// in-app history (`notification_log`, migrations 010 and 012).
///
/// The server does everything else — the `push-notify` Edge Function works
/// out each user's 10 PM, sums their spending with the app's own rules and
/// sends to every device they have.
class NotificationRepository {
  const NotificationRepository(this._client);

  final SupabaseClient _client;

  static const String _prefs = 'notification_preferences';
  static const String _tokens = 'mobile_push_tokens';
  static const String _log = 'notification_log';

  /// Enough for a long history on one screen; the sender prunes rows after
  /// 120 days. The web app's limit.
  static const int inboxLimit = 100;

  // ---- The in-app history ---------------------------------------------------
  //
  // The sender writes the rows; the app only reads its own, marks them read
  // and — with migration 012 — clears read ones from the list. RLS and a
  // column grant on read_at and cleared_at allow nothing more; rows are never
  // deleted, because the sender's de-duplication relies on them.

  /// The user's notifications, newest first.
  Future<List<NotificationItem>> fetchInbox(String userId) async {
    try {
      PostgrestFilterBuilder<List<Map<String, dynamic>>> query = _client
          .from(_log)
          .select('event_key, kind, sent_at, title, body, url, read_at')
          .eq('user_id', userId);
      // Cleared notifications stay in the table for the sender; the list
      // leaves them out.
      if (SchemaCapabilities.notificationClear) {
        query = query.isFilter('cleared_at', null);
      }
      final List<Map<String, dynamic>> rows = await query
          .order('sent_at', ascending: false)
          .limit(inboxLimit);
      return NotificationItem.fromRows(rows);
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  // Each update returns the rows it changed, so an update the database
  // quietly refused is not mistaken for success.

  /// Marks one notification read; returns how many changed (0 when it was
  /// already read, e.g. on another device).
  Future<int> markInboxRead(String userId, String key) async {
    try {
      final List<Map<String, dynamic>> rows = await _client
          .from(_log)
          .update(<String, dynamic>{'read_at': _now()})
          .eq('user_id', userId)
          .eq('event_key', key)
          .isFilter('read_at', null)
          .select('event_key');
      return rows.length;
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// Marks every unread notification read; returns how many changed.
  Future<int> markAllInboxRead(String userId) async {
    try {
      final List<Map<String, dynamic>> rows = await _client
          .from(_log)
          .update(<String, dynamic>{'read_at': _now()})
          .eq('user_id', userId)
          .isFilter('read_at', null)
          .select('event_key');
      return rows.length;
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// Clears read notifications from the list (migration 012); returns how
  /// many changed. Unread ones are never touched — and the database refuses
  /// to clear them.
  Future<int> clearReadInbox(String userId) async {
    try {
      final List<Map<String, dynamic>> rows = await _client
          .from(_log)
          .update(<String, dynamic>{'cleared_at': _now()})
          .eq('user_id', userId)
          .not('read_at', 'is', null)
          .isFilter('cleared_at', null)
          .select('event_key');
      return rows.length;
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  static String _now() => DateTime.now().toUtc().toIso8601String();

  // ---- Switches and this phone's token -------------------------------------

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
