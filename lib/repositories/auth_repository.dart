import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/errors/app_exception.dart';

/// All authentication I/O. Returns plain results and throws [AppException]
/// so the UI never handles a Supabase type directly.
class AuthRepository {
  const AuthRepository(this._auth);

  final GoTrueClient _auth;

  Session? get currentSession => _auth.currentSession;

  User? get currentUser => _auth.currentUser;

  Stream<AuthState> get onAuthStateChange => _auth.onAuthStateChange;

  /// Signs up and reports whether Supabase returned a usable session.
  ///
  /// With "Confirm email" enabled the session is null and the caller must
  /// route to the verify-email screen rather than the dashboard.
  Future<SignUpOutcome> signUp({
    required String email,
    required String password,
    required String fullName,
  }) async {
    try {
      final AuthResponse response = await _auth.signUp(
        email: email.trim(),
        password: password,
        data: <String, dynamic>{'full_name': fullName.trim()},
      );
      return SignUpOutcome(
        needsEmailConfirmation: response.session == null,
        email: email.trim(),
      );
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  Future<void> signIn({
    required String email,
    required String password,
  }) async {
    try {
      await _auth.signInWithPassword(
        email: email.trim(),
        password: password,
      );
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  Future<void> signOut() async {
    try {
      await _auth.signOut();
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// Changes the signed-in user's password after proving they know the
  /// current one.
  ///
  /// There is no email in this flow. The proof is a real sign-in with the
  /// current password, which is the only way to verify it without a
  /// privileged key — and a *failed* sign-in does not disturb the session
  /// that is already open, so getting the current password wrong leaves the
  /// user exactly where they were.
  ///
  /// Neither password is stored, logged or put in an error message.
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final String? email = _auth.currentUser?.email;
    final String? problem = checkPasswordChange(
      email: email,
      currentPassword: currentPassword,
      newPassword: newPassword,
    );
    if (problem != null) throw AppException(problem);

    // 1. Prove the current password. Wrong credentials are reported as
    //    exactly that; a transport failure must not be, or the user would
    //    doubt a password that is in fact correct.
    try {
      await _auth.signInWithPassword(email: email!, password: currentPassword);
    } on AuthApiException catch (error) {
      final String raw = error.message.toLowerCase();
      if (raw.contains('invalid login credentials')) {
        throw const AppException('Your current password is not correct.');
      }
      throw ErrorMapper.map(error);
    } catch (error) {
      throw ErrorMapper.map(error);
    }

    // 2. Set the new one on the session just proven.
    try {
      await _auth.updateUser(UserAttributes(password: newPassword));
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// Preconditions that need no network, so they are decided in one place and
  /// unit-tested. Returns null when the change may be attempted.
  ///
  /// [email] is the signed-in user's address; null means either no session or
  /// an account with no password to change (an anonymous dev session).
  static String? checkPasswordChange({
    required String? email,
    required String currentPassword,
    required String newPassword,
  }) {
    if (email == null || email.isEmpty) {
      return 'This account has no password to change. Sign in with an email '
          'address first.';
    }
    if (currentPassword.isEmpty) return 'Enter your current password.';
    if (newPassword.isEmpty) return 'Enter a new password.';
    if (currentPassword == newPassword) {
      return 'Your new password must be different from the current one.';
    }
    return null;
  }

  Future<void> resendConfirmation(String email) async {
    try {
      await _auth.resend(type: OtpType.signup, email: email.trim());
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }
}

class SignUpOutcome {
  const SignUpOutcome({
    required this.needsEmailConfirmation,
    required this.email,
  });

  final bool needsEmailConfirmation;
  final String email;
}
