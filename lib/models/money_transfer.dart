/// Moving money between two accounts the user already owns.
///
/// A transfer is not a financial event in the household sense: nothing was
/// earned and nothing was spent, the same money simply sits somewhere else.
/// The whole model follows from that:
///
///  * it writes two ledger rows (a debit and a credit) and nothing else,
///  * it never creates an expense or an income row, which is why it cannot
///    reach the Dashboard, Reports, budgets or spending analytics,
///  * it is labelled from [moneyTransferLabel] rather than from a row in
///    `categories`, so it never pollutes the category picker or breakdown.
library;

import '../core/utils/date_utils.dart';

/// Shown wherever a real category would be. Intentionally not a database
/// category: see the library comment above.
const String moneyTransferLabel = 'Money Transfer';

/// Why a transfer cannot be made. Kept as an enum so the reason is testable
/// without depending on the wording shown to the user.
enum TransferProblem {
  noSource,
  noDestination,
  sameAccount,
  invalidAmount,
  amountTooLarge,
  insufficientFunds,
}

extension TransferProblemMessage on TransferProblem {
  String message({String? sourceLabel, String? availableText}) =>
      switch (this) {
        TransferProblem.noSource => 'Choose the account to transfer from.',
        TransferProblem.noDestination => 'Choose the account to transfer to.',
        TransferProblem.sameAccount =>
          'Pick two different accounts. Money cannot move to the account it '
              'came from.',
        TransferProblem.invalidAmount => 'Enter an amount greater than 0.',
        TransferProblem.amountTooLarge => 'That amount is too large.',
        TransferProblem.insufficientFunds => availableText == null
            ? 'Not enough money in ${sourceLabel ?? 'that account'}.'
            : '${sourceLabel ?? 'That account'} only has $availableText '
                'available.',
      };
}

/// What the user filled in. Pure data, no database types.
class TransferDraft {
  const TransferDraft({
    required this.fromAccountId,
    required this.toAccountId,
    required this.amount,
    required this.date,
    this.note,
  });

  final String? fromAccountId;
  final String? toAccountId;
  final double? amount;
  final DateTime date;
  final String? note;

  String? get trimmedNote {
    final String? text = note?.trim();
    return (text == null || text.isEmpty) ? null : text;
  }
}

/// Validates a transfer. Pure function, so every rule is unit-tested without
/// a live database.
///
/// [availableBalance] is the sender's ledger-derived balance. It is compared
/// in whole cents because the amounts are stored as `numeric(14,2)` and a
/// binary-float comparison can otherwise reject a transfer of exactly the
/// full balance.
///
/// Pass null for [availableBalance] to check only the rules that need no
/// balance — which is what the caller does before spending a request on
/// reading one.
class TransferValidation {
  const TransferValidation._();

  /// Largest single movement, matching the expense/income amount validator.
  static const double maxAmount = 999999999;

  static TransferProblem? check({
    required TransferDraft draft,
    required double? availableBalance,
  }) {
    final String? from = draft.fromAccountId;
    final String? to = draft.toAccountId;

    if (from == null || from.isEmpty) return TransferProblem.noSource;
    if (to == null || to.isEmpty) return TransferProblem.noDestination;
    if (from == to) return TransferProblem.sameAccount;

    final double? amount = draft.amount;
    if (amount == null || amount.isNaN || amount <= 0) {
      return TransferProblem.invalidAmount;
    }
    if (amount > maxAmount) return TransferProblem.amountTooLarge;

    // `isFinite` is not defensive padding: `round()` throws outright on a
    // non-finite double, and an amount above [maxAmount] has already been
    // rejected above, so by here only the balance could be non-finite.
    if (availableBalance != null &&
        availableBalance.isFinite &&
        _cents(amount) > _cents(availableBalance)) {
      return TransferProblem.insufficientFunds;
    }

    return null;
  }

  static int _cents(double value) => (value * 100).round();
}

/// The description stored on each leg.
///
/// The user's own note wins when they wrote one, exactly as a bank shows your
/// remark. Otherwise the leg describes itself, so the row still reads
/// correctly even if the other account is later deleted and the structured
/// link is cleared.
String transferDescription({
  required String? note,
  required bool isOutgoing,
  required String counterpartyLabel,
}) {
  final String? text = note?.trim();
  if (text != null && text.isNotEmpty) return text;
  return isOutgoing
      ? 'Transfer to $counterpartyLabel'
      : 'Transfer from $counterpartyLabel';
}

/// Convenience for building the wire date, kept here so the repository and
/// tests agree on the format.
String transferDateString(DateTime date) => AppDateUtils.toDateString(date);
