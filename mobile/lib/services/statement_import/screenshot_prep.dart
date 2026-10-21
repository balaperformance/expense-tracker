import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

/// Readies a card statement screenshot for ML Kit — the phone's counterpart
/// of `prepareScreenshot` in the web app's ocr.ts.
///
/// Screenshots shared through a chat app arrive at ~600px wide, where the
/// small grey detail line ("emi", "1 Oct") is too small and faint to be read.
/// The image is scaled to [_width], greyed (a dark-mode one inverted) and its
/// contrast stretched from the page's own background, so captions and green
/// or red amounts become near-black.
///
/// The prepared copy is written to the app's temporary folder only because
/// ML Kit reads from a file; [read] deletes it as soon as [recognise] returns.
class ScreenshotPrep {
  const ScreenshotPrep._();

  static const int _width = 1280;
  static const int _maxPixels = 12000000;
  static const int _inkDepth = 120;

  /// Runs [recognise] on a prepared copy of [bytes], or on [originalPath]
  /// when the image cannot be decoded.
  static Future<T> read<T>(
    Uint8List bytes,
    String originalPath,
    Future<T> Function(String path) recognise,
  ) async {
    final Uint8List? prepared = await compute(_prepare, bytes);
    if (prepared == null) return recognise(originalPath);
    final Directory dir = await getTemporaryDirectory();
    final File file = File(
      '${dir.path}/card_shot_${DateTime.now().microsecondsSinceEpoch}.png',
    );
    try {
      await file.writeAsBytes(prepared, flush: true);
      return await recognise(file.path);
    } finally {
      try {
        if (await file.exists()) await file.delete();
      } on Exception {
        // Best effort, as with the picker's own copy.
      }
    }
  }

  static Uint8List? _prepare(Uint8List bytes) {
    final img.Image? read = img.decodeImage(bytes);
    if (read == null || read.width == 0 || read.height == 0) return null;
    // Plain 8-bit RGB, whatever the source (a palette PNG, 16-bit, alpha).
    final img.Image decoded = read.convert(format: img.Format.uint8, numChannels: 3);
    final double fit = _width / decoded.width;
    final double cap = math.sqrt(_maxPixels / (decoded.width * decoded.height));
    final double scale = <double>[3, fit, cap].reduce((a, b) => a < b ? a : b);
    img.Image image = (scale - 1).abs() < 0.05
        ? decoded
        : img.copyResize(
            decoded,
            width: (decoded.width * scale).round(),
            height: (decoded.height * scale).round(),
            interpolation: img.Interpolation.cubic,
          );
    image = img.grayscale(image);

    // Grey levels and the background (the most common one).
    final Uint32List histogram = Uint32List(256);
    int sum = 0;
    for (final img.Pixel p in image) {
      final int v = p.r.toInt().clamp(0, 255);
      histogram[v]++;
      sum += v;
    }
    final bool dark = sum / (image.width * image.height) < 110;
    int background = 0;
    for (int v = 1; v < 256; v++) {
      if (histogram[v] > histogram[background]) background = v;
    }
    if (dark) background = 255 - background;

    final Uint8List lookup = Uint8List(256);
    for (int v = 0; v < 256; v++) {
      final int grey = dark ? 255 - v : v;
      lookup[v] = (255 - (background - grey) * 255 / _inkDepth).round().clamp(0, 255);
    }
    for (final img.Pixel p in image) {
      final int v = lookup[p.r.toInt().clamp(0, 255)];
      p
        ..r = v
        ..g = v
        ..b = v;
    }
    return img.encodePng(image, level: 1);
  }
}
