import 'package:supabase_flutter/supabase_flutter.dart';

/// Retries a request that failed for a transient, self-correcting reason.
///
/// The case this exists for is `PGRST303 — JWT issued at future`. A token is
/// stamped `iat = <now>` by the auth service, and if the first query reaches
/// PostgREST within that same second its clock can still read an instant
/// before `iat`, so a perfectly valid token is rejected. It happens most
/// often on the very first request after signing in, which is exactly when
/// the app bootstraps.
///
/// Waiting a moment and asking again resolves it, so the user never sees an
/// error for what is really a one-second race.
Future<T> retryOnTransientAuth<T>(
  Future<T> Function() action, {
  int attempts = 3,
  Duration step = const Duration(milliseconds: 700),
}) async {
  for (int attempt = 0;; attempt++) {
    try {
      return await action();
    } on PostgrestException catch (error) {
      final bool isClockSkew = error.code == 'PGRST303';
      if (!isClockSkew || attempt >= attempts - 1) rethrow;
      await Future<void>.delayed(step * (attempt + 1));
    }
  }
}
