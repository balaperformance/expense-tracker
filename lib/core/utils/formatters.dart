/// Display formatting for money and dates.
library;

import 'package:intl/intl.dart';

import '../constants/app_constants.dart';

class Formatters {
  const Formatters._();

  static final DateFormat _dayMonth = DateFormat('d MMM');
  static final DateFormat _dayMonthYear = DateFormat('d MMM yyyy');
  static final DateFormat _monthYear = DateFormat('MMMM yyyy');
  static final DateFormat _shortMonth = DateFormat('MMM');
  static final DateFormat _weekday = DateFormat('EEEE');

  static String currency(
    num amount, {
    String currencyCode = AppConstants.defaultCurrencyCode,
    bool compact = false,
  }) {
    final String symbol = AppConstants.symbolFor(currencyCode);
    if (compact && amount.abs() >= 1000) {
      return '$symbol${_compact(amount)}';
    }
    final NumberFormat format = NumberFormat.currency(
      symbol: symbol,
      decimalDigits: 2,
      locale: currencyCode == 'INR' ? 'en_IN' : 'en_US',
    );
    return format.format(amount);
  }

  static String _compact(num amount) {
    final double abs = amount.abs().toDouble();
    final String sign = amount < 0 ? '-' : '';
    if (abs >= 10000000) {
      return '$sign${(abs / 10000000).toStringAsFixed(2)}Cr';
    }
    if (abs >= 100000) {
      return '$sign${(abs / 100000).toStringAsFixed(2)}L';
    }
    return '$sign${(abs / 1000).toStringAsFixed(1)}K';
  }

  static String dayMonth(DateTime date) => _dayMonth.format(date);

  static String dayMonthYear(DateTime date) => _dayMonthYear.format(date);

  static String monthYear(DateTime date) => _monthYear.format(date);

  static String shortMonth(DateTime date) => _shortMonth.format(date);

  /// "Today" / "Yesterday" / "Monday" / "12 Mar 2025" depending on recency.
  static String relativeDay(DateTime date) {
    final DateTime today = DateTime.now();
    final DateTime d = DateTime(date.year, date.month, date.day);
    final DateTime t = DateTime(today.year, today.month, today.day);
    final int diff = t.difference(d).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    if (diff > 1 && diff < 7) return _weekday.format(date);
    if (d.year == t.year) return _dayMonth.format(date);
    return _dayMonthYear.format(date);
  }

  static String percent(double ratio) =>
      '${(ratio * 100).clamp(0, 999).toStringAsFixed(0)}%';

  /// Time-of-day greeting for the dashboard header.
  static String greeting([DateTime? now]) {
    final int hour = (now ?? DateTime.now()).hour;
    if (hour < 12) return 'Good morning';
    if (hour < 17) return 'Good afternoon';
    return 'Good evening';
  }
}
