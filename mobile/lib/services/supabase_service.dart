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

  /// A session-less auth client on the implicit flow, used only to request a
  /// password-reset email.
  ///
  /// The main client uses PKCE, which ties the emailed link to a secret kept on
  /// this phone: the link would then only work if it came back into this app.
  /// The link opens the web app's reset page instead (there is no deep link),
  /// so it must carry the recovery session itself, which the implicit flow
  /// does. It never signs in, stores nothing and refreshes nothing.
  static GoTrueClient recoveryAuth() {
    final String key = EnvConfig.supabaseAnonKey;
    return GoTrueClient(
      url: '${EnvConfig.supabaseUrl}/auth/v1',
      headers: <String, String>{
        'apikey': key,
        'Authorization': 'Bearer $key',
      },
      autoRefreshToken: false,
      flowType: AuthFlowType.implicit,
    );
  }

  static String? get currentUserId => auth.currentUser?.id;
}
