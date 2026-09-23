import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/errors/app_exception.dart';
import '../repositories/auth_repository.dart';
import 'async_state.dart';

enum AuthStage {
  /// Restoring a persisted session at launch.
  initialising,
  signedOut,
  signedIn,
}

/// Owns authentication state and exposes it to the widget tree.
///
/// The Supabase SDK persists and refreshes the session itself; this provider
/// mirrors that stream so the UI has a single synchronous source of truth.
class AuthProvider extends AsyncProvider {
  AuthProvider(this._repository) {
    _bind();
  }

  final AuthRepository _repository;
  StreamSubscription<AuthState>? _subscription;

  AuthStage _stage = AuthStage.initialising;
  User? _user;

  /// Set after a sign-up that requires confirmation, so the UI can route to
  /// the verify-email screen and offer a resend.
  String? _pendingConfirmationEmail;

  /// Guards against submitting a form twice.
  bool _submitting = false;

  AuthStage get stage => _stage;
  User? get user => _user;
  String? get userId => _user?.id;
  bool get isSignedIn => _stage == AuthStage.signedIn;
  bool get submitting => _submitting;
  String? get pendingConfirmationEmail => _pendingConfirmationEmail;

  /// Best-effort display name from auth metadata, used before the profile row
  /// has loaded.
  String? get metadataName {
    final Object? name = _user?.userMetadata?['full_name'];
    return name is String && name.trim().isNotEmpty ? name.trim() : null;
  }

  void _bind() {
    // Seed synchronously so a persisted session does not flash the login
    // screen while the stream delivers its first event.
    final Session? existing = _repository.currentSession;
    _user = _repository.currentUser;
    _stage = existing != null ? AuthStage.signedIn : AuthStage.signedOut;

    _subscription = _repository.onAuthStateChange.listen(
      (AuthState state) {
        _user = state.session?.user;
        final AuthStage next =
            state.session != null ? AuthStage.signedIn : AuthStage.signedOut;
        if (next == AuthStage.signedIn) _pendingConfirmationEmail = null;
        if (next != _stage || state.event == AuthChangeEvent.userUpdated) {
          _stage = next;
          safeNotify();
        }
      },
      onError: (Object error) => setError(error),
    );
  }

  Future<bool> signIn({
    required String email,
    required String password,
  }) async {
    return _submit(() => _repository.signIn(email: email, password: password));
  }

  /// Returns true on success. When the project requires email confirmation,
  /// [pendingConfirmationEmail] is set and the caller should show the
  /// verify-email screen rather than navigating to the dashboard.
  Future<bool> signUp({
    required String email,
    required String password,
    required String fullName,
  }) async {
    return _submit(() async {
      final SignUpOutcome outcome = await _repository.signUp(
        email: email,
        password: password,
        fullName: fullName,
      );
      _pendingConfirmationEmail =
          outcome.needsEmailConfirmation ? outcome.email : null;
    });
  }

  /// Changes the password of the signed-in user.
  ///
  /// Returns true on success; on failure [errorMessage] says why. There is no
  /// email step — see [AuthRepository.changePassword].
  Future<bool> changePassword({
    required String currentPassword,
    required String newPassword,
  }) {
    return _submit(() => _repository.changePassword(
          currentPassword: currentPassword,
          newPassword: newPassword,
        ));
  }

  Future<bool> resendConfirmation() async {
    final String? email = _pendingConfirmationEmail;
    if (email == null) return false;
    return _submit(() => _repository.resendConfirmation(email));
  }

  Future<void> signOut() async {
    await _submit(() => _repository.signOut());
  }

  void clearPendingConfirmation() {
    _pendingConfirmationEmail = null;
    safeNotify();
  }

  Future<bool> _submit(Future<void> Function() action) async {
    if (_submitting) return false;
    _submitting = true;
    clearError();
    safeNotify();
    try {
      await action();
      return true;
    } catch (error) {
      setError(ErrorMapper.map(error));
      return false;
    } finally {
      _submitting = false;
      safeNotify();
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
