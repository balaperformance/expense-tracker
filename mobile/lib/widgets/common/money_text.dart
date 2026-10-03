import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/formatters.dart';

/// What a figure means, which decides its colour.
///
/// Colour in this app is semantic and nothing else: a green number always
/// means money in, a red one always means money out. Anything that is merely
/// a quantity — a balance, a budget limit, a total — is [AmountTone.neutral]
/// and inherits the normal text colour, so the eye only stops on figures
/// that carry direction.
enum AmountTone {
  /// Ordinary figure. No colour.
  neutral,

  /// Money in.
  positive,

  /// Money out.
  negative,

  /// Budget pressure.
  warning,

  /// Movement between the user's own accounts. Deliberately not green: a
  /// transfer must never read as income.
  transfer,

  /// Colour follows the sign of the value.
  auto,
}

/// Renders a currency amount.
///
/// Always use this rather than `Text(Formatters.currency(...))`. It applies
/// tabular figures, so amounts stacked in a column align digit-for-digit and
/// a list of transactions reads as a ledger rather than as ragged text.
class MoneyText extends StatelessWidget {
  const MoneyText(
    this.amount, {
    super.key,
    required this.currency,
    this.style,
    this.tone = AmountTone.neutral,
    this.compact = false,
    this.signed = false,
    this.emphasis = false,
    this.textAlign,
    this.maxLines = 1,

    /// Shrinks the text rather than wrapping or overflowing when the amount
    /// is wider than its slot. Large figures on a narrow phone need this.
    this.fit = false,

    /// Replaces the figure with dots while keeping its style and slot, so
    /// revealing a hidden balance does not move anything on the screen.
    this.obscured = false,

    /// Counts from the previous value to the new one when [amount] changes.
    ///
    /// Opt-in, and only for the one or two hero figures on a screen. Applied
    /// to a list it would animate every row on every rebuild, which costs
    /// frames and makes a ledger look like a slot machine. Tabular figures
    /// mean the digits change in place without the text reflowing.
    this.animate = false,
  });

  final double amount;
  final String currency;
  final TextStyle? style;
  final AmountTone tone;
  final bool compact;

  /// Prefixes an explicit + or −, for rows where direction matters more than
  /// the colour alone can convey.
  final bool signed;
  final bool emphasis;
  final TextAlign? textAlign;
  final int maxLines;
  final bool fit;
  final bool obscured;
  final bool animate;

  /// What a hidden amount looks like. Fixed length on purpose: varying the
  /// dots with the real digit count would leak the magnitude.
  static const String _mask = '••••••';

  @override
  Widget build(BuildContext context) {
    // A counting figure is decorative, so it is skipped entirely when the
    // amount is hidden (there is nothing to count to) or when the platform
    // asks for reduced motion.
    final bool reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (animate && !obscured && !reduced) {
      return TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: amount, end: amount),
        duration: AppMotion.figure,
        curve: AppMotion.standard,
        builder: (BuildContext context, double value, Widget? _) =>
            _render(context, value),
      );
    }
    return _render(context, amount);
  }

  Widget _render(BuildContext context, double amount) {
    final ThemeData theme = Theme.of(context);
    final TextStyle base = style ?? theme.textTheme.titleMedium!;
    final Color? colour = _colour(context, amount);

    if (obscured) {
      return Text(
        _mask,
        textAlign: textAlign,
        maxLines: 1,
        overflow: TextOverflow.clip,
        style: AppTypography.money(
          base.copyWith(
            // Neutral while hidden: a red or green mask would still say
            // which way the money went.
            color: theme.colorScheme.onSurfaceVariant,
            letterSpacing: 1.5,
          ),
        ),
      );
    }

    final String formatted = Formatters.currency(
      amount.abs(),
      currencyCode: currency,
      compact: compact,
    );

    final String prefix = !signed
        ? ''
        : amount < 0
            ? '−'
            : '+';

    final Widget label = Text(
      '$prefix$formatted',
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      style: AppTypography.money(
        colour == null ? base : base.copyWith(color: colour),
        emphasis: emphasis,
      ),
    );

    if (!fit) return label;

    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: textAlign == TextAlign.end
          ? Alignment.centerRight
          : Alignment.centerLeft,
      child: label,
    );
  }

  Color? _colour(BuildContext context, double amount) {
    switch (tone) {
      case AmountTone.neutral:
        return null;
      case AmountTone.positive:
        return ToneColors.income(context);
      case AmountTone.negative:
        return ToneColors.expense(context);
      case AmountTone.warning:
        return ToneColors.warning(context);
      case AmountTone.transfer:
        return ToneColors.transfer(context);
      case AmountTone.auto:
        if (amount == 0) return null;
        return amount > 0
            ? ToneColors.income(context)
            : ToneColors.expense(context);
    }
  }
}

/// Resolves a semantic colour for the active brightness.
///
/// Light and dark need different values for the same meaning: the green that
/// passes contrast on white is too dark on near-black, and vice versa.
class ToneColors {
  const ToneColors._();

  static bool _dark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  static Color income(BuildContext context) =>
      _dark(context) ? AppColors.incomeDark : AppColors.income;

  static Color expense(BuildContext context) =>
      _dark(context) ? AppColors.expenseDark : AppColors.expense;

  static Color warning(BuildContext context) =>
      _dark(context) ? AppColors.warningDark : AppColors.warning;

  static Color transfer(BuildContext context) =>
      _dark(context) ? AppColors.transferDark : AppColors.transfer;

  /// Tinted background for a tone — icon wells, soft badges, chart tracks.
  ///
  /// Dark mode needs a stronger tint because a 10% wash over near-black is
  /// effectively invisible.
  static Color wash(BuildContext context, Color tone) =>
      tone.withOpacity(_dark(context) ? 0.20 : 0.11);
}
