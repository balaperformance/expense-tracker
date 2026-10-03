/// On-device receipt scanning with ML Kit text recognition.
///
/// Everything happens on the phone: the image is never uploaded, and there is
/// no API key to leak because there is no service to call. That is the reason
/// this engine was chosen over a cloud OCR provider for the default build.
///
/// The picked image is a throwaway. `image_picker` copies it into the app's
/// own cache directory, this class reads it once and then deletes that copy,
/// so scanning a receipt leaves nothing behind — matching the rule that the
/// app stores no receipt images.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';

import 'receipt_parser.dart';
import 'receipt_result.dart';
import 'receipt_scanner_service.dart';

class MlKitReceiptScanner implements ReceiptScannerService {
  MlKitReceiptScanner({
    ImagePicker? picker,
    TextRecognizer? recognizer,
    ReceiptParser parser = const ReceiptParser(),
  })  : _picker = picker ?? ImagePicker(),
        _recognizer =
            recognizer ?? TextRecognizer(script: TextRecognitionScript.latin),
        _parser = parser;

  final ImagePicker _picker;
  final TextRecognizer _recognizer;
  final ReceiptParser _parser;

  /// ML Kit ships for Android and iOS only.
  @override
  bool get isAvailable => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  @override
  Future<ReceiptScanOutcome> scan(ReceiptImageSource source) async {
    XFile? picked;
    try {
      picked = await _picker.pickImage(
        source: source == ReceiptImageSource.camera
            ? ImageSource.camera
            : ImageSource.gallery,
        // Receipts are long and thin and OCR needs the detail, so the image is
        // capped generously rather than tightly. Below roughly this size the
        // small print stops resolving.
        maxWidth: 2000,
        maxHeight: 2600,
        imageQuality: 92,
      );
    } on Exception catch (error) {
      return ReceiptScanFailed(_classify(error));
    }

    if (picked == null) {
      return const ReceiptScanFailed(ReceiptScanProblem.cancelled);
    }

    try {
      final RecognizedText recognised =
          await _recognizer.processImage(InputImage.fromFilePath(picked.path));

      final List<String> lines = _readingOrder(recognised);
      if (lines.isEmpty) {
        return const ReceiptScanFailed(ReceiptScanProblem.unreadable);
      }

      final ReceiptResult result = _parser.parse(lines);
      if (result.isEmpty) {
        return const ReceiptScanFailed(ReceiptScanProblem.unreadable);
      }
      return ReceiptScanned(result);
    } on Exception catch (error) {
      return ReceiptScanFailed(_classify(error));
    } finally {
      await _discard(picked);
    }
  }

  /// Flattens ML Kit's blocks into one top-to-bottom list of lines.
  ///
  /// Block order follows the recogniser's own layout analysis, which on a
  /// multi-column receipt can interleave the item names and their prices.
  /// Sorting every line by its vertical position instead reconstructs the
  /// order the receipt was printed in, which is the order the parser's
  /// "amount on the next line" and "merchant at the top" rules assume.
  List<String> _readingOrder(RecognizedText recognised) {
    final List<TextLine> all = <TextLine>[
      for (final TextBlock block in recognised.blocks) ...block.lines,
    ];

    all.sort((TextLine a, TextLine b) {
      // Lines printed side by side — an item name and its price — have
      // near-identical tops, so they are ordered left to right instead.
      final double drop = a.boundingBox.top - b.boundingBox.top;
      if (drop.abs() > _sameRowSlack) return drop < 0 ? -1 : 1;
      return a.boundingBox.left.compareTo(b.boundingBox.left);
    });

    return <String>[
      for (final TextLine line in all)
        if (line.text.trim().isNotEmpty) line.text.trim(),
    ];
  }

  /// Two lines whose tops are within this many pixels are treated as one row.
  static const double _sameRowSlack = 12;

  /// Removes the picker's cached copy of the image.
  ///
  /// Best effort on purpose: a receipt that scanned correctly must not fail
  /// because a temp file could not be unlinked.
  Future<void> _discard(XFile file) async {
    try {
      final File cached = File(file.path);
      if (await cached.exists()) await cached.delete();
    } on Exception {
      // Nothing useful to do, and nothing sensitive to log.
    }
  }

  /// Maps a plugin error onto a user-facing problem.
  ///
  /// The message is matched rather than the exception type because
  /// `image_picker` reports a refused permission as a generic
  /// `PlatformException` carrying a code, and there is no typed exception to
  /// catch. A denied permission is worth separating out because it is the one
  /// failure the user can actually fix.
  ReceiptScanProblem _classify(Exception error) {
    final String text = error.toString().toLowerCase();
    final bool denied = text.contains('permission') ||
        text.contains('denied') ||
        text.contains('photo_access') ||
        text.contains('camera_access');
    return denied
        ? ReceiptScanProblem.permissionDenied
        : ReceiptScanProblem.engineFailure;
  }

  @override
  Future<void> dispose() => _recognizer.close();
}

