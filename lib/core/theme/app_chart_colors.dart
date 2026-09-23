import 'package:flutter/material.dart';

/// Chart colours — a vivid jewel-tone palette.
///
/// Used by the category donut (and the ranked list that is its legend) and
/// by the monthly bars, and by nothing else. The app theme is deliberately
/// restrained — black, gray, taupe — so the charts are where the colour
/// lives: the one place a burst of saturation is information rather than
/// decoration. Read through [ChartColors.of] so a chart never needs to know
/// which mode it is in.
///
/// Slices are ordered so neighbours in the ring sit at least 99° apart in
/// hue — rose, violet, amber, teal, pink, blue — and the last named slice is
/// still far from the first where the ring closes.
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

  /// Expense and income series, where both are drawn — rose out, emerald in,
  /// matching the app's money tones.
  final Color expense;
  final Color income;

  /// Text on a pill washed in [emphasis] — the selected month's label.
  final Color labelOnEmphasis;

  static const ChartColors light = ChartColors._(
    segments: <Color>[
      Color(0xFFE8475F), // rose
      Color(0xFF7C5CFA), // violet
      Color(0xFFE08A00), // amber
      Color(0xFF0EA5A0), // teal
      Color(0xFFEC4899), // pink
      Color(0xFF3B82F6), // blue
    ],
    other: Color(0xFFB8AEAE),
    emphasis: Color(0xFFE8475F),
    emphasisHighlight: Color(0xFFF7849A),
    idle: Color(0x38E8475F),
    expense: Color(0xFFE8475F),
    income: Color(0xFF0B875E),
    labelOnEmphasis: Color(0xFF9F1239),
  );

  static const ChartColors dark = ChartColors._(
    segments: <Color>[
      Color(0xFFE8475F), // rose
      Color(0xFF7C5CFA), // violet
      Color(0xFFF59E0B), // amber, brighter on the dark card
      Color(0xFF14B8A6), // teal, brighter on the dark card
      Color(0xFFEC4899), // pink
      Color(0xFF3B82F6), // blue
    ],
    other: Color(0xFF5A5050),
    emphasis: Color(0xFFFB7185),
    emphasisHighlight: Color(0xFFFDA4AF),
    idle: Color(0x4DFB7185),
    expense: Color(0xFFFB7185),
    income: Color(0xFF34D399),
    labelOnEmphasis: Color(0xFFFDA4AF),
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
