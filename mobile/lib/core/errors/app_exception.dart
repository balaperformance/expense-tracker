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
  const AppException(this.message, {this.column});

  final String message;

  /// For a not-null violation: the column left empty, so a caller can point
  /// at the field to fix.
  final String? column;

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
      return AppException(_postgrest(error), column: missingColumn(error));
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

  /// What the user calls a column a write can leave empty.
  static const Map<String, String> _columnLabels = <String, String>{
    'payment_method_id': 'Payment method',
    'source': 'Source',
    'description': 'Description',
    'merchant': 'Payee',
    'category_id': 'Category',
    'amount': 'Amount',
    'expense_date': 'Date',
    'income_date': 'Date',
    'txn_date': 'Date',
    'account_id': 'Account',
    'bank_account_id': 'Account',
    'person': 'Person',
    'credit_card_id': 'Card',
    'card_id': 'Card',
  };

  /// The column a not-null violation (23502) names — raw or already mapped —
  /// or null for any other error.
  static String? missingColumn(Object error) {
    if (error is AppException) return error.column;
    if (error is! PostgrestException || error.code != '23502') return null;
    return RegExp(r'column "([a-z_]+)"').firstMatch(error.message)?.group(1);
  }

  static String _postgrest(PostgrestException error) {
    switch (error.code) {
      case '23505':
        return 'That entry already exists.';
      case '23503':
        return 'This item is still linked to other records.';
      case '23502':
        // Name the field: "null value in column "source" of relation "income"…".
        final String? label = _columnLabels[missingColumn(error)];
        return label != null ? '$label is missing.' : 'A required field is missing.';
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
