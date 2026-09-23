/// What a bank SMS says, once it has been read.
///
/// Plain values: no Flutter, no Supabase, no repository. The parser produces
/// one of these, the matcher and the draft builder consume it, and all three
/// are testable against real message text without a device.
///
/// Every field is optional and nothing is inferred to fill a gap. A message
/// that states no date leaves [date] null and the review screen falls back to
/// today in the open, rather than the parser inventing a date that looks
/// like it was read off the SMS.
library;

/// Which way the money moved, as the message states it.
enum SmsDirection { debit, credit }

/// One parsed bank message.
class ParsedBankSms {
  const ParsedBankSms({
    this.direction,
    this.amount,
    this.bankName,
    this.last4,
    this.counterparty,
    this.date,
    this.reference,
    this.availableBalance,
  });

  /// Nothing in the text looked like a bank transaction.
  const ParsedBankSms.unrecognised()
      : direction = null,
        amount = null,
        bankName = null,
        last4 = null,
        counterparty = null,
        date = null,
        reference = null,
        availableBalance = null;

  /// Debit or credit. Null when the message never says, which is enough on
  /// its own to treat it as unreadable — the direction decides whether this
  /// is spending at all.
  final SmsDirection? direction;

  final double? amount;

  /// As printed: "HDFC Bank", "Airtel Payments Bank".
  final String? bankName;

  /// The masked digits, always exactly four when present.
  final String? last4;

  /// Who was paid, or who paid. Null for the many messages that never name
  /// the other side.
  final String? counterparty;

  final DateTime? date;

  /// Transaction or reference id, when the message carries one. Used to
  /// recognise the same SMS pasted twice.
  final String? reference;

  /// Balance after the transaction, when stated. Shown for reassurance and
  /// never saved: the ledger derives balances and this figure is a snapshot
  /// from the bank, not something the app should start trusting.
  final double? availableBalance;

  bool get isDebit => direction == SmsDirection.debit;
  bool get isCredit => direction == SmsDirection.credit;

  bool get hasAmount => amount != null && amount! > 0;

  /// Enough was read to be worth showing a review screen.
  ///
  /// The amount and the direction are the two facts without which there is
  /// no transaction to review. Everything else is a convenience.
  bool get isUsable => hasAmount && direction != null;

  /// Names of the fields that were read, for the "what we found" line.
  List<String> get foundFields => <String>[
        if (hasAmount) 'amount',
        if (bankName != null) 'bank',
        if (last4 != null) 'account',
        if (counterparty != null) 'payee',
        if (date != null) 'date',
        if (reference != null) 'reference',
      ];

  @override
  String toString() => 'ParsedBankSms(${direction?.name}, $amount, '
      '$bankName, $last4, $counterparty, $date, $reference)';
}
