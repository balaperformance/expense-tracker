/// Form validators shared across auth and transaction forms.
library;

class Validators {
  const Validators._();

  static final RegExp _email = RegExp(r'^[\w.+-]+@[\w-]+\.[\w.-]+$');

  static String? email(String? value) {
    final String input = (value ?? '').trim();
    if (input.isEmpty) return 'Email is required';
    if (!_email.hasMatch(input)) return 'Enter a valid email address';
    return null;
  }

  /// Sign-in only: just enough to catch an empty box.
  ///
  /// Deliberately lenient. Strength rules belong where a password is *chosen*;
  /// enforcing them here would lock out an existing account whose password
  /// predates the rule, and the server is the real authority anyway.
  static String? password(String? value) {
    final String input = value ?? '';
    if (input.isEmpty) return 'Password is required';
    if (input.length < 6) return 'Use at least 6 characters';
    return null;
  }

  /// Minimum length for a newly chosen password. Above Supabase's own
  /// default of 6, so the app rejects a weak password before the round trip.
  static const int minNewPasswordLength = 8;

  /// Shown under the field so the rule is known before it is broken.
  static const String passwordHint =
      'At least $minNewPasswordLength characters, with a letter and a number.';

  /// Registration and change-password: the strength rule.
  ///
  /// Length plus two character classes. Kept to rules a person can satisfy
  /// without a generator — a policy nobody can remember gets written on a
  /// note, which is worse than a slightly shorter password.
  static String? newPassword(String? value) {
    final String input = value ?? '';
    if (input.isEmpty) return 'Password is required';
    if (input.length < minNewPasswordLength) {
      return 'Use at least $minNewPasswordLength characters';
    }
    if (input.trim() != input) {
      return 'Remove the spaces at the start or end';
    }
    if (!input.contains(RegExp(r'[A-Za-z]'))) {
      return 'Include at least one letter';
    }
    if (!input.contains(RegExp(r'[0-9]'))) {
      return 'Include at least one number';
    }
    return null;
  }

  static String? confirmPassword(String? value, String original) {
    if ((value ?? '').isEmpty) return 'Confirm your password';
    if (value != original) return 'Passwords do not match';
    return null;
  }

  static String? required(String? value, String label) {
    if ((value ?? '').trim().isEmpty) return '$label is required';
    return null;
  }

  /// Amount must parse and be strictly greater than zero.
  static String? amount(String? value) {
    final String input = (value ?? '').trim();
    if (input.isEmpty) return 'Amount is required';
    final double? parsed = double.tryParse(input.replaceAll(',', ''));
    if (parsed == null) return 'Enter a valid number';
    if (parsed <= 0) return 'Amount must be greater than 0';
    if (parsed > 999999999) return 'Amount is too large';
    return null;
  }

  static double? parseAmount(String? value) =>
      double.tryParse((value ?? '').trim().replaceAll(',', ''));
}
