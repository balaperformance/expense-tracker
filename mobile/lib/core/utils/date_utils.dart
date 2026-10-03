/// Month/day helpers. Kept free of Flutter imports for testability.
library;

class MonthRange {
  const MonthRange(this.start, this.endExclusive);

  /// First day of the month at 00:00 local time.
  final DateTime start;

  /// First day of the following month (exclusive upper bound).
  final DateTime endExclusive;

  /// Inclusive last day, useful for `lte` style date filters.
  DateTime get endInclusive => endExclusive.subtract(const Duration(days: 1));

  int get year => start.year;
  int get month => start.month;
}

class AppDateUtils {
  const AppDateUtils._();

  static DateTime today() {
    final DateTime now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  static DateTime firstDayOf(DateTime date) =>
      DateTime(date.year, date.month, 1);

  static MonthRange monthRange(DateTime anchor) {
    final DateTime start = DateTime(anchor.year, anchor.month, 1);
    final DateTime end = anchor.month == 12
        ? DateTime(anchor.year + 1, 1, 1)
        : DateTime(anchor.year, anchor.month + 1, 1);
    return MonthRange(start, end);
  }

  static MonthRange currentMonth() => monthRange(DateTime.now());

  static DateTime addMonths(DateTime anchor, int delta) {
    final int zeroBased = anchor.month - 1 + delta;
    final int year = anchor.year + (zeroBased / 12).floor();
    final int month = zeroBased % 12 + 1;
    return DateTime(year, month, 1);
  }

  /// The last [count] months ending with [anchor], oldest first.
  static List<DateTime> trailingMonths(DateTime anchor, int count) {
    return List<DateTime>.generate(
      count,
      (int i) => addMonths(firstDayOf(anchor), i - (count - 1)),
    );
  }

  /// `yyyy-MM-dd` — the wire format for Postgres `date` columns.
  static String toDateString(DateTime date) {
    final String m = date.month.toString().padLeft(2, '0');
    final String d = date.day.toString().padLeft(2, '0');
    return '${date.year}-$m-$d';
  }

  static DateTime parseDate(String value) {
    final DateTime parsed = DateTime.parse(value);
    return DateTime(parsed.year, parsed.month, parsed.day);
  }

  static bool isSameMonth(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month;
}
