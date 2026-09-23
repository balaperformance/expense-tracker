/// Renders an [ExportDataset] as a PDF.
///
/// Laid out to be read and filed: a masthead, the headline figures, then one
/// table per section, with a repeating header row and page numbers so a long
/// statement survives being printed.
///
/// Uses only the `pdf` package, which is pure Dart — the same code produces
/// the same bytes on Android, iOS and in a unit test, so the PDF is testable
/// without a device.
library;

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'export_models.dart';

class PdfExportService implements ExportRenderer {
  const PdfExportService();

  @override
  ExportFormat get format => ExportFormat.pdf;

  // A restrained, print-safe palette. Deliberately not the app's theme
  // colours: a document is read on paper and on other people's screens, where
  // the app's dark-mode surfaces mean nothing.
  static const PdfColor _ink = PdfColor.fromInt(0xFF1A1C1E);
  static const PdfColor _muted = PdfColor.fromInt(0xFF6B7280);
  static const PdfColor _rule = PdfColor.fromInt(0xFFD9DDE3);
  static const PdfColor _band = PdfColor.fromInt(0xFFF2F4F7);
  static const PdfColor _accent = PdfColor.fromInt(0xFF3B4CCA);

  @override
  Future<List<int>> render(ExportDataset dataset) async {
    final pw.Document document = pw.Document(
      title: dataset.title,
      // No author, no creator string: nothing identifying the user is written
      // into the file's metadata.
      producer: 'Expense Tracker',
    );

    document.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(32, 32, 32, 36),
        // A year of daily movements is a long document, and the default cap
        // of 20 pages would reject it outright rather than truncating it.
        maxPages: 200,
        header: (pw.Context context) =>
            context.pageNumber == 1 ? pw.SizedBox() : _runningHeader(dataset),
        footer: _footer,
        build: (pw.Context context) => <pw.Widget>[
          _masthead(dataset),
          if (dataset.summary.isNotEmpty) ...<pw.Widget>[
            pw.SizedBox(height: 16),
            _summaryStrip(dataset.summary),
          ],
          for (final ExportSection section in dataset.sections)
            ..._section(section),
          if (dataset.footnote != null) ...<pw.Widget>[
            pw.SizedBox(height: 22),
            _footnote(dataset.footnote!),
          ],
        ],
      ),
    );

    return document.save();
  }

  // -------------------------------------------------------------------

  pw.Widget _masthead(ExportDataset dataset) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: <pw.Widget>[
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: <pw.Widget>[
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: <pw.Widget>[
                  pw.Text(
                    printable(dataset.title),
                    style: pw.TextStyle(
                      fontSize: 20,
                      fontWeight: pw.FontWeight.bold,
                      color: _ink,
                    ),
                  ),
                  if (dataset.subtitle != null) ...<pw.Widget>[
                    pw.SizedBox(height: 3),
                    pw.Text(
                      printable(dataset.subtitle!),
                      style: const pw.TextStyle(fontSize: 10, color: _muted),
                    ),
                  ],
                ],
              ),
            ),
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: <pw.Widget>[
                pw.Text(
                  printable(dataset.periodLabel),
                  style: pw.TextStyle(
                    fontSize: 11,
                    fontWeight: pw.FontWeight.bold,
                    color: _accent,
                  ),
                ),
                pw.SizedBox(height: 3),
                pw.Text(
                  'Generated ${_timestamp(dataset.generatedAt)}',
                  style: const pw.TextStyle(fontSize: 8, color: _muted),
                ),
              ],
            ),
          ],
        ),
        pw.SizedBox(height: 10),
        pw.Divider(color: _rule, thickness: 0.8, height: 1),
      ],
    );
  }

  pw.Widget _runningHeader(ExportDataset dataset) {
    return pw.Container(
      margin: const pw.EdgeInsets.only(bottom: 12),
      padding: const pw.EdgeInsets.only(bottom: 6),
      decoration: const pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(color: _rule, width: 0.8)),
      ),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: <pw.Widget>[
          pw.Text(
            printable(
              dataset.subtitle == null
                  ? dataset.title
                  : '${dataset.title} — ${dataset.subtitle}',
            ),
            style: const pw.TextStyle(fontSize: 9, color: _muted),
          ),
          pw.Text(
            printable(dataset.periodLabel),
            style: const pw.TextStyle(fontSize: 9, color: _muted),
          ),
        ],
      ),
    );
  }

  pw.Widget _footer(pw.Context context) {
    return pw.Container(
      alignment: pw.Alignment.centerRight,
      margin: const pw.EdgeInsets.only(top: 8),
      child: pw.Text(
        'Page ${context.pageNumber} of ${context.pagesCount}',
        style: const pw.TextStyle(fontSize: 8, color: _muted),
      ),
    );
  }

  /// The headline figures, as a row of tiles that wraps on a narrow page.
  pw.Widget _summaryStrip(List<ExportSummaryItem> items) {
    return pw.Wrap(
      spacing: 10,
      runSpacing: 10,
      children: <pw.Widget>[
        for (final ExportSummaryItem item in items)
          pw.Container(
            width: 122,
            padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: pw.BoxDecoration(
              color: item.emphasis ? _band : null,
              border: pw.Border.all(color: _rule, width: 0.8),
              borderRadius: pw.BorderRadius.circular(5),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: <pw.Widget>[
                pw.Text(
                  printable(item.label.toUpperCase()),
                  style: const pw.TextStyle(fontSize: 7, color: _muted),
                ),
                pw.SizedBox(height: 3),
                pw.Text(
                  printable(item.value),
                  style: pw.TextStyle(
                    fontSize: item.emphasis ? 13 : 11,
                    fontWeight: pw.FontWeight.bold,
                    color: item.emphasis ? _accent : _ink,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// Returns the section's widgets flat rather than wrapped in a Column.
  ///
  /// This is load-bearing. `MultiPage` can only split a widget across pages
  /// when that widget is a direct child of its `build` list, and a `Column` is
  /// not splittable. Nesting the table inside one made a 120-row statement
  /// fail to lay out at all — `MultiPage` kept adding pages without making
  /// progress until it gave up with `TooManyPagesException`. Flat, the table
  /// spans as many pages as it needs.
  List<pw.Widget> _section(ExportSection section) {
    return <pw.Widget>[
      pw.SizedBox(height: 20),
      pw.Text(
        printable(section.title),
        style: pw.TextStyle(
          fontSize: 12,
          fontWeight: pw.FontWeight.bold,
          color: _ink,
        ),
      ),
      if (section.note != null) ...<pw.Widget>[
        pw.SizedBox(height: 2),
        pw.Text(
          printable(section.note!),
          style: const pw.TextStyle(fontSize: 8.5, color: _muted),
        ),
      ],
      pw.SizedBox(height: 6),
      if (section.isEmpty)
        pw.Container(
          width: double.infinity,
          padding: const pw.EdgeInsets.symmetric(vertical: 14),
          alignment: pw.Alignment.center,
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: _rule, width: 0.8),
            borderRadius: pw.BorderRadius.circular(5),
          ),
          child: pw.Text(
            printable(section.emptyMessage),
            style: const pw.TextStyle(fontSize: 9, color: _muted),
          ),
        )
      else
        _table(section),
    ];
  }

  pw.Widget _table(ExportSection section) {
    final Map<int, pw.TableColumnWidth> widths = <int, pw.TableColumnWidth>{
      for (int i = 0; i < section.columns.length; i++)
        i: pw.FlexColumnWidth(section.columns[i].width),
    };

    return pw.Table(
      columnWidths: widths,
      border: const pw.TableBorder(
        horizontalInside: pw.BorderSide(color: _rule, width: 0.5),
        bottom: pw.BorderSide(color: _rule, width: 0.5),
      ),
      children: <pw.TableRow>[
        pw.TableRow(
          // Repeated at the top of every page the table spills onto.
          repeat: true,
          decoration: const pw.BoxDecoration(color: _band),
          children: <pw.Widget>[
            for (final ExportColumn column in section.columns)
              _cell(
                column.label,
                column.align,
                bold: true,
                size: 8.5,
                color: _muted,
              ),
          ],
        ),
        for (final List<ExportCell> row in section.rows)
          pw.TableRow(
            children: <pw.Widget>[
              for (int i = 0; i < section.columns.length; i++)
                _cell(
                  i < row.length ? row[i].text : '',
                  section.columns[i].align,
                ),
            ],
          ),
        if (section.totalRow != null)
          pw.TableRow(
            decoration: const pw.BoxDecoration(
              border: pw.Border(top: pw.BorderSide(color: _ink, width: 0.9)),
            ),
            children: <pw.Widget>[
              for (int i = 0; i < section.columns.length; i++)
                _cell(
                  i < section.totalRow!.length ? section.totalRow![i].text : '',
                  section.columns[i].align,
                  bold: true,
                ),
            ],
          ),
      ],
    );
  }

  pw.Widget _cell(
    String text,
    ExportAlign align, {
    bool bold = false,
    double size = 9,
    PdfColor color = _ink,
  }) {
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4.5),
      alignment: align == ExportAlign.right
          ? pw.Alignment.centerRight
          : pw.Alignment.centerLeft,
      child: pw.Text(
        printable(text),
        textAlign:
            align == ExportAlign.right ? pw.TextAlign.right : pw.TextAlign.left,
        style: pw.TextStyle(
          fontSize: size,
          color: color,
          fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
        ),
      ),
    );
  }

  pw.Widget _footnote(String text) {
    return pw.Container(
      padding: const pw.EdgeInsets.all(9),
      decoration: pw.BoxDecoration(
        color: _band,
        borderRadius: pw.BorderRadius.circular(5),
      ),
      child: pw.Text(
        printable(text),
        style: const pw.TextStyle(fontSize: 8, color: _muted),
      ),
    );
  }

  static String _timestamp(DateTime when) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(when.day)}/${two(when.month)}/${when.year} '
        '${two(when.hour)}:${two(when.minute)}';
  }

  // -------------------------------------------------------------------
  // Glyph safety
  // -------------------------------------------------------------------

  /// Makes a string safe for the PDF's built-in Helvetica.
  ///
  /// dart_pdf's standard fonts cover Latin-1 and nothing beyond it. Anything
  /// outside that draws as a hole in the page — which on a financial document
  /// reads as a missing amount, not as a missing glyph. Rather than ship a
  /// ~500 KB Unicode font, the handful of characters this app can actually
  /// emit above U+00FF are spelled out in ASCII.
  ///
  /// The list is not theoretical. `₹` comes from the currency formatter, `•`
  /// from a masked account number, `—` and `–` from the report headings, and
  /// curly quotes from typed merchant names and notes.
  ///
  /// Substitution is visible and correct; a blank is neither. If full Unicode
  /// is wanted later — Arabic currency, a Devanagari merchant name — the
  /// change is to register a TTF on the document and delete this method.
  static String printable(String text) {
    String work = text;
    for (final MapEntry<String, String> entry in _substitutions.entries) {
      work = work.replaceAll(entry.key, entry.value);
    }

    final StringBuffer out = StringBuffer();
    for (final int rune in work.runes) {
      if (rune <= 0xFF) {
        out.writeCharCode(rune);
      } else {
        // Unrepresentable and unmapped. A space keeps the surrounding words
        // apart instead of running them together.
        out.write(' ');
      }
    }
    return out.toString();
  }

  /// Characters above Latin-1 this app emits, and their ASCII stand-ins.
  ///
  /// Ordered so the multi-character Arabic cluster is matched before its
  /// individual letters could be dropped.
  static const Map<String, String> _substitutions = <String, String>{
    'د.إ': 'AED ', // د.إ
    '₹': 'Rs ', // ₹
    '₨': 'Rs ', // ₨
    '€': 'EUR ', // €
    '•': '*', // • — masked account digits
    '—': '-', // —
    '–': '-', // –
    '…': '...', // …
    '‘': "'", // ‘
    '’': "'", // ’
    '“': '"', // “
    '”': '"', // ”
  };
}
