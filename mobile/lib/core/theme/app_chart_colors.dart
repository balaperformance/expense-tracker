import 'package:flutter/material.dart';

/// Chart colours — a rich, muted jewel palette for Gothic Noir.
///
/// Used by the category donut (and the ranked list that is its legend) and
/// by the monthly bars, and by nothing else. The app theme is deliberately
/// restrained — black, gray, taupe — so the charts are where the colour
/// lives. The tones are deep and ink-like rather than neon: garnet,
/// amethyst, antique gold, jade, plum and steel blue. They are saturated
/// enough to tell apart at a glance and quiet enough to sit next to taupe.
/// Read through [ChartColors.of] so a chart never needs to know which mode
/// it is in.
///
/// Slices are ordered so neighbours in the ring sit at least 92° apart in
/// hue, and the last named slice is still far from the first where the ring
/// closes. Dark mode lifts each tone so it keeps 5:1 on the dark card.
@immutable
class ChartColors {
  const ChartColors._({
    required this.segments,
    required this.other,
    required this.emphasis,
    required this.emphasisHighlight,
    required this.idle,
    required this.expense,
    required this.income,
    required this.labelOnEmphasis,
  });

  /// Slice colours in rank order: slice 0 is the largest category.
  final List<Color> segments;

  /// The aggregated "Other" slice: a quiet warm neutral, so the named
  /// categories carry all the colour.
  final Color other;

  /// The selected month's bar, drawn as a gradient from [emphasis] at the
  /// base to [emphasisHighlight] at the top.
  final Color emphasis;
  final Color emphasisHighlight;

  /// Every other month's bar: the same hue, washed back.
  final Color idle;

  /// Expense and income series, where both are drawn — garnet out, jade in:
  /// the money tones' hues, in the chart palette's register.
  final Color expense;
  final Color income;

  /// Text on a pill washed in [emphasis] — the selected month's label.
  final Color labelOnEmphasis;

  static const ChartColors light = ChartColors._(
    segments: <Color>[
      Color(0xFFA63A50), // garnet
      Color(0xFF6650A6), // amethyst
      Color(0xFFB5842A), // antique gold
      Color(0xFF2E8278), // jade
      Color(0xFFA04A86), // plum
      Color(0xFF3F6D9E), // steel blue
    ],
    other: Color(0xFFB8AEAE),
    emphasis: Color(0xFFA63A50),
    emphasisHighlight: Color(0xFFC66478),
    idle: Color(0x33A63A50),
    expense: Color(0xFFA63A50),
    income: Color(0xFF2E8278),
    labelOnEmphasis: Color(0xFF7A2236),
  );

  static const ChartColors dark = ChartColors._(
    segments: <Color>[
      Color(0xFFD9677B), // garnet
      Color(0xFF9A86D8), // amethyst
      Color(0xFFD9A84E), // antique gold
      Color(0xFF4DB3A6), // jade
      Color(0xFFCC78B4), // plum
      Color(0xFF72A0D6), // steel blue
    ],
    other: Color(0xFF5A5050),
    emphasis: Color(0xFFD9677B),
    emphasisHighlight: Color(0xFFE892A1),
    idle: Color(0x4DD9677B),
    expense: Color(0xFFD9677B),
    income: Color(0xFF4DB3A6),
    labelOnEmphasis: Color(0xFFF0A3B0),
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
