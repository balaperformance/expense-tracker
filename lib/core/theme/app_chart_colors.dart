import 'package:flutter/material.dart';

/// Chart colours — the Pastel Garden palette.
///
/// Used by the category donut (and the ranked list that is its legend) and
/// by the monthly spending bars, and by nothing else: the rest of the UI is
/// Ink Wash, and no chart ever uses the Ink Wash blue gray. Read through
/// [ChartColors.of] so a chart never needs to know which mode it is in.
///
///   rose      #C75F71  the emphasised series and the largest slice
///   blush     #F0B8B8  context bars, a light slice
///   grayGreen #A2AE9D  income, a mid slice
///   deepBrown #54463A  a high-contrast slice, labels on the rose wash
///
/// Light mode uses the four exactly. Dark mode uses three of them exactly
/// and lifts only Deep Brown, which would be 1.7:1 on the charcoal card —
/// a slice you could not see.
@immutable
class ChartColors {
  const ChartColors._({
    required this.segments,
    required this.other,
    required this.emphasis,
    required this.idle,
    required this.expense,
    required this.income,
    required this.labelOnEmphasis,
  });

  // ---------------------------------------------------------------------
  // Palette sources
  // ---------------------------------------------------------------------

  static const Color rose = Color(0xFFC75F71);
  static const Color blush = Color(0xFFF0B8B8);
  static const Color grayGreen = Color(0xFFA2AE9D);
  static const Color deepBrown = Color(0xFF54463A);

  // ---------------------------------------------------------------------
  // Resolved roles
  // ---------------------------------------------------------------------

  /// Slice colours in rank order: slice 0 is the largest category. The four
  /// palette colours come first, strongest contrast first, so the biggest
  /// slices are the clearest. The fifth and sixth are blends of two palette
  /// colours rather than strangers, for a donut with six named slices.
  final List<Color> segments;

  /// The aggregated "Other" slice: a quiet neutral from the same family.
  final Color other;

  /// The selected month's bar.
  final Color emphasis;

  /// Every other month's bar — present, but receding behind [emphasis].
  final Color idle;

  /// Expense and income series, where both are drawn. Rose and gray-green
  /// keep the app's rule that red is money out and green is money in.
  final Color expense;
  final Color income;

  /// Text on a pill washed in [emphasis] — the selected month's label.
  final Color labelOnEmphasis;

  static const ChartColors light = ChartColors._(
    segments: <Color>[
      rose,
      deepBrown,
      grayGreen,
      blush,
      Color(0xFF8E5A63), // rose × deep brown
      Color(0xFF7C8472), // gray-green × deep brown
    ],
    other: Color(0xFFD8D2CC),
    emphasis: rose,
    idle: blush,
    expense: rose,
    income: grayGreen,
    labelOnEmphasis: deepBrown,
  );

  static const ChartColors dark = ChartColors._(
    segments: <Color>[
      rose,
      Color(0xFFA89484), // deep brown, lifted to 5.2:1 on the dark card
      grayGreen,
      blush,
      Color(0xFFC08C95), // rose × deep brown, lifted
      Color(0xFF8F9A80), // gray-green × deep brown, lifted
    ],
    other: Color(0xFF5C5752),
    emphasis: rose,
    // Blush at full strength is brighter than rose on charcoal, which would
    // make every *unselected* month look selected. Dimmed, it recedes.
    idle: Color(0x73F0B8B8),
    expense: rose,
    income: grayGreen,
    labelOnEmphasis: blush,
  );

  static ChartColors of(BuildContext context) =>
      forBrightness(Theme.of(context).brightness);

  static ChartColors forBrightness(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  /// Colour for the category ranked [rank] (0 = largest) out of [count],
  /// when the donut draws at most [maxSlices] slices.
  ///
  /// The donut and its ranked list both call this, so a category is the
  /// same colour in the ring and in the legend beneath it — including the
  /// categories folded into "Other".
  Color segment(int rank, int count, {int maxSlices = 6}) {
    final bool folds = count > maxSlices;
    if (folds && rank >= maxSlices - 1) return other;
    return segments[rank % segments.length];
  }
}
