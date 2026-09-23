/// Renders an [ExportDataset] as CSV.
///
/// Pure Dart with no package dependency: the format is small enough that
/// owning it is cheaper than a dependency, and owning it is what allows the
/// two things below that a generic encoder would not do.
library;

import 'dart:convert';

import 'export_models.dart';

class CsvExportService implements ExportRenderer {
  const CsvExportService();

  @override
  ExportFormat get format => ExportFormat.csv;

  @override
  Future<List<int>> render(ExportDataset dataset) async =>
      utf8.encode(renderString(dataset));

  /// The synchronous form, which is what the tests assert against.
  String renderString(ExportDataset dataset) {
    final StringBuffer out = StringBuffer();

    // A short header block, so a CSV opened months later still says what it
    // is, what it covers and when it was taken.
    _row(out, <String>[dataset.title]);
    if (dataset.subtitle != null) _row(out, <String>[dataset.subtitle!]);
    _row(out, <String>['Period', dataset.periodLabel]);
    _row(out, <String>['Generated', _timestamp(dataset.generatedAt)]);

    if (dataset.summary.isNotEmpty) {
      out.writeln();
      for (final ExportSummaryItem item in dataset.summary) {
        _row(out, <String>[item.label, item.value]);
      }
    }

    for (final ExportSection section in dataset.sections) {
      out.writeln();
      _row(out, <String>[section.title]);
      if (section.note != null) _row(out, <String>[section.note!]);

      if (section.isEmpty) {
        _row(out, <String>[section.emptyMessage]);
        continue;
      }

      _row(
        out,
        <String>[for (final ExportColumn c in section.columns) c.label],
      );
      for (final List<ExportCell> row in section.rows) {
        _row(out, <String>[for (final ExportCell cell in row) _value(cell)]);
      }
      final List<ExportCell>? total = section.totalRow;
      if (total != null) {
        _row(out, <String>[for (final ExportCell cell in total) _value(cell)]);
      }
    }

    if (dataset.footnote != null) {
      out.writeln();
      _row(out, <String>[dataset.footnote!]);
    }

    return out.toString();
  }

  /// A money or count cell is written as a bare number.
  ///
  /// "₹1,234.56" in a spreadsheet is a string, and a column of strings cannot
  /// be summed — which is the main reason to export CSV at all. The formatted
  /// text stays in the PDF, where it is read rather than calculated with.
  String _value(ExportCell cell) {
    final num? raw = cell.raw;
    if (raw == null) return cell.text;

    return switch (cell.kind) {
      ExportCellKind.money => raw.toStringAsFixed(2),
      ExportCellKind.count => raw.toStringAsFixed(0),
      ExportCellKind.percent => raw.toStringAsFixed(4),
      ExportCellKind.text || ExportCellKind.date => cell.text,
    };
  }

  void _row(StringBuffer out, List<String> cells) {
    // CRLF: the line ending RFC 4180 specifies and the one Excel is happiest
    // with on the Windows machines these files usually land on.
    out.write(cells.map(_escape).join(','));
    out.write('\r\n');
  }

  /// Quotes per RFC 4180, and neutralises formula injection.
  ///
  /// A cell beginning `=`, `+`, `-`, `@` or a control character is executed as
  /// a formula by Excel, Sheets and LibreOffice on open. A merchant name is
  /// user-controlled text that lands in exactly such a cell, so it is prefixed
  /// with an apostrophe — which the spreadsheet strips on display, leaving the
  /// value readable but inert.
  ///
  /// The guard deliberately skips anything that is wholly a number. `-500.00`
  /// starts with a formula leader and is not an attack; prefixing it would
  /// turn the negative amounts in an export into text and break the sums the
  /// CSV exists to support.
  String _escape(String value) {
    String text = value.replaceAll('\r\n', ' ').replaceAll('\n', ' ');

    final bool risky = text.isNotEmpty &&
        _formulaLeaders.contains(text[0]) &&
        num.tryParse(text) == null;
    if (risky) text = "'$text";

    final bool needsQuotes = risky ||
        text.contains(',') ||
        text.contains('"') ||
        text.trim() != text;

    if (!needsQuotes) return text;
    return '"${text.replaceAll('"', '""')}"';
  }

  static const String _formulaLeaders = '=+-@\t\r';

  static String _timestamp(DateTime when) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${when.year}-${two(when.month)}-${two(when.day)} '
        '${two(when.hour)}:${two(when.minute)}';
  }
}
