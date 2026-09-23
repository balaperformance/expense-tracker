import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/errors/retry.dart';

/// Detects which optional schema objects exist, once per app launch.
///
/// Phase 2 adds tables and columns through a migration the developer runs by
/// hand. Rather than hard-failing every query until that happens, the app
/// asks the database what it actually has and degrades to the Phase 1
/// feature set when the migration has not been applied.
///
/// The probes are cheap: PostgREST validates the requested columns before it
/// reads any rows, so an empty result still proves the shape exists.
class SchemaCapabilities {
  const SchemaCapabilities._();

  /// Postgres: column does not exist.
  static const String _undefinedColumn = '42703';

  /// PostgREST: relation not found in the exposed schema.
  static const String _undefinedTable = 'PGRST205';

  static bool _resolved = false;

  static bool _merchant = false;
  static bool _bankAccounts = false;
  static bool _expenseBankLink = false;
  static bool _incomeBankLink = false;
  static bool _transfers = false;

  static bool get resolved => _resolved;

  /// `expenses.merchant` (Phase 1 optional migration).
  static bool get merchant => _merchant;

  /// `bank_accounts` and `account_transactions` tables (Phase 2).
  static bool get bankAccounts => _bankAccounts;

  static bool get expenseBankLink => _expenseBankLink;

  static bool get incomeBankLink => _incomeBankLink;

  /// `account_transactions.counterparty_account_id` (migration 003).
  ///
  /// Gates self-account transfers. Without the column a transfer leg could
  /// still be written, but the statement would have no structured link to the
  /// other side, so the feature is hidden rather than offered half-working.
  static bool get transfers => _transfers;

  /// True only when everything Phase 2 needs to record a debit is present.
  ///
  /// The expense link is required: without it an expense cannot say which
  /// account it came from, so offering bank payment sources would silently
  /// lose that choice.
  static bool get phase2Ready => _bankAccounts && _expenseBankLink;

  /// One-line summary for the migration prompt shown in the UI.
  static String get missingSummary {
    final List<String> missing = <String>[
      if (!_bankAccounts) 'bank_accounts / account_transactions tables',
      if (!_expenseBankLink) 'expenses.bank_account_id',
      if (!_incomeBankLink) 'income.bank_account_id',
      if (!_merchant) 'expenses.merchant',
      if (!_transfers) 'account_transactions.counterparty_account_id',
    ];
    return missing.join(', ');
  }

  /// Probes the database. Safe to call more than once; only the first call
  /// does work unless [force] is set.
  static Future<void> resolve(SupabaseClient client, {bool force = false}) async {
    if (_resolved && !force) return;

    // This is the first database call after signing in, so it absorbs the
    // brief clock-skew window on behalf of everything that follows.
    final List<bool> results =
        await retryOnTransientAuth(() => Future.wait(<Future<bool>>[
              _probe(client, 'expenses', 'merchant'),
              _probe(client, 'bank_accounts', 'id'),
              _probe(client, 'expenses', 'bank_account_id'),
              _probe(client, 'income', 'bank_account_id'),
              _probe(
                  client, 'account_transactions', 'counterparty_account_id'),
            ]));

    _merchant = results[0];
    _bankAccounts = results[1];
    _expenseBankLink = results[2];
    _incomeBankLink = results[3];
    _transfers = results[4];
    _resolved = true;
  }

  /// Returns whether [table].[column] can be selected.
  ///
  /// Only a missing column or missing table counts as "absent". Any other
  /// failure (network, auth) is rethrown so a transient outage is never
  /// misread as a permanently missing feature.
  static Future<bool> _probe(
    SupabaseClient client,
    String table,
    String column,
  ) async {
    try {
      await client.from(table).select(column).limit(1);
      return true;
    } on PostgrestException catch (error) {
      if (error.code == _undefinedColumn || error.code == _undefinedTable) {
        return false;
      }
      rethrow;
    }
  }

  /// Test seam. Lets unit tests exercise capability-dependent logic without a
  /// live database.
  static void debugOverride({
    bool? merchant,
    bool? bankAccounts,
    bool? expenseBankLink,
    bool? incomeBankLink,
    bool? transfers,
  }) {
    _merchant = merchant ?? _merchant;
    _bankAccounts = bankAccounts ?? _bankAccounts;
    _expenseBankLink = expenseBankLink ?? _expenseBankLink;
    _incomeBankLink = incomeBankLink ?? _incomeBankLink;
    _transfers = transfers ?? _transfers;
    _resolved = true;
  }

  static void debugReset() {
    _resolved = false;
    _merchant = false;
    _bankAccounts = false;
    _expenseBankLink = false;
    _incomeBankLink = false;
    _transfers = false;
  }
}
