/// Translates low-level Supabase/network failures into user-safe messages.
///
/// Raw exception text can embed query fragments and identifiers, so the UI
/// only ever shows a mapped [AppException.message]. Financial values and
/// credentials are never included.
library;

import 'dart:async';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/validators.dart';

class AppException implements Exception {
  const AppException(this.message, {this.isAuthExpired = false});

  final String message;
  final bool isAuthExpired;

  @override
  String toString() => 'AppException: $message';
}

class ErrorMapper {
  const ErrorMapper._();

  static AppException map(Object error) {
    if (error is AppException) return error;

    if (error is AuthException) {
      return AppException(_auth(error));
    }

    if (error is PostgrestException) {
      return AppException(_postgrest(error));
    }

    if (error is SocketException || error is TimeoutException) {
      return const AppException(
        'No internet connection. Check your network and try again.',
      );
    }

    if (error is StateError) {
      return AppException(error.message);
    }

    return const AppException(
      'Something went wrong. Please try again.',
    );
  }

  static String _auth(AuthException error) {
    final String raw = error.message.toLowerCase();

    if (raw.contains('email not confirmed') ||
        raw.contains('not confirmed')) {
      return 'Please confirm your email address first. '
          'Check your inbox for the verification link.';
    }
    if (raw.contains('invalid login credentials')) {
      return 'Incorrect email or password.';
    }
    if (raw.contains('user already registered') ||
        raw.contains('already been registered')) {
      return 'An account with this email already exists. Try signing in.';
    }
    if (raw.contains('password should be at least')) {
      return 'Password is too short. Use at least 6 characters.';
    }
    // Raised when the project's own strength policy rejects the password.
    // The server's reasons are generic, so the app states its own rule.
    if (error is AuthWeakPasswordException || raw.contains('weak password')) {
      return 'That password is too weak. ${Validators.passwordHint}';
    }
    if (raw.contains('should be different from the old password') ||
        raw.contains('same_password')) {
      return 'Your new password must be different from the current one.';
    }
    if (raw.contains('reauthentication') || raw.contains('not authenticated')) {
      return 'Please sign in again and retry.';
    }
    if (raw.contains('rate limit') || raw.contains('too many')) {
      return 'Too many attempts. Please wait a moment and try again.';
    }
    if (raw.contains('invalid email')) {
      return 'That email address does not look valid.';
    }
    return 'Authentication failed. Please try again.';
  }

  static String _postgrest(PostgrestException error) {
    switch (error.code) {
      case '23505':
        return 'That entry already exists.';
      case '23503':
        return 'This item is still linked to other records.';
      case '23502':
        return 'A required field is missing.';
      case '42501':
        return 'You do not have permission to do that.';
      case 'PGRST301':
        return 'Your session expired. Please sign in again.';
      case 'PGRST303':
        // Retried automatically; only surfaces if it somehow persists.
        return 'Your device clock looks out of sync. Retrying usually fixes it.';
    }

    final String raw = error.message.toLowerCase();
    if (raw.contains('row-level security') || raw.contains('policy')) {
      return 'You do not have permission to do that.';
    }
    if (raw.contains('merchant')) {
      return 'The database is missing the "merchant" column on expenses. '
          'Run the migration provided in the setup notes.';
    }
    return 'Could not reach the database. Please try again.';
  }
}
