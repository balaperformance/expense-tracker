/// Matches a parsed bank SMS against the user's own bank accounts.
///
/// Pure, and deliberately unwilling to guess. Picking the wrong account is
/// not a cosmetic error — it debits the wrong balance — so a match is only
/// returned when the evidence identifies exactly one account. Everything else
/// is reported as "not matched", and the review screen asks the user.
///
/// No account is ever created here. A message from a bank the user has not
/// added produces no match, never a new row.
library;

import '../../models/bank_account.dart';
import 'bank_sms.dart';

/// How firmly the message points at the account.
enum SmsMatchStrength {
  /// The masked digits in the message are an account the user holds.
  exact,

  /// Only the bank's name lined up, and only one account carries it.
  likely,
}

class SmsAccountMatch {
  const SmsAccountMatch({
    required this.account,
    required this.strength,
    required this.reason,
  });

  final BankAccount account;
  final SmsMatchStrength strength;

  /// Short and user-facing: "account ending 6459". Shown so the match is
  /// something the user can check rather than something they have to trust.
  final String reason;
}

class SmsAccountMatcher {
  const SmsAccountMatcher();

  /// Words that appear in so many bank names that they identify nothing.
  static const Set<String> _genericBankWords = <String>{
    'bank', 'banks', 'banking', 'payments', 'payment', 'ltd', 'limited',
    'india', 'indian', 'the', 'of', 'and', 'co', 'corporation', 'finance',
    'financial', 'services', 'account', 'savings', 'current', 'a/c', 'ac',
  };

  /// The single account this message is about, or null.
  SmsAccountMatch? match({
    required ParsedBankSms sms,
    required List<BankAccount> accounts,
  }) {
    final List<BankAccount> usable =
        accounts.where((BankAccount a) => a.isActive).toList();
    if (usable.isEmpty) return null;

    final String? last4 = sms.last4;

    if (last4 != null) {
      final List<BankAccount> byDigits = usable
          .where((BankAccount a) => _digits(a.last4) == last4)
          .toList();

      // Exactly one account with those digits is the whole answer. Two would
      // mean the user holds duplicates, which only they can disambiguate.
      if (byDigits.length == 1) {
        return SmsAccountMatch(
          account: byDigits.first,
          strength: SmsMatchStrength.exact,
          reason: 'account ending $last4',
        );
      }
      if (byDigits.length > 1) return null;

      // The message named digits and none of the accounts carry them. Falling
      // back to the bank name here would be actively wrong: "HDFC *6459" when
      // the only HDFC account on file ends 1234 is a different account, not a
      // near miss. The one exception is an account with no digits recorded,
      // which cannot contradict anything.
      final List<BankAccount> unmasked = usable
          .where((BankAccount a) => _digits(a.last4) == null)
          .toList();
      if (unmasked.isEmpty) return null;
      return _byBankName(sms, unmasked);
    }

    return _byBankName(sms, usable);
  }

  /// Falls back to the bank's name, and only when it singles one account out.
  SmsAccountMatch? _byBankName(ParsedBankSms sms, List<BankAccount> accounts) {
    final Set<String> wanted = _identifyingWords(sms.bankName);
    if (wanted.isEmpty) return null;

    final List<BankAccount> hits = accounts.where((BankAccount account) {
      final Set<String> mine = <String>{
        ..._identifyingWords(account.bankName),
        ..._identifyingWords(account.nickname),
      };
      return mine.intersection(wanted).isNotEmpty;
    }).toList();

    if (hits.length != 1) return null;

    return SmsAccountMatch(
      account: hits.first,
      strength: SmsMatchStrength.likely,
      reason: 'the only ${sms.bankName} account',
    );
  }

  /// The words in a bank name that actually distinguish it.
  ///
  /// "Airtel Payments Bank" reduces to {airtel}: matching on "bank" or
  /// "payments" would pair it with every account the user holds.
  static Set<String> _identifyingWords(String? name) {
    if (name == null) return <String>{};
    return name
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((String w) => w.length > 1 && !_genericBankWords.contains(w))
        .toSet();
  }

  /// An account's stored last4, normalised to digits only, or null when it
  /// holds nothing usable.
  static String? _digits(String? raw) {
    final String cleaned = (raw ?? '').replaceAll(RegExp(r'[^0-9]'), '');
    if (cleaned.length < 4) return null;
    return cleaned.substring(cleaned.length - 4);
  }
}
