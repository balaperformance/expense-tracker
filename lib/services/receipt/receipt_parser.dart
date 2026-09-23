/// Turns recognised receipt text into structured fields.
///
/// Pure Dart: no plugins, no Flutter, no network. That is deliberate — the
/// parser is the part most likely to be wrong, so it is the part that has to
/// be testable against real receipt text without a device.
///
/// It is also the seam a smarter extractor plugs into later. A cloud vision
/// service or a GenAI model would replace [ReceiptParser.parse] and keep
/// producing the same [ReceiptResult], leaving the review screen and the
/// expense flow untouched.
library;

import 'receipt_result.dart';

class ReceiptParser {
  const ReceiptParser();

  /// Lines that name the figure the customer actually pays, strongest first.
  ///
  /// Order matters: a receipt commonly prints "Subtotal", "Tax" and "Total"
  /// and sometimes "Grand Total" below that. The later the entry in this
  /// list, the more it wins.
  static const List<String> _totalKeywords = <String>[
    'total',
    'total amount',
    'amount payable',
    'amount due',
    'balance due',
    'net payable',
    'net amount',
    'grand total',
    'to pay',
  ];

  /// Phrases that contain a total keyword but are not the payable figure.
  ///
  /// Without these, "Subtotal 450.00" and "Total Savings 50.00" are both read
  /// as the amount to charge the user.
  static const List<String> _totalDecoys = <String>[
    'subtotal',
    'sub total',
    'sub-total',
    'total savings',
    'total saving',
    'total discount',
    'total qty',
    'total quantity',
    'total items',
    'total item',
    'total tax',
    'tax total',
    'total gst',
    'total vat',
    'cash total',
    'card total',
    'you saved',
  ];

  /// Header noise that is never the shop's name.
  static const List<String> _merchantDecoys = <String>[
    'tax invoice',
    'invoice',
    'receipt',
    'bill of supply',
    'cash memo',
    'gstin',
    'gst no',
    'gst',
    'tin',
    'pan',
    'cin',
    'vat',
    'phone',
    'tel',
    'mobile',
    'www.',
    'http',
    '@',
    'order no',
    'order id',
    'bill no',
    'invoice no',
    'table no',
    'counter',
    'cashier',
    'terminal',
    'welcome to',
    'thank you',
  ];

  /// Words that mark a line as a summary or metadata row rather than a
  /// purchased item.
  ///
  /// The metadata entries earn their place: a bill number like
  /// `Bill No: 2024/0931` ends in something that parses perfectly well as an
  /// amount, so without them a reference number is listed as a purchase.
  static const List<String> _itemDecoys = <String>[
    'bill no',
    'bill number',
    'invoice',
    'order no',
    'order id',
    'receipt no',
    'ref no',
    'date',
    'time',
    'gstin',
    'tin no',
    'phone',
    'table no',
    'counter',
    'cashier',
    'total',
    'subtotal',
    'sub total',
    'tax',
    'gst',
    'cgst',
    'sgst',
    'igst',
    'vat',
    'cess',
    'discount',
    'savings',
    'change',
    'cash',
    'card',
    'upi',
    'tender',
    'balance',
    'round off',
    'rounding',
    'amount',
    'paid',
    'payable',
    'qty',
  ];

  /// Reads [lines] — one entry per recognised text line, top to bottom.
  ReceiptResult parse(List<String> lines) {
    final List<String> cleaned = <String>[
      for (final String line in lines)
        if (line.trim().isNotEmpty) _collapseSpaces(line),
    ];

    if (cleaned.isEmpty) return const ReceiptResult.unreadable();

    return ReceiptResult(
      merchant: _findMerchant(cleaned),
      total: _findTotal(cleaned),
      date: _findDate(cleaned),
      lineItems: _findLineItems(cleaned),
      rawLines: cleaned,
    );
  }

  /// Convenience for engines that hand back one blob rather than lines.
  ReceiptResult parseText(String text) => parse(text.split(RegExp(r'[\r\n]+')));

  // -------------------------------------------------------------------
  // Total
  // -------------------------------------------------------------------

  ReceiptField<double> _findTotal(List<String> lines) {
    double? best;
    int bestRank = -1;

    for (int i = 0; i < lines.length; i++) {
      final String lower = lines[i].toLowerCase();
      if (_containsAny(lower, _totalDecoys)) continue;

      final int rank = _totalRank(lower);
      if (rank < 0) continue;

      // The figure usually sits on the keyword's own line. When the line
      // holds only the label, receipts put the number immediately below it.
      double? amount = _lastAmountIn(lines[i]);
      amount ??= i + 1 < lines.length ? _lastAmountIn(lines[i + 1]) : null;
      if (amount == null || amount <= 0) continue;

      // A later keyword of equal rank wins: "Grand Total" is printed after
      // the running "Total" it supersedes.
      if (rank >= bestRank) {
        bestRank = rank;
        best = amount;
      }
    }

    if (best != null) return ReceiptField<double>(best, ReceiptConfidence.high);

    // No labelled total. The largest amount on a receipt is very often the
    // one being charged, but it is a guess and is marked as one.
    final List<double> all = <double>[
      for (final String line in lines)
        if (!_containsAny(line.toLowerCase(), _totalDecoys))
          ..._amountsIn(line),
    ];
    if (all.isEmpty) return const ReceiptField<double>.missing();

    all.sort();
    final double largest = all.last;
    return ReceiptField<double>(
      largest,
      all.length == 1 ? ReceiptConfidence.low : ReceiptConfidence.medium,
    );
  }

  /// Index into [_totalKeywords], or -1. Longer phrases outrank shorter ones.
  int _totalRank(String lower) {
    int rank = -1;
    for (int i = 0; i < _totalKeywords.length; i++) {
      if (lower.contains(_totalKeywords[i]) && i > rank) rank = i;
    }
    return rank;
  }

  // -------------------------------------------------------------------
  // Merchant
  // -------------------------------------------------------------------

  /// The shop name is almost always in the first few lines, above the
  /// address and the invoice metadata — so only the top of the receipt is
  /// considered, and anything that looks like metadata is skipped.
  ReceiptField<String> _findMerchant(List<String> lines) {
    final int window = lines.length < 6 ? lines.length : 6;

    String? firstPlausible;
    for (int i = 0; i < window; i++) {
      final String line = lines[i];
      if (!_couldBeMerchant(line)) continue;

      final String name = _titleiseIfShouting(line);
      // A shouting line near the very top is the classic receipt header.
      if (i < 3 && _isShouting(line)) {
        return ReceiptField<String>(name, ReceiptConfidence.high);
      }
      firstPlausible ??= name;
    }

    if (firstPlausible != null) {
      return ReceiptField<String>(firstPlausible, ReceiptConfidence.medium);
    }
    return const ReceiptField<String>.missing();
  }

  /// A price printed on the line — two decimal places after a digit.
  static final RegExp _pricePattern = RegExp(r'\d[.,]\d{2}(?!\d)');

  bool _couldBeMerchant(String line) {
    final String trimmed = line.trim();
    if (trimmed.length < 3 || trimmed.length > 40) return false;

    final String lower = trimmed.toLowerCase();
    if (_containsAny(lower, _merchantDecoys)) return false;

    // A line that states money is a total, an item or a tax row — never the
    // shop's name. Without this, a short receipt whose only readable line is
    // "TOTAL 240.00" puts that line in the merchant field.
    //
    // The test is a *priced* amount rather than any digit, so "7-Eleven" and
    // "Cafe 24" still read as names.
    if (_totalRank(lower) >= 0 ||
        _containsAny(lower, _totalDecoys) ||
        _pricePattern.hasMatch(trimmed)) {
      return false;
    }

    final int letters = _countWhere(trimmed, _isLetter);
    if (letters < 3) return false;

    // Mostly digits means an address, a phone number or a bill reference.
    final int digits = _countWhere(trimmed, _isDigit);
    if (digits > letters) return false;

    return true;
  }

  bool _isShouting(String line) {
    final int upper = _countWhere(line, (int c) => c >= 65 && c <= 90);
    final int lower = _countWhere(line, (int c) => c >= 97 && c <= 122);
    return upper >= 3 && upper > lower;
  }

  /// "SPAR HYPERMARKET" reads better as "Spar Hypermarket" in a form field,
  /// but a name that is already mixed case is left exactly as printed.
  String _titleiseIfShouting(String line) {
    final String trimmed = line.trim();
    if (!_isShouting(trimmed)) return trimmed;

    return trimmed
        .split(' ')
        .map((String word) => word.length <= 1
            ? word
            : '${word[0]}${word.substring(1).toLowerCase()}')
        .join(' ');
  }

  // -------------------------------------------------------------------
  // Date
  // -------------------------------------------------------------------

  /// 12/05/2024, 12-05-24, 2024-05-12, 12.05.2024
  static final RegExp _numericDate =
      RegExp(r'(\d{1,4})\s*[/\-.]\s*(\d{1,2})\s*[/\-.]\s*(\d{2,4})');

  /// 12 May 2024 / 12 May 24
  static final RegExp _dayMonthName = RegExp(
    r'(\d{1,2})\s*[-\s]\s*([A-Za-z]{3,9})\.?\s*[-,\s]\s*(\d{2,4})',
  );

  /// May 12, 2024
  static final RegExp _monthNameDay = RegExp(
    r'([A-Za-z]{3,9})\.?\s+(\d{1,2})\s*[-,\s]\s*(\d{2,4})',
  );

  static const Map<String, int> _months = <String, int>{
    'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
    'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
  };

  ReceiptField<DateTime> _findDate(List<String> lines) {
    for (final String line in lines) {
      final DateTime? parsed = _dateIn(line);
      if (parsed == null) continue;

      // A receipt cannot be from the future, and one more than five years old
      // is far more likely to be a misread than a real purchase date. Either
      // way the value is offered rather than dropped, so the user can keep it
      // if the scan was right.
      final DateTime now = DateTime.now();
      final DateTime tomorrow = DateTime(now.year, now.month, now.day + 1);
      final bool plausible = parsed.isBefore(tomorrow) &&
          parsed.isAfter(DateTime(now.year - 5, now.month, now.day));

      return ReceiptField<DateTime>(
        parsed,
        plausible ? ReceiptConfidence.high : ReceiptConfidence.low,
      );
    }
    return const ReceiptField<DateTime>.missing();
  }

  DateTime? _dateIn(String line) {
    final RegExpMatch? numeric = _numericDate.firstMatch(line);
    if (numeric != null) {
      final int a = int.parse(numeric.group(1)!);
      final int b = int.parse(numeric.group(2)!);
      final int c = int.parse(numeric.group(3)!);

      // yyyy-MM-dd
      if (a > 31) return _build(c, b, a);

      // Day and month are ambiguous in dd/MM vs MM/dd. A value above 12
      // settles it; otherwise day-first wins, which is the convention in the
      // locale this app formats for.
      if (a > 12) return _build(a, b, _expandYear(c));
      if (b > 12) return _build(b, a, _expandYear(c));
      return _build(a, b, _expandYear(c));
    }

    final RegExpMatch? dayFirst = _dayMonthName.firstMatch(line);
    if (dayFirst != null) {
      final int? month = _monthFrom(dayFirst.group(2)!);
      if (month != null) {
        return _build(
          int.parse(dayFirst.group(1)!),
          month,
          _expandYear(int.parse(dayFirst.group(3)!)),
        );
      }
    }

    final RegExpMatch? monthFirst = _monthNameDay.firstMatch(line);
    if (monthFirst != null) {
      final int? month = _monthFrom(monthFirst.group(1)!);
      if (month != null) {
        return _build(
          int.parse(monthFirst.group(2)!),
          month,
          _expandYear(int.parse(monthFirst.group(3)!)),
        );
      }
    }

    return null;
  }

  int? _monthFrom(String word) {
    final String key = word.toLowerCase();
    return key.length < 3 ? null : _months[key.substring(0, 3)];
  }

  /// Two-digit years on a receipt are always this century.
  int _expandYear(int year) => year < 100 ? 2000 + year : year;

  /// Returns null rather than rolling over, so "32/13/2024" is rejected
  /// instead of silently becoming 1 February 2025.
  DateTime? _build(int day, int month, int year) {
    if (month < 1 || month > 12) return null;
    if (day < 1 || day > 31) return null;
    if (year < 1990 || year > 2100) return null;

    final DateTime date = DateTime(year, month, day);
    if (date.day != day || date.month != month) return null;
    return date;
  }

  // -------------------------------------------------------------------
  // Line items
  // -------------------------------------------------------------------

  /// "2 x Flat White   7.00" — description, then a trailing amount.
  static final RegExp _quantityPrefix =
      RegExp(r'^(\d{1,3})\s*(?:x|X|\*)\s*(.+)$');

  List<ReceiptLineItem> _findLineItems(List<String> lines) {
    final List<ReceiptLineItem> items = <ReceiptLineItem>[];

    for (final String line in lines) {
      final String lower = line.toLowerCase();
      if (_containsAny(lower, _itemDecoys)) continue;

      final double? amount = _lastAmountIn(line);
      if (amount == null || amount <= 0) continue;

      // Everything before the trailing amount is the description.
      final String description =
          _stripTrailingAmount(line).replaceAll(RegExp(r'[.\-_·…]{2,}'), ' ');
      final String tidy = _collapseSpaces(description);
      if (_countWhere(tidy, _isLetter) < 3) continue;

      final RegExpMatch? quantity = _quantityPrefix.firstMatch(tidy);
      items.add(
        ReceiptLineItem(
          description: quantity == null
              ? tidy
              : _collapseSpaces(quantity.group(2)!),
          amount: amount,
          quantity:
              quantity == null ? null : int.tryParse(quantity.group(1)!),
        ),
      );
    }

    // A receipt with dozens of recognised "items" is almost always a layout
    // the parser has misread, and a wall of wrong rows is worse than none.
    return items.length > 30 ? const <ReceiptLineItem>[] : items;
  }

  // -------------------------------------------------------------------
  // Amounts
  // -------------------------------------------------------------------

  /// A run of digits with optional thousands groups and up to two decimals.
  /// Matches both 1,234.56 and the Indian 1,23,456.78 grouping.
  static final RegExp _amountToken =
      RegExp(r'\d{1,3}(?:,\d{2,3})+(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?');

  List<double> _amountsIn(String line) {
    // Strip date-shaped runs first: "12.05.2024" would otherwise yield 12.05.
    final String withoutDates = line
        .replaceAll(_numericDate, ' ')
        .replaceAll(RegExp(r'\d{1,2}:\d{2}(?::\d{2})?'), ' ');

    final List<double> found = <double>[];
    for (final RegExpMatch match in _amountToken.allMatches(withoutDates)) {
      final double? value = _toAmount(match.group(0)!);
      if (value != null) found.add(value);
    }
    return found;
  }

  double? _lastAmountIn(String line) {
    final List<double> amounts = _amountsIn(line);
    return amounts.isEmpty ? null : amounts.last;
  }

  String _stripTrailingAmount(String line) {
    final List<RegExpMatch> matches = _amountToken.allMatches(line).toList();
    if (matches.isEmpty) return line;
    return line.substring(0, matches.last.start);
  }

  double? _toAmount(String token) {
    final String digitsOnly = token.replaceAll(',', '');
    final double? value = double.tryParse(digitsOnly);
    if (value == null) return null;

    // A long run of digits with no decimal point is a phone number, a bill
    // reference or a GST id — not money.
    if (!token.contains('.') && digitsOnly.length >= 8) return null;
    if (value > 99999999) return null;

    return value;
  }

  // -------------------------------------------------------------------
  // Small helpers
  // -------------------------------------------------------------------

  static String _collapseSpaces(String value) =>
      value.replaceAll(RegExp(r'\s+'), ' ').trim();

  static bool _containsAny(String lower, List<String> needles) {
    for (final String needle in needles) {
      if (lower.contains(needle)) return true;
    }
    return false;
  }

  static int _countWhere(String value, bool Function(int) test) {
    int count = 0;
    for (final int unit in value.codeUnits) {
      if (test(unit)) count++;
    }
    return count;
  }

  static bool _isLetter(int c) =>
      (c >= 65 && c <= 90) || (c >= 97 && c <= 122);

  static bool _isDigit(int c) => c >= 48 && c <= 57;
}
