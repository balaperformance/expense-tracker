/// The contract between the receipt UI and whatever actually reads receipts.
///
/// The screens depend only on this file. Swapping the on-device recogniser
/// for a cloud vision service, or for a GenAI extractor, means writing one
/// more implementation of [ReceiptScannerService] — no screen, no repository
/// and no expense logic changes.
library;

import 'receipt_result.dart';

/// Where the receipt image comes from.
enum ReceiptImageSource {
  camera,
  gallery,
}

extension ReceiptImageSourceLabel on ReceiptImageSource {
  String get label => switch (this) {
        ReceiptImageSource.camera => 'Take photo',
        ReceiptImageSource.gallery => 'Choose from gallery',
      };

  String get description => switch (this) {
        ReceiptImageSource.camera => 'Point the camera at the receipt',
        ReceiptImageSource.gallery => 'Pick a photo you already have',
      };
}

/// Captures an image and extracts receipt fields from it.
///
/// Implementations must never throw: every failure is reported as a
/// [ReceiptScanFailed] so the caller has exactly one path to handle, and a
/// blurry photo cannot crash the add-expense flow.
abstract class ReceiptScannerService {
  /// False when the platform cannot scan at all — a desktop or web build with
  /// no recogniser. The UI hides the entry point rather than offering an
  /// action that will always fail.
  bool get isAvailable;

  Future<ReceiptScanOutcome> scan(ReceiptImageSource source);

  /// Releases the recogniser's native resources.
  Future<void> dispose();
}

/// A scanner that is compiled in but cannot run here.
///
/// Used on platforms with no text recogniser so the rest of the app can
/// depend on a non-null service without null checks at every call site.
class UnavailableReceiptScanner implements ReceiptScannerService {
  const UnavailableReceiptScanner();

  @override
  bool get isAvailable => false;

  @override
  Future<ReceiptScanOutcome> scan(ReceiptImageSource source) async =>
      const ReceiptScanFailed(ReceiptScanProblem.engineFailure);

  @override
  Future<void> dispose() async {}
}
