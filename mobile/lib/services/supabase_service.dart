import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/config/env_config.dart';

/// Owns Supabase initialisation and is the single place the rest of the app
/// reaches the client.
///
/// Repositories take a [SupabaseClient] by constructor injection rather than
/// reaching for the singleton, so they stay unit-testable and no widget ever
/// talks to Supabase directly.
class SupabaseService {
  const SupabaseService._();

  static Future<void> initialize() async {
    await Supabase.initialize(
      url: EnvConfig.supabaseUrl,
      // The project uses a modern `sb_publishable_...` key. `publishableKey`
      // is the non-deprecated parameter for it; `anonKey` is the legacy name.
      publishableKey: EnvConfig.supabaseAnonKey,
      authOptions: const FlutterAuthClientOptions(
        // Sessions are persisted to secure local storage so the user stays
        // signed in across app restarts.
        autoRefreshToken: true,
      ),
    );
  }

  static SupabaseClient get client => Supabase.instance.client;

  static GoTrueClient get auth => Supabase.instance.client.auth;

  static String? get currentUserId => auth.currentUser?.id;

  /// Throws when a repository is used without a session. Guards against
  /// writing rows with a null `user_id`, which RLS would reject anyway.
  static String get requireUserId {
    final String? id = currentUserId;
    if (id == null) {
      throw StateError('You are signed out. Please sign in again.');
    }
    return id;
  }
}
