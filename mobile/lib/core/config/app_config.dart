import 'package:flutter/foundation.dart';

/// Build-time switches.
///
/// ## Development authentication bypass
///
/// When [bypassAuth] is true the app skips the Login, Sign-up and
/// verify-email screens and opens straight on the Dashboard.
///
/// It does **not** remove authentication. Every table in this project is
/// protected by row-level security keyed on `auth.uid()`, so a request with no
/// session reads nothing and writes nothing. A bypass that simply skipped
/// sign-in would produce an empty, permanently broken Dashboard. Instead the
/// bypass acquires a real Supabase session automatically (see
/// `DevAuthBypass`), so RLS is still enforced and every Phase 1 CRUD path
/// behaves exactly as it does in production.
///
/// ### Turning it off
///
/// Two independent safeguards, either of which restores the normal login flow:
///
/// 1. Pass the define explicitly:
///    `flutter build apk --dart-define=BYPASS_AUTH=false`
/// 2. Build in release mode. [bypassAuth] is force-disabled whenever
///    `kReleaseMode` is set, so a production build can never ship the bypass
///    even if someone forgets the flag.
///
/// To make the normal flow the default again, change [_bypassAuthDefault] to
/// `false`. No other file needs editing — the authentication implementation
/// itself is untouched and fully intact.
class AppConfig {
  const AppConfig._();

  /// Default used when no `BYPASS_AUTH` define is supplied.
  ///
  /// Currently `true` for Phase 1 development convenience.
  static const bool _bypassAuthDefault = true;

  static const bool _bypassAuthDefine =
      bool.fromEnvironment('BYPASS_AUTH', defaultValue: _bypassAuthDefault);

  /// Whether to skip the authentication screens on launch.
  ///
  /// Always false in release builds, regardless of the define.
  static bool get bypassAuth => _bypassAuthDefine && !kReleaseMode;

  /// Optional `.env` keys holding a development account. When present they
  /// are preferred over an anonymous session because the data is stable
  /// across reinstalls.
  static const String devEmailKey = 'DEV_EMAIL';
  static const String devPasswordKey = 'DEV_PASSWORD';
}
