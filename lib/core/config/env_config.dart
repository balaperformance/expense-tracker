/// Reads and validates runtime configuration from the bundled `.env` asset.
///
/// Values are never logged or printed. Callers get a clear, non-sensitive
/// error when configuration is missing so start-up failures are diagnosable
/// without leaking credentials.
library;

import 'package:flutter_dotenv/flutter_dotenv.dart';

class EnvConfig {
  const EnvConfig._();

  static const String _urlKey = 'SUPABASE_URL';
  static const String _anonKey = 'SUPABASE_ANON_KEY';

  static String get supabaseUrl => _require(_urlKey);

  static String get supabaseAnonKey => _require(_anonKey);

  /// Loads the `.env` asset. Must be called before [supabaseUrl] is read.
  static Future<void> load() => dotenv.load(fileName: '.env');

  /// Reads an optional key, returning null when absent or blank.
  ///
  /// Used for development-only settings that must not make start-up fail when
  /// they are missing.
  static String? optional(String key) {
    final String? value = dotenv.env[key];
    if (value == null || value.trim().isEmpty) return null;
    return value.trim();
  }

  static String _require(String key) {
    final value = dotenv.env[key];
    if (value == null || value.trim().isEmpty) {
      throw StateError(
        'Missing "$key" in .env. Add it to the project root .env file. '
        'The value itself is never logged.',
      );
    }
    return value.trim();
  }
}
