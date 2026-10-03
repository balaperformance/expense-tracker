/// Reads an Indian bank transaction SMS into structured fields.
///
/// Deterministic and pure: no network, no AI, no plugins. Banks phrase these
/// messages in a small number of recognisable shapes, and every fact the app
/// needs — amount, direction, bank, account, payee, date, reference — is
/// stated literally in the text. Sending that to a model would be slower,
/// non-reproducible, and would put the message on the network for no gain.
///
/// The parser's job is to be *honestly* incomplete. Each field is extracted
/// by a pattern specific enough to be right or to find nothing; where a value
/// cannot be read with confidence it is left null and the review screen shows
/// the gap. A wrong value silently prefilled is worse than an empty one,
/// because the user has to notice it before they can correct it.
library;

import 'bank_sms.dart';

class BankSmsParser {
  const BankSmsParser();

  /// Longest message accepted. A transaction alert is a couple of lines;
  /// anything past this is a paste of something else.
  static const int maxInputChars = 2000;

  /// Above this the "amount" is a misread, not a purchase.
  static const double _maxAmount = 999999999;

  // -------------------------------------------------------------------------
  // Direction
  // -------------------------------------------------------------------------

  /// Words stating money left the account, and words stating it arrived.
  ///
  /// The *earliest* match wins, because banks lead with the verb ("Sent
  /// Rs…", "Rs 30 debited…") and a later mention is usually incidental —
  /// "credited" followed by "…to your debit card".
  static final RegExp _debitWords = RegExp(
    r'\b(?:debited|debit|spent|paid|sent|withdrawn|withdrawal|purchased|purchase)\b',
    caseSensitive: false,
  );

  static final RegExp _creditWords = RegExp(
    r'\b(?:credited|credit|received|deposited|deposit|refunded|refund)\b',
    caseSensitive: false,
  );

  // -------------------------------------------------------------------------
  // Amounts
  // -------------------------------------------------------------------------

  /// A figure carrying a currency marker: "Rs.2900.00", "INR 30", "1,250.50".
  static final RegExp _currencyLed = RegExp(
    r'(?:rs\.?|inr|₹)\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)',
    caseSensitive: false,
  );

  /// The same the other way round: "2900.00 INR".
  static final RegExp _currencyTrailed = RegExp(
    r'([0-9][0-9,]*(?:\.[0-9]{1,2})?)\s*(?:rs\.?|inr|₹)',
    caseSensitive: false,
  );

  /// Last resort for messages that omit the currency: "debited by 500".
  static final RegExp _bareAfterVerb = RegExp(
    r'\b(?:debited|credited|spent|paid|sent|withdrawn)\s+'
    r'(?:by|for|with|of)?\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)\b',
    caseSensitive: false,
  );

  /// The balance line. Matched so its figure can be *excluded* from the
  /// candidates above — "Bal:183.03" is not what was spent.
  static final RegExp _balance = RegExp(
    r'(?:avl\.?\s*|available\s*|a/?c\s*|closing\s*|clear\s*|total\s*)*'
    r'bal(?:ance)?\.?\s*(?:is\s*)?[:\-]?\s*'
    r'(?:rs\.?|inr|₹)?\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)',
    caseSensitive: false,
  );

  // -------------------------------------------------------------------------
  // Account
  // -------------------------------------------------------------------------

  /// "a/c", "ac", "account" — the anchor the bank name sits in front of and
  /// the masked digits sit behind.
  static final RegExp _accountMarker = RegExp(
    r'\b(?:a/c|ac|account)\b',
    caseSensitive: false,
  );

  /// Masked digits directly after the account marker.
  ///
  /// Deliberately tight. Only separators, a "no."/":"/"#" and mask characters
  /// may stand between the marker and the digits, so "a/c Txn ID 663129068661"
  /// cannot read a twelve-digit reference as an account number. The run must
  /// also be short and complete: a longer number is not a mask.
  static final RegExp _maskedDigits = RegExp(
    r'^\s*(?:no\.?|number)?\s*[:#]?\s*[*xX]{0,8}\s*([0-9]{3,6})(?![0-9])',
  );

  /// "card ending 1234", "ending with XX4821".
  static final RegExp _endingDigits = RegExp(
    r'\bending\s*(?:with|in)?\s*[*xX]*\s*([0-9]{4})(?![0-9])',
    caseSensitive: false,
  );

  /// A bank named without any "a/c" nearby.
  static final RegExp _bareBankName = RegExp(
    r'\b([A-Z][A-Za-z&.]*(?:\s+[A-Za-z&.]+){0,2}\s+Bank)\b',
  );

  /// Sentence scaffolding that is never part of a bank's name.
  ///
  /// "of" and "and" are deliberately absent: they are scaffolding in general
  /// but they are also parts of real names — State Bank of India, Bank of
  /// Baroda — and losing them would be worse than keeping an occasional
  /// stray word.
  static const Set<String> _bankNoise = <String>{
    'from', 'in', 'to', 'at', 'your', 'ur', 'the', 'with', 'on', 'by',
    'is', 'was', 'has', 'been', 'a', 'an', 'rs', 'inr', 'debited',
    'credited', 'spent', 'paid', 'sent', 'withdrawn', 'received', 'deposited',
    'transferred', 'dear', 'customer', 'txn', 'transaction', 'amount', 'using',
    'for', 'via', 'thru', 'through', 'linked',
  };

  // -------------------------------------------------------------------------
  // Payee
  // -------------------------------------------------------------------------

  /// Who the money went to.
  ///
  /// Anchored on a standalone "to"/"at" and stopped by whichever field the
  /// message starts next. The date terminator requires a digit after "on", so
  /// a merchant like "SALON ON WHEELS" is not cut in half.
  static final RegExp _payee = RegExp(
    r'\b(?:to|at)\s+([A-Za-z0-9@][^\n]{1,59}?)'
    r'(?=\s+on\s+[0-9]'
    r'|\s+(?:ref|refno|txn|txnid|transaction|upi|utr|rrn|bal|avl|info|dt|'
    r'date|a/c|not\b|if\b|call\b|thru\b|via\b|from\b)'
    r'|\s*[.;,]?\s*$)',
    caseSensitive: false,
  );

  // -------------------------------------------------------------------------
  // Reference
  // -------------------------------------------------------------------------

  static final RegExp _reference = RegExp(
    r'\b(?:txn\s*(?:id|no\.?|number|num)?|transaction\s*(?:id|no\.?)?'
    r'|ref(?:erence)?\s*(?:id|no\.?|number|num)?|rrn|utr)\s*'
    r'[:#\-]?\s*([A-Za-z0-9]{4,24})\b',
    caseSensitive: false,
  );

  // -------------------------------------------------------------------------
  // Dates
  // -------------------------------------------------------------------------

  static final RegExp _isoDate =
      RegExp(r'(?<![0-9])([0-9]{4})-([0-9]{2})-([0-9]{2})(?![0-9])');

  static final RegExp _namedMonthDate = RegExp(
    r'(?<![0-9A-Za-z])([0-9]{1,2})[\-\s/]([A-Za-z]{3,9})[\-\s/]([0-9]{2,4})'
    r'(?![0-9])',
    caseSensitive: false,
  );

  static final RegExp _slashDate = RegExp(
    r'(?<![0-9])([0-9]{1,2})[/\-]([0-9]{1,2})[/\-]([0-9]{2,4})(?![0-9])',
  );

  static final RegExp _dottedDate = RegExp(
    r'(?<![0-9])([0-9]{1,2})\.([0-9]{1,2})\.([0-9]{2,4})(?![0-9])',
  );

  static const List<String> _monthNames = <String>[
    'jan', 'feb', 'mar', 'apr', 'may', 'jun',
    'jul', 'aug', 'sep', 'oct', 'nov', 'dec',
  ];

  // -------------------------------------------------------------------------

  /// Reads [raw] and returns whatever could be established.
  ///
  /// Never throws: any text at all is a legitimate input, and an unreadable
  /// paste produces [ParsedBankSms.unrecognised] rather than an error every
  /// caller would have to catch.
  ///
  /// [now] settles the century for two-digit years and nothing else. It is a
  /// parameter so the tests do not drift as the real clock moves.
  ParsedBankSms parse(String raw, {DateTime? now}) {
    final String text = _normalise(raw);
    if (text.isEmpty) return const ParsedBankSms.unrecognised();

    final SmsDirection? direction = _direction(text);
    final _Span? balanceSpan = _firstSpan(_balance, text);
    final double? amount = _amount(text, balanceSpan);

    // Without these two there is no transaction. Reporting a bank name read
    // off an unrelated paste would only be confusing.
    if (direction == null || amount == null) {
      return const ParsedBankSms.unrecognised();
    }

    final _AccountRead account = _account(text);

    return ParsedBankSms(
      direction: direction,
      amount: amount,
      bankName: account.bankName,
      last4: account.last4,
      counterparty: _counterparty(text),
      date: _date(text, now ?? DateTime.now()),
      reference: _referenceIn(text),
      availableBalance:
          balanceSpan == null ? null : _toAmount(balanceSpan.capture),
    );
  }

  // -------------------------------------------------------------------------

  /// Collapses the message to one line of single-spaced text.
  ///
  /// Banks break these messages at arbitrary points, so a pattern coping with
  /// both "A/C *6459\nTo NAME" and "A/C *6459 To NAME" would have to allow
  /// newlines everywhere. Flattening once, here, keeps every pattern below
  /// simple.
  static String _normalise(String raw) {
    final String capped =
        raw.length > maxInputChars ? raw.substring(0, maxInputChars) : raw;
    return capped.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static SmsDirection? _direction(String text) {
    final int debit = _debitWords.firstMatch(text)?.start ?? -1;
    final int credit = _creditWords.firstMatch(text)?.start ?? -1;

    if (debit < 0 && credit < 0) return null;
    if (credit < 0) return SmsDirection.debit;
    if (debit < 0) return SmsDirection.credit;
    return debit <= credit ? SmsDirection.debit : SmsDirection.credit;
  }

  /// The transacted amount, never the balance.
  static double? _amount(String text, _Span? balance) {
    for (final RegExp pattern in <RegExp>[_currencyLed, _currencyTrailed]) {
      for (final RegExpMatch match in pattern.allMatches(text)) {
        if (balance != null && _overlaps(match.start, match.end, balance)) {
          continue;
        }
        final double? value = _toAmount(match.group(1));
        if (value != null) return value;
      }
    }

    final RegExpMatch? bare = _bareAfterVerb.firstMatch(text);
    if (bare == null) return null;
    if (balance != null && _overlaps(bare.start, bare.end, balance)) return null;
    return _toAmount(bare.group(1));
  }

  static double? _toAmount(String? raw) {
    if (raw == null) return null;
    final double? value = double.tryParse(raw.replaceAll(',', ''));
    if (value == null || value <= 0 || value > _maxAmount) return null;
    return value;
  }

  /// Bank name and masked digits, read around the "a/c" anchor.
  ///
  /// Every anchor is tried, not just the first. "ac" is a legitimate spelling
  /// of the marker but it also appears inside ordinary words — "Rs 100 spent
  /// at AC SERVICE from HDFC Bank a/c *6459" has two matches and only the
  /// second is an account. An anchor that yields neither a bank nor digits
  /// told us nothing, so the search moves on rather than stopping there.
  static _AccountRead _account(String text) {
    String? last4;
    String? bankName;

    for (final RegExpMatch marker in _accountMarker.allMatches(text)) {
      final int from = marker.end;
      final int to = (from + 24).clamp(0, text.length);

      final String? digits = _lastFour(
        _maskedDigits.firstMatch(text.substring(from, to))?.group(1),
      );
      final String? named =
          _cleanBank(_bankBefore(text.substring(0, marker.start)));

      if (digits != null || named != null) {
        last4 = digits;
        bankName = named;
        break;
      }
    }

    last4 ??= _lastFour(_endingDigits.firstMatch(text)?.group(1));
    bankName ??= _cleanBank(_bareBankName.firstMatch(text)?.group(1));

    return _AccountRead(bankName: bankName, last4: last4);
  }

  /// The bank's name, from the words immediately before "a/c".
  ///
  /// Reads the last few words and drops the sentence scaffolding off the
  /// front, so "…debited from Airtel Payments Bank a/c" leaves "Airtel
  /// Payments Bank". Four words covers every bank name in use and is short
  /// enough that a longer preceding clause cannot bleed in.
  static String? _bankBefore(String prefix) {
    final List<String> words = prefix
        .split(' ')
        .where((String w) => w.trim().isNotEmpty)
        .toList();
    if (words.isEmpty) return null;

    final List<String> tail =
        words.length <= 4 ? words : words.sublist(words.length - 4);

    // Cut after the *last* piece of scaffolding, not the first. "…spent at AC
    // SERVICE from HDFC Bank a/c" has a real merchant word sitting before the
    // preposition, and starting at the first non-noise word would carry the
    // merchant into the bank's name.
    int start = 0;
    for (int i = 0; i < tail.length; i++) {
      if (_isBankNoise(tail[i])) start = i + 1;
    }
    if (start >= tail.length) return null;

    return tail.sublist(start).join(' ');
  }

  static bool _isBankNoise(String word) {
    final String plain = word.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
    return plain.isEmpty ||
        _bankNoise.contains(plain) ||
        word.contains(RegExp(r'[0-9]'));
  }

  /// Rejects a "name" with no actual bank in it.
  static String? _cleanBank(String? raw) {
    final String? trimmed = raw?.trim().replaceAll(RegExp(r'[.,;:]+$'), '');
    if (trimmed == null || trimmed.isEmpty) return null;
    if (trimmed.length > 40) return null;
    if (trimmed.toLowerCase() == 'bank') return null;
    if (!RegExp(r'[A-Za-z]{2}').hasMatch(trimmed)) return null;
    return trimmed;
  }

  static String? _lastFour(String? digits) {
    if (digits == null || digits.length < 3) return null;
    return digits.length <= 4
        ? digits.padLeft(4, '0')
        : digits.substring(digits.length - 4);
  }

  static String? _counterparty(String text) {
    for (final RegExpMatch match in _payee.allMatches(text)) {
      final String? name = _cleanPayee(match.group(1));
      if (name != null) return name;
    }
    return null;
  }

  /// Keeps a payee only when it reads like a name rather than a leftover
  /// fragment of the message.
  static String? _cleanPayee(String? raw) {
    final String? name =
        raw?.trim().replaceAll(RegExp(r'[.,;:\-]+$'), '').trim();
    if (name == null || name.length < 2 || name.length > 60) return null;

    // Digits alone are a reference, not a payee.
    if (!RegExp(r'[A-Za-z]{2}').hasMatch(name)) return null;

    // "…to your a/c", "…to the bank" name nothing useful.
    final String lower = name.toLowerCase();
    if (lower == 'your account' || lower == 'account' || lower == 'bank') {
      return null;
    }
    return name;
  }

  static String? _referenceIn(String text) {
    for (final RegExpMatch match in _reference.allMatches(text)) {
      final String? value = match.group(1);
      // A reference with no digit in it is a word the pattern ran into.
      if (value != null && RegExp(r'[0-9]').hasMatch(value)) return value;
    }
    return null;
  }

  /// The transaction date, most specific format first.
  static DateTime? _date(String text, DateTime now) {
    final RegExpMatch? iso = _isoDate.firstMatch(text);
    if (iso != null) {
      final DateTime? parsed = _build(
        int.parse(iso.group(3)!),
        int.parse(iso.group(2)!),
        int.parse(iso.group(1)!),
        now,
      );
      if (parsed != null) return parsed;
    }

    for (final RegExpMatch match in _namedMonthDate.allMatches(text)) {
      final int? month = _monthFromName(match.group(2)!);
      if (month == null) continue;
      final DateTime? parsed = _build(
        int.parse(match.group(1)!),
        month,
        int.parse(match.group(3)!),
        now,
      );
      if (parsed != null) return parsed;
    }

    for (final RegExp pattern in <RegExp>[_slashDate, _dottedDate]) {
      for (final RegExpMatch match in pattern.allMatches(text)) {
        final DateTime? parsed = _build(
          int.parse(match.group(1)!),
          int.parse(match.group(2)!),
          int.parse(match.group(3)!),
          now,
        );
        if (parsed != null) return parsed;
      }
    }
    return null;
  }

  static int? _monthFromName(String raw) {
    final String key = raw.toLowerCase();
    if (key.length < 3) return null;
    final int index = _monthNames.indexOf(key.substring(0, 3));
    return index < 0 ? null : index + 1;
  }

  /// Validates a day/month/year triple and settles the century.
  ///
  /// Indian bank SMS write the day first. A two-digit year is read as this
  /// century, and rejected outright if that puts the transaction more than a
  /// year ahead: rolling it back a hundred years would only produce a 1990s
  /// date, which is just as impossible for a bank alert. An unreadable date
  /// is reported as no date, and the review screen says so.
  static DateTime? _build(int day, int month, int rawYear, DateTime now) {
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;

    final int year = rawYear < 100 ? 2000 + rawYear : rawYear;
    if (year < 2000 || year > now.year + 1) return null;

    final DateTime candidate = DateTime(year, month, day);
    // Rejects 31 February and friends, which DateTime would roll forward.
    if (candidate.day != day || candidate.month != month) return null;
    return candidate;
  }

  // -------------------------------------------------------------------------

  static _Span? _firstSpan(RegExp pattern, String text) {
    final RegExpMatch? match = pattern.firstMatch(text);
    return match == null ? null : _Span(match.start, match.end, match.group(1));
  }

  static bool _overlaps(int start, int end, _Span span) =>
      start < span.end && end > span.start;
}

class _Span {
  const _Span(this.start, this.end, this.capture);

  final int start;
  final int end;
  final String? capture;
}

class _AccountRead {
  const _AccountRead({required this.bankName, required this.last4});

  final String? bankName;
  final String? last4;
}
