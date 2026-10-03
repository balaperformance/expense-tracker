/// Turns a built [ExportDataset] into a file the user can keep.
///
/// The renderers decide what a report looks like; this class decides what it
/// is called, where it is written and how it leaves the app. Splitting it that
/// way is what lets a third format be added by writing one more
/// [ExportRenderer] and changing nothing here.
library;

import 'dart:io';
import 'dart:ui' show Rect;

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/errors/app_exception.dart';
import 'csv_export_service.dart';
import 'export_models.dart';
import 'pdf_export_service.dart';

class ExportService {
  ExportService({
    CsvExportService csv = const CsvExportService(),
    PdfExportService pdf = const PdfExportService(),
  }) : _renderers = <ExportFormat, ExportRenderer>{
          ExportFormat.csv: csv,
          ExportFormat.pdf: pdf,
        };

  final Map<ExportFormat, ExportRenderer> _renderers;

  /// Subdirectory of the app's own cache. Exports are disposable copies of
  /// data that already lives in the database, so they belong in cache rather
  /// than in documents, where the OS would back them up.
  static const String _folder = 'exports';

  /// Files older than this are removed the next time anything is exported.
  ///
  /// The share sheet may hand the file to another app asynchronously, so it
  /// cannot be deleted immediately after sharing — but leaving a growing pile
  /// of financial reports in the cache is not acceptable either. A day is long
  /// enough for any share to complete.
  static const Duration _keepFor = Duration(hours: 24);

  /// Renders [dataset] and writes it to a private cache file.
  Future<ExportResult> write({
    required ExportDataset dataset,
    required ExportFormat format,
    required String fileName,
  }) async {
    final ExportRenderer? renderer = _renderers[format];
    if (renderer == null) {
      throw AppException('No renderer is registered for ${format.label}.');
    }

    try {
      final List<int> bytes = await renderer.render(dataset);

      final Directory directory = await _exportDirectory();
      await _prune(directory);

      final File file = File('${directory.path}${Platform.pathSeparator}$fileName');
      await file.writeAsBytes(bytes, flush: true);

      return ExportResult(
        path: file.path,
        fileName: fileName,
        format: format,
        byteCount: bytes.length,
      );
    } on AppException {
      rethrow;
    } catch (error) {
      throw AppException(
        'Could not create the ${format.label} file. Check that there is '
        'free space on the device and try again.',
      );
    }
  }

  /// Hands the file to the OS share sheet.
  ///
  /// [origin] is the rectangle the sheet should point at, which iPad requires
  /// for the popover and every other platform ignores.
  Future<void> share(ExportResult result, {Rect? origin}) async {
    try {
      await Share.shareXFiles(
        <XFile>[
          XFile(result.path, mimeType: result.format.mimeType, name: result.fileName),
        ],
        subject: result.fileName,
        sharePositionOrigin: origin,
      );
    } catch (error) {
      throw AppException(
        'Could not open the share sheet. The file is saved as '
        '${result.fileName}.',
      );
    }
  }

  Future<Directory> _exportDirectory() async {
    final Directory base = await getTemporaryDirectory();
    final Directory directory =
        Directory('${base.path}${Platform.pathSeparator}$_folder');
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  /// Best effort: a failed cleanup must never fail the export the user asked
  /// for.
  Future<void> _prune(Directory directory) async {
    try {
      final DateTime cutoff = DateTime.now().subtract(_keepFor);
      await for (final FileSystemEntity entity in directory.list()) {
        if (entity is! File) continue;
        final FileStat stat = await entity.stat();
        if (stat.modified.isBefore(cutoff)) await entity.delete();
      }
    } catch (_) {
      // Nothing actionable, and nothing sensitive to report.
    }
  }

  // -------------------------------------------------------------------
  // Filenames
  // -------------------------------------------------------------------

  /// Builds a filename that says what the file is without being opened.
  ///
  /// `bank_statement_hdfc_2026-09.csv`, `spending_report_2026-09.pdf`,
  /// `expenses_2026-09-01_to_2026-09-14.csv`. A whole calendar month collapses
  /// to `yyyy-MM`; anything else spells both ends out, because "September" for
  /// a report covering three days of it would be a lie.
  static String fileNameFor({
    required ExportReportType type,
    required ExportDateRange range,
    required ExportFormat format,
    String? qualifier,
  }) {
    final String slug = qualifier == null ? '' : '_${slugify(qualifier)}';
    return '${type.fileStem}$slug'
        '_${range.fileToken}.${format.extension}';
  }

  /// Lowercases, keeps letters and digits, and collapses everything else to a
  /// single underscore.
  ///
  /// Filenames travel through share sheets, email attachments and other
  /// people's filesystems, so anything that is not plainly safe is removed
  /// rather than escaped. A name that reduces to nothing — an account
  /// nicknamed in a non-Latin script, say — yields an empty string, and the
  /// caller's filename simply omits that part.
  static String slugify(String value) {
    final String lowered = value.toLowerCase();
    final StringBuffer out = StringBuffer();
    bool pendingSeparator = false;

    for (final int unit in lowered.codeUnits) {
      final bool keep = (unit >= 97 && unit <= 122) || (unit >= 48 && unit <= 57);
      if (keep) {
        if (pendingSeparator && out.isNotEmpty) out.write('_');
        pendingSeparator = false;
        out.writeCharCode(unit);
      } else {
        pendingSeparator = true;
      }
    }

    final String slug = out.toString();
    // Long enough to identify an account, short enough not to produce an
    // unwieldy filename.
    return slug.length <= 24 ? slug : slug.substring(0, 24);
  }
}
