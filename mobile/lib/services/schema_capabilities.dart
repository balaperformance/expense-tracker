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

  /// Postgres: relation does not exist (older PostgREST versions).
  static const String _undefinedTableLegacy = '42P01';

  /// Postgres: permission denied. Before migration 010 granted the app
  /// `notification_log`, the table existed but was closed to it.
  static const String _permissionDenied = '42501';

  static bool _resolved = false;

  static bool _merchant = false;
  static bool _bankAccounts = false;
  static bool _expenseBankLink = false;
  static bool _incomeBankLink = false;
  static bool _transfers = false;
  static bool _creditCards = false;
  static bool _treatments = false;
  static bool _tags = false;
  static bool _statementDetails = false;
  static bool _notifications = false;
  static bool _notificationInbox = false;
  static bool _notificationClear = false;
  static bool _cashAccount = false;

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

  /// `credit_cards`, `credit_card_transactions` and both `credit_card_id`
  /// columns (migration 004, shared with the web app). One migration adds all
  /// four, so the feature is on only when every part is present.
  static bool get creditCards => _creditCards;

  /// `receivables`, `account_transactions.receivable_id` and the treatment
  /// functions (migration 005, shared with the web app). With it, a
  /// transfer to one of the user's accounts is saved through
  /// `record_bank_movement`, which can also link the other account's row
  /// when both statements were imported. 005 builds on 004, so it counts only
  /// with it — exactly as the web app decides.
  static bool get treatments => _treatments;

  /// `tags`, `expense_tags`, `income_tags` (migration 006): an imported row's
  /// tags are written as tags rather than into its notes.
  static bool get tags => _tags;

  /// `account_transactions.reference`, `upi_id`, `txn_time` (migration 007):
  /// what a statement printed about a movement is kept on the movement, so a
  /// re-import is recognised by its reference.
  static bool get statementDetails => _statementDetails;

  /// `notification_preferences` (migration 008) and `mobile_push_tokens`
  /// (migration 009): push notifications on the phone. Both are needed — the
  /// switches are shared with the web app, the device table is the phone's.
  static bool get notifications => _notifications;

  /// `notification_log` readable by the app with its title, body, link and
  /// read time (migration 010): the bell's history, shared with the web app.
  static bool get notificationInbox => _notificationInbox;

  /// `notification_log.cleared_at` (migration 012): read notifications can be
  /// cleared from the list. Builds on the inbox.
  static bool get notificationClear => _notificationClear;

  /// `bank_accounts.kind` (migration 011): one account can be the user's cash
  /// in hand, which cash expenses come out of.
  static bool get cashAccount => _cashAccount;

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
      if (!_creditCards) 'credit card tables and columns (004)',
      if (!_treatments) 'transfer linking, loans and reimbursements (005)',
      if (!_tags) 'tags (006)',
      if (!_statementDetails) 'statement references and UPI details (007)',
      if (!_notifications) 'push notifications (008, 009)',
      if (!_notificationInbox) 'notification history (010)',
      if (!_cashAccount) 'cash balance (011)',
      if (!_notificationClear) 'clearing read notifications (012)',
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
              // 5–8: credit cards (004).
              _probe(client, 'credit_cards', 'id'),
              _probe(client, 'credit_card_transactions', 'id'),
              _probe(client, 'expenses', 'credit_card_id'),
              _probe(client, 'account_transactions', 'credit_card_id'),
              // 9–10: treatments (005).
              _probe(client, 'receivables',
                  'id, kind, person, ledger_entry_id, expense_id, due_date, note'),
              _probe(client, 'account_transactions', 'receivable_id'),
              // 11–13: tags (006).
              _probe(client, 'tags', 'id, name'),
              _probe(client, 'expense_tags', 'expense_id, tag_id'),
              _probe(client, 'income_tags', 'income_id, tag_id'),
              // 14: statement details (007).
              _probe(client, 'account_transactions',
                  'reference, upi_id, txn_time'),
              // 15–16: push notifications (008 shared, 009 the phone's).
              _probe(client, 'notification_preferences',
                  'user_id, daily_reminder, spending_summary, low_balance, '
                      'card_due, timezone'),
              _probe(client, 'mobile_push_tokens', 'id, token'),
              // 17–18: notification history (010) and clearing it (012).
              _probe(client, 'notification_log',
                  'event_key, kind, sent_at, title, body, url, read_at',
                  deniedMeansMissing: true),
              _probe(client, 'notification_log', 'cleared_at',
                  deniedMeansMissing: true),
              // 19: the cash account (011).
              _probe(client, 'bank_accounts', 'kind'),
            ]));

    _merchant = results[0];
    _bankAccounts = results[1];
    _expenseBankLink = results[2];
    _incomeBankLink = results[3];
    _transfers = results[4];
    _creditCards = results.sublist(5, 9).every((bool present) => present);
    _treatments = _creditCards && results[9] && results[10];
    _tags = results.sublist(11, 14).every((bool present) => present);
    _statementDetails = results[14];
    _notifications = results[15] && results[16];
    _notificationInbox = results[17];
    _notificationClear = _notificationInbox && results[18];
    _cashAccount = _bankAccounts && results[19];
    _resolved = true;
  }

  /// Returns whether [table].[column] can be selected.
  ///
  /// Only a missing column or missing table counts as "absent" — and, with
  /// [deniedMeansMissing], a table the app has not been granted yet. Any other
  /// failure (network, auth) is rethrown so a transient outage is never
  /// misread as a permanently missing feature.
  static Future<bool> _probe(
    SupabaseClient client,
    String table,
    String column, {
    bool deniedMeansMissing = false,
  }) async {
    try {
      await client.from(table).select(column).limit(1);
      return true;
    } on PostgrestException catch (error) {
      if (error.code == _undefinedColumn ||
          error.code == _undefinedTable ||
          error.code == _undefinedTableLegacy ||
          (deniedMeansMissing && error.code == _permissionDenied)) {
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
    bool? creditCards,
    bool? treatments,
    bool? tags,
    bool? statementDetails,
    bool? notifications,
    bool? notificationInbox,
    bool? notificationClear,
    bool? cashAccount,
  }) {
    _merchant = merchant ?? _merchant;
    _bankAccounts = bankAccounts ?? _bankAccounts;
    _expenseBankLink = expenseBankLink ?? _expenseBankLink;
    _incomeBankLink = incomeBankLink ?? _incomeBankLink;
    _transfers = transfers ?? _transfers;
    _creditCards = creditCards ?? _creditCards;
    _treatments = treatments ?? _treatments;
    _tags = tags ?? _tags;
    _statementDetails = statementDetails ?? _statementDetails;
    _notifications = notifications ?? _notifications;
    _notificationInbox = notificationInbox ?? _notificationInbox;
    _notificationClear = notificationClear ?? _notificationClear;
    _cashAccount = cashAccount ?? _cashAccount;
    _resolved = true;
  }

  static void debugReset() {
    _resolved = false;
    _merchant = false;
    _bankAccounts = false;
    _expenseBankLink = false;
    _incomeBankLink = false;
    _transfers = false;
    _creditCards = false;
    _treatments = false;
    _tags = false;
    _statementDetails = false;
    _notifications = false;
    _notificationInbox = false;
    _notificationClear = false;
    _cashAccount = false;
  }
}
