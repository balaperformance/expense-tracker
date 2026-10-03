/// What a receipt scan produces, independent of who produced it.
///
/// Nothing in this file imports a plugin, a repository or Flutter. An OCR
/// engine, a cloud vision API or a future GenAI extractor all describe their
/// findings with these types, and the review screen renders them without
/// knowing which one ran.
library;

/// How much the extractor trusts a single field.
///
/// Confidence is per field, not per receipt: a scan very often reads the
/// total cleanly off a bold line while guessing at the merchant from the
/// header. Collapsing that into one number would either hide a good total or
/// oversell a bad merchant.
enum ReceiptConfidence {
  /// Found where this field is expected, in an unambiguous form.
  high,

  /// Found, but inferred rather than labelled — the largest amount on the
  /// receipt, or the first line that looked like a name.
  medium,

  /// A guess worth showing so the user can correct it rather than retype it.
  low,

  /// Not found. The review screen leaves the field empty.
  none,
}

extension ReceiptConfidenceLabel on ReceiptConfidence {
  String get label => switch (this) {
        ReceiptConfidence.high => 'Clear',
        ReceiptConfidence.medium => 'Likely',
        ReceiptConfidence.low => 'Unsure',
        ReceiptConfidence.none => 'Not found',
      };

  /// True when the value should be pointed out for checking rather than
  /// presented as read.
  bool get needsReview =>
      this == ReceiptConfidence.low || this == ReceiptConfidence.medium;

  bool get found => this != ReceiptConfidence.none;
}

/// One extracted value and how much the extractor trusts it.
class ReceiptField<T> {
  const ReceiptField(this.value, this.confidence);

  const ReceiptField.missing()
      : value = null,
        confidence = ReceiptConfidence.none;

  final T? value;
  final ReceiptConfidence confidence;

  bool get hasValue => value != null;

  /// True when the value is present but the user should glance at it.
  bool get shouldVerify => hasValue && confidence.needsReview;

  @override
  String toString() => 'ReceiptField($value, ${confidence.name})';
}

/// A single purchased line, when the receipt lists them legibly.
///
/// Items are a convenience, never a requirement: most receipts are printed in
/// a layout OCR cannot reliably column-split, so an empty list is a normal
/// result and not a failure.
class ReceiptLineItem {
  const ReceiptLineItem({
    required this.description,
    required this.amount,
    this.quantity,
  });

  final String description;
  final double amount;
  final int? quantity;

  /// "2 x Flat White" — what the review screen prints.
  String get display =>
      quantity == null || quantity == 1 ? description : '$quantity x $description';

  @override
  String toString() => 'ReceiptLineItem($display, $amount)';
}

/// Everything one scan found.
class ReceiptResult {
  const ReceiptResult({
    this.merchant = const ReceiptField<String>.missing(),
    this.total = const ReceiptField<double>.missing(),
    this.date = const ReceiptField<DateTime>.missing(),
    this.lineItems = const <ReceiptLineItem>[],
    this.rawLines = const <String>[],
  });

  /// Nothing legible at all — a blurry photo, a blank page, a picture of
  /// something that is not a receipt.
  const ReceiptResult.unreadable()
      : merchant = const ReceiptField<String>.missing(),
        total = const ReceiptField<double>.missing(),
        date = const ReceiptField<DateTime>.missing(),
        lineItems = const <ReceiptLineItem>[],
        rawLines = const <String>[];

  final ReceiptField<String> merchant;
  final ReceiptField<double> total;
  final ReceiptField<DateTime> date;
  final List<ReceiptLineItem> lineItems;

  /// Every non-blank line the recogniser returned, in reading order.
  ///
  /// Kept because some facts are on a receipt but in none of the structured
  /// fields — "Paid by UPI" is neither the merchant nor a purchased item, and
  /// is the only place the tender is stated. It also gives a future cloud or
  /// GenAI extractor the same input this parser had.
  ///
  /// In memory for the length of the scan and never written anywhere: the
  /// review screen reads it, the expense that follows does not carry it.
  final List<String> rawLines;

  /// How many text lines the recogniser returned. Used to tell "the photo was
  /// unreadable" apart from "the photo was readable but is not a receipt",
  /// which are different messages to the user.
  int get rawLineCount => rawLines.length;

  /// The amount is the one field without which a scan has saved no typing.
  bool get hasUsableTotal => total.hasValue && (total.value ?? 0) > 0;

  /// True when OCR read text but none of it looked like receipt data.
  bool get readTextButFoundNothing =>
      rawLineCount > 0 && !hasUsableTotal && !merchant.hasValue;

  bool get isEmpty =>
      !total.hasValue && !merchant.hasValue && !date.hasValue;

  /// Fields the review screen should flag for a second look.
  List<String> get fieldsToVerify => <String>[
        if (total.shouldVerify || !total.hasValue) 'amount',
        if (merchant.shouldVerify) 'merchant',
        if (date.shouldVerify) 'date',
      ];
}

/// Why a scan did not return a result.
enum ReceiptScanProblem {
  /// The user backed out of the camera or the picker.
  cancelled,

  /// Camera or photo-library access was refused.
  permissionDenied,

  /// The image was picked but no text could be recognised in it.
  unreadable,

  /// The recogniser itself failed — a decode error, a missing model.
  engineFailure,
}

extension ReceiptScanProblemMessage on ReceiptScanProblem {
  /// Phrased as what the user can do next, not as what the code hit.
  String get message => switch (this) {
        ReceiptScanProblem.cancelled => 'Scan cancelled.',
        ReceiptScanProblem.permissionDenied =>
          'Allow camera and photo access in your device settings to scan '
              'receipts.',
        ReceiptScanProblem.unreadable =>
          'Could not read that image. Try again with the whole receipt in '
              'frame, flat, and in good light.',
        ReceiptScanProblem.engineFailure =>
          'Receipt scanning is unavailable right now. You can still add the '
              'expense by hand.',
      };
}

/// The outcome of a scan: a result, or a reason there is none.
///
/// A sealed type rather than a nullable result plus an error string, so the
/// caller cannot forget to handle the failure branch.
sealed class ReceiptScanOutcome {
  const ReceiptScanOutcome();
}

class ReceiptScanned extends ReceiptScanOutcome {
  const ReceiptScanned(this.result);

  final ReceiptResult result;
}

class ReceiptScanFailed extends ReceiptScanOutcome {
  const ReceiptScanFailed(this.problem);

  final ReceiptScanProblem problem;

  String get message => problem.message;
}
