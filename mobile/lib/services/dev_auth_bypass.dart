import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/config/app_config.dart';
import '../core/config/env_config.dart';

/// How a development session was obtained, for the on-screen DEV badge and
/// for reporting a useful message when none could be.
enum DevSessionSource {
  /// A session persisted from an earlier launch was reused.
  existingSession,

  /// Signed in with `DEV_EMAIL` / `DEV_PASSWORD` from `.env`.
  devCredentials,

  /// Supabase anonymous sign-in.
  anonymous,

  /// No session could be established.
  failed,
}

class DevSessionResult {
  const DevSessionResult(this.source, {this.message});

  final DevSessionSource source;

  /// Populated only when [source] is [DevSessionSource.failed].
  final String? message;

  bool get succeeded => source != DevSessionSource.failed;

  String get label => switch (source) {
        DevSessionSource.existingSession => 'restored session',
        DevSessionSource.devCredentials => 'DEV_EMAIL account',
        DevSessionSource.anonymous => 'anonymous session',
        DevSessionSource.failed => 'no session',
      };
}

/// Test-only handle on the URL scrubber, so its behaviour is pinned by a test
/// without widening the public surface of [DevAuthBypass].
@visibleForTesting
String debugSanitiseBypassError(String raw) => DevAuthBypass._sanitise(raw);

/// Records how the current development session was obtained, purely so the
/// on-screen DEV badge can say which rung of the ladder succeeded.
///
/// A plain static is adequate here: it is developer diagnostics, it is only
/// written from the bypass, and it never influences behaviour.
class DevSessionBadge {
  const DevSessionBadge._();

  static DevSessionResult? source;

  static void clear() => source = null;
}

/// Acquires a Supabase session without showing the authentication screens.
///
/// Development only — nothing calls this when [AppConfig.bypassAuth] is false,
/// and that getter is hard-disabled in release builds.
///
/// The production authentication code is used unchanged: this simply drives
/// `GoTrueClient` the same way the login screen would. RLS therefore stays
/// fully in force, which is what keeps Phase 1 CRUD working under the bypass.
class DevAuthBypass {
  const DevAuthBypass(this._auth);

  final GoTrueClient _auth;

  /// Tries each strategy in order of preference and returns the first that
  /// yields a session.
  ///
  /// Ordering rationale: a persisted session avoids a pointless network call;
  /// a real dev account keeps the same rows across reinstalls; an anonymous
  /// session is the last resort because each install creates a fresh, empty
  /// user.
  Future<DevSessionResult> ensureSession() async {
    if (_auth.currentSession != null) {
      return const DevSessionResult(DevSessionSource.existingSession);
    }

    final String? email = EnvConfig.optional(AppConfig.devEmailKey);
    final String? password = EnvConfig.optional(AppConfig.devPasswordKey);

    String? credentialFailure;
    if (email != null && password != null) {
      try {
        await _auth.signInWithPassword(email: email, password: password);
        if (_auth.currentSession != null) {
          return const DevSessionResult(DevSessionSource.devCredentials);
        }
      } on AuthException catch (error) {
        // Reported verbatim-ish but without echoing the password; the address
        // is the user's own development account.
        credentialFailure = 'DEV_EMAIL sign-in failed: ${error.message}';
      } catch (_) {
        credentialFailure = 'DEV_EMAIL sign-in failed: network error.';
      }
    }

    try {
      await _auth.signInAnonymously();
      if (_auth.currentSession != null) {
        return const DevSessionResult(DevSessionSource.anonymous);
      }
    } on AuthException catch (error) {
      return DevSessionResult(
        DevSessionSource.failed,
        message: _explain(credentialFailure, error.message),
      );
    } catch (_) {
      return DevSessionResult(
        DevSessionSource.failed,
        message: _explain(
          credentialFailure,
          'Could not reach Supabase. Check the device network connection.',
        ),
      );
    }

    return DevSessionResult(
      DevSessionSource.failed,
      message:
          _explain(credentialFailure, 'Anonymous sign-in returned no session.'),
    );
  }

  /// Strips URLs from a driver error before it reaches the screen.
  ///
  /// Transport failures arrive wrapped with the full request URI, which would
  /// put the project endpoint from `.env` on screen and into any screenshot.
  /// The endpoint tells the developer nothing they need here.
  static String _sanitise(String raw) {
    final String withoutUri =
        raw.replaceAll(RegExp(r',?\s*uri=\S+', caseSensitive: false), '');
    final String withoutUrls =
        withoutUri.replaceAll(RegExp(r'https?://\S+'), '[endpoint]');
    final String cleaned = withoutUrls.trim();
    return cleaned.isEmpty ? 'Request failed.' : cleaned;
  }

  /// Builds an actionable message naming both routes back to a session.
  static String _explain(String? credentialFailure, String anonymousFailure) {
    final StringBuffer buffer = StringBuffer();
    if (credentialFailure != null) {
      buffer.writeln(_sanitise(credentialFailure));
      buffer.writeln();
    }
    buffer.writeln(
        'Anonymous sign-in also failed: ${_sanitise(anonymousFailure)}');
    buffer.writeln();
    buffer.write(
      'Fix either one:\n'
      '  a) Enable Anonymous sign-ins in Supabase → Authentication → '
      'Sign In / Providers, or\n'
      '  b) Add DEV_EMAIL and DEV_PASSWORD for a confirmed account to .env '
      'and restart.\n\n'
      'You can also sign in normally below.',
    );
    return buffer.toString();
  }
}
