/// The shape every export is described in, whatever it is rendered to.
///
/// A report is built once, as an [ExportDataset], and then handed to a
/// renderer. CSV and PDF therefore cannot disagree about what the numbers are
/// — they are the same numbers, formatted twice — and a third format later
/// means one more renderer rather than one more copy of the arithmetic.
///
/// Nothing here imports Flutter, Supabase or a rendering package, so every
/// figure in every report is unit-testable without a device.
library;

/// What a report is rendered to.
enum ExportFormat { csv, pdf }

extension ExportFormatMeta on ExportFormat {
  String get label => switch (this) {
        ExportFormat.csv => 'CSV',
        ExportFormat.pdf => 'PDF',
      };

  String get extension => switch (this) {
        ExportFormat.csv => 'csv',
        ExportFormat.pdf => 'pdf',
      };

  String get mimeType => switch (this) {
        ExportFormat.csv => 'text/csv',
        ExportFormat.pdf => 'application/pdf',
      };

  String get description => switch (this) {
        ExportFormat.csv => 'Open in Excel or Sheets',
        ExportFormat.pdf => 'Formatted for reading and printing',
      };
}

/// The six things a user can export.
enum ExportReportType {
  bankStatement,
  expenses,
  income,
  spendingReport,
  categoryReport,
  incomeVsExpense,
}

extension ExportReportTypeMeta on ExportReportType {
  String get label => switch (this) {
        ExportReportType.bankStatement => 'Bank statement',
        ExportReportType.expenses => 'Expenses',
        ExportReportType.income => 'Income',
        ExportReportType.spendingReport => 'Spending report',
        ExportReportType.categoryReport => 'Category breakdown',
        ExportReportType.incomeVsExpense => 'Income vs expense',
      };

  String get description => switch (this) {
        ExportReportType.bankStatement =>
          'One account, every movement, with a running balance',
        ExportReportType.expenses =>
          'Every expense with category, source and notes',
        ExportReportType.income => 'Every income entry with its source',
        ExportReportType.spendingReport =>
          'Totals by category, by source and by month',
        ExportReportType.categoryReport =>
          'Each category with its total, count and share',
        ExportReportType.incomeVsExpense =>
          'Money in, money out, and the monthly net',
      };

  /// Stem of the generated filename.
  String get fileStem => switch (this) {
        ExportReportType.bankStatement => 'bank_statement',
        ExportReportType.expenses => 'expenses',
        ExportReportType.income => 'income',
        ExportReportType.spendingReport => 'spending_report',
        ExportReportType.categoryReport => 'category_spending',
        ExportReportType.incomeVsExpense => 'income_vs_expense',
      };

  /// True for the one report that is about a single account.
  bool get needsAccount => this == ExportReportType.bankStatement;

  /// True where narrowing to particular categories is meaningful.
  bool get supportsCategoryFilter =>
      this == ExportReportType.expenses ||
      this == ExportReportType.spendingReport ||
      this == ExportReportType.categoryReport;
}

/// How a cell is aligned, which is really a statement about what it holds.
enum ExportAlign { left, right }

/// What a cell means, so a renderer can style it without re-parsing the text.
enum ExportCellKind { text, money, date, count, percent }

/// One column of a table.
class ExportColumn {
  const ExportColumn(
    this.label, {
    this.align = ExportAlign.left,
    this.width = 1,
  });

  /// Money and counts read right-aligned; everything else left.
  const ExportColumn.number(this.label, {this.width = 1})
      : align = ExportAlign.right;

  final String label;
  final ExportAlign align;

  /// Relative width, used by the PDF renderer to share the page out. CSV
  /// ignores it.
  final double width;
}

/// One cell: the text a human reads, plus the number a spreadsheet wants.
///
/// Keeping both matters. A PDF should show "₹1,234.56"; a CSV cell holding
/// that string is useless for a SUM, so CSV writes [raw] where there is one.
class ExportCell {
  const ExportCell(this.text, {this.kind = ExportCellKind.text, this.raw});

  const ExportCell.money(this.text, double amount)
      : kind = ExportCellKind.money,
        raw = amount;

  const ExportCell.count(this.text, int value)
      : kind = ExportCellKind.count,
        raw = value;

  const ExportCell.date(this.text)
      : kind = ExportCellKind.date,
        raw = null;

  /// Empty cell — a debit column on a credit row, for instance.
  const ExportCell.blank()
      : text = '',
        kind = ExportCellKind.text,
        raw = null;

  final String text;
  final ExportCellKind kind;
  final num? raw;

  bool get isBlank => text.isEmpty;
}

/// One table inside a report.
class ExportSection {
  const ExportSection({
    required this.title,
    required this.columns,
    required this.rows,
    this.note,
    this.totalRow,
    this.emptyMessage = 'Nothing in this period.',
  });

  final String title;

  /// One line of context under the heading — the account's opening balance,
  /// or what the filter narrowed the table to.
  final String? note;

  final List<ExportColumn> columns;
  final List<List<ExportCell>> rows;

  /// Rendered emphasised at the foot of the table.
  final List<ExportCell>? totalRow;

  final String emptyMessage;

  bool get isEmpty => rows.isEmpty;
}

/// A headline figure printed above the tables.
class ExportSummaryItem {
  const ExportSummaryItem(this.label, this.value, {this.emphasis = false});

  final String label;
  final String value;

  /// Marks the one figure the report is really about.
  final bool emphasis;
}

/// A complete report, ready to render.
class ExportDataset {
  ExportDataset({
    required this.title,
    required this.periodLabel,
    required this.sections,
    this.subtitle,
    this.summary = const <ExportSummaryItem>[],
    this.footnote,
    DateTime? generatedAt,
  }) : generatedAt = generatedAt ?? DateTime.now();

  final String title;

  /// "HDFC •••• 4821" for a statement, the filter description elsewhere.
  final String? subtitle;

  /// "1 – 30 September 2026".
  final String periodLabel;

  final List<ExportSummaryItem> summary;
  final List<ExportSection> sections;

  /// Printed small at the foot — currently used to state that transfers are
  /// excluded from spending figures.
  final String? footnote;

  final DateTime generatedAt;

  /// True when at least one table has something in it.
  ///
  /// A report with figures but no rows is still worth exporting; one with
  /// neither is what the UI calls an empty result.
  bool get hasRows => sections.any((ExportSection s) => !s.isEmpty);

  bool get isEmpty => !hasRows && summary.isEmpty;
}

/// A rendered file on disk, ready to share.
class ExportResult {
  const ExportResult({
    required this.path,
    required this.fileName,
    required this.format,
    required this.byteCount,
  });

  final String path;
  final String fileName;
  final ExportFormat format;
  final int byteCount;

  /// "12 KB" — shown on the success confirmation.
  String get readableSize {
    if (byteCount < 1024) return '$byteCount B';
    if (byteCount < 1024 * 1024) {
      return '${(byteCount / 1024).toStringAsFixed(0)} KB';
    }
    return '${(byteCount / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// Renders a dataset to bytes. One implementation per format.
abstract class ExportRenderer {
  ExportFormat get format;

  /// Synchronous where it can be; PDF layout is not.
  Future<List<int>> render(ExportDataset dataset);
}

/// An inclusive day range.
///
/// Inclusive at both ends because that is what the user picks — "1 to 30
/// September", not "1 September up to but excluding 1 October". The exclusive
/// bound the queries need is derived, in one place, by [endExclusive].
class ExportDateRange {
  ExportDateRange(DateTime start, DateTime endInclusive)
      : start = DateTime(start.year, start.month, start.day),
        endInclusive =
            DateTime(endInclusive.year, endInclusive.month, endInclusive.day);

  /// The calendar month containing [anchor].
  factory ExportDateRange.month(DateTime anchor) {
    final DateTime start = DateTime(anchor.year, anchor.month, 1);
    return ExportDateRange(start, DateTime(anchor.year, anchor.month + 1, 0));
  }

  /// The last [days] days, ending today.
  factory ExportDateRange.lastDays(int days, {DateTime? now}) {
    final DateTime today = now ?? DateTime.now();
    final DateTime end = DateTime(today.year, today.month, today.day);
    return ExportDateRange(end.subtract(Duration(days: days - 1)), end);
  }

  /// The calendar year containing [anchor].
  factory ExportDateRange.year(DateTime anchor) =>
      ExportDateRange(DateTime(anchor.year, 1, 1), DateTime(anchor.year, 12, 31));

  final DateTime start;
  final DateTime endInclusive;

  /// The exclusive upper bound every range query uses.
  DateTime get endExclusive => endInclusive.add(const Duration(days: 1));

  bool get isValid => !endInclusive.isBefore(start);

  int get dayCount => endInclusive.difference(start).inDays + 1;

  /// True when the range is exactly one whole calendar month, which is what
  /// lets the filename collapse to `2026-09` instead of a pair of dates.
  bool get isWholeMonth {
    if (start.day != 1) return false;
    final DateTime lastOfMonth = DateTime(start.year, start.month + 1, 0);
    return endInclusive.year == lastOfMonth.year &&
        endInclusive.month == lastOfMonth.month &&
        endInclusive.day == lastOfMonth.day;
  }

  /// The period token used in filenames.
  String get fileToken => isWholeMonth
      ? '${start.year}-${_two(start.month)}'
      : '${_iso(start)}_to_${_iso(endInclusive)}';

  bool contains(DateTime date) {
    final DateTime day = DateTime(date.year, date.month, date.day);
    return !day.isBefore(start) && !day.isAfter(endInclusive);
  }

  static String _iso(DateTime d) =>
      '${d.year}-${_two(d.month)}-${_two(d.day)}';

  static String _two(int value) => value.toString().padLeft(2, '0');

  @override
  bool operator ==(Object other) =>
      other is ExportDateRange &&
      other.start == start &&
      other.endInclusive == endInclusive;

  @override
  int get hashCode => Object.hash(start, endInclusive);
}

/// Everything the user chose on the export screen.
class ExportRequest {
  const ExportRequest({
    required this.type,
    required this.range,
    required this.format,
    this.accountId,
    this.categoryIds = const <String>{},
  });

  final ExportReportType type;
  final ExportDateRange range;
  final ExportFormat format;

  /// Required for [ExportReportType.bankStatement], ignored otherwise.
  final String? accountId;

  /// Empty means every category.
  final Set<String> categoryIds;

  /// True when the choices are complete enough to run.
  bool get isRunnable =>
      range.isValid && (!type.needsAccount || accountId != null);

  ExportRequest copyWith({
    ExportReportType? type,
    ExportDateRange? range,
    ExportFormat? format,
    String? accountId,
    Set<String>? categoryIds,
    bool clearAccount = false,
  }) {
    return ExportRequest(
      type: type ?? this.type,
      range: range ?? this.range,
      format: format ?? this.format,
      accountId: clearAccount ? null : (accountId ?? this.accountId),
      categoryIds: categoryIds ?? this.categoryIds,
    );
  }
}
