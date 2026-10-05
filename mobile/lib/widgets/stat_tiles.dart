import 'package:flutter/material.dart';

import '../core/theme/app_glass.dart';
import '../core/theme/app_motion.dart';
import '../core/theme/app_palette.dart';
import '../core/theme/app_spacing.dart';
import '../core/theme/app_typography.dart';
import '../core/utils/formatters.dart';
import 'common/hero_surface.dart';
import 'common/money_text.dart';

// ToneColors lives with MoneyText, but is re-exported here because most
// callers need both together.
export 'common/money_text.dart' show ToneColors, AmountTone, MoneyText;

/// Small labelled figure. The unit the dashboard and report headers are
/// built from.
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    required this.amount,
    required this.currency,
    required this.icon,
    required this.tone,
    this.compact = true,
    this.colouredAmount = false,
  });

  final String label;
  final double amount;
  final String currency;
  final IconData icon;

  /// Colours the icon well. The figure stays neutral unless
  /// [colouredAmount] is set, so a card of stats does not become a
  /// traffic light.
  final Color tone;
  final bool compact;
  final bool colouredAmount;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: ToneColors.wash(context, tone),
                borderRadius: BorderRadius.circular(AppSpacing.radiusXs),
              ),
              child: Icon(icon, size: 12, color: tone),
            ),
            const SizedBox(width: AppSpacing.sm),
            Flexible(
              child: Text(
                label,
                style: theme.textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        MoneyText(
          amount,
          currency: currency,
          compact: compact,
          fit: true,
          style: theme.textTheme.headlineSmall?.copyWith(
            color: colouredAmount ? tone : null,
          ),
        ),
      ],
    );
  }
}

/// The dashboard's hero, on the black [HeroSurface]: what is available now,
/// then the month so far.
///
/// The month is still running — a salary paid at month-end has not arrived
/// yet — so income received and spending sit side by side as figures to date
/// and are never netted into a verdict on the month. Without accounts there is
/// no balance, and the figure is the month's spending. The web's
/// `BalanceCard`.
class BalanceCard extends StatelessWidget {
  const BalanceCard({
    super.key,
    required this.income,
    required this.expense,
    required this.currency,
    required this.monthLabel,
    this.bankTotal,
    this.bankTotalHidden = false,
    this.onToggleBankTotal,
  });

  final double income;
  final double expense;
  final String currency;
  final String monthLabel;

  /// Every bank and cash account's balance added up — the total the Accounts
  /// screen shows; null when there are no accounts. Credit-card outstanding
  /// is not money available, so it is never part of it.
  final double? bankTotal;

  /// Masks [bankTotal] behind dots until the eye is tapped.
  final bool bankTotalHidden;

  /// Null hides the eye entirely, for callers with nothing to protect.
  final VoidCallback? onToggleBankTotal;

  @override
  Widget build(BuildContext context) {
    // Builder so the content reads the hero's dark theme, not the page's.
    return HeroSurface(
      glow: PaletteTokens.of(context).heroGlow,
      child: Builder(builder: _content),
    );
  }

  Widget _content(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // The hero's own ink and accent — taupe on Gothic Noir, sand on Matte.
    final PaletteTokens hero = PaletteTokens.of(context);
    final double? balance = bankTotal;
    final Widget monthBadge = _HeroBadge(label: monthLabel);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                balance != null ? 'AVAILABLE BALANCE' : 'SPENT THIS MONTH',
                style: AppTypography.eyebrow(
                  theme.textTheme,
                  color: hero.heroAccent,
                ),
              ),
            ),
            if (balance == null)
              monthBadge
            else if (onToggleBankTotal != null)
              _RevealButton(
                hidden: bankTotalHidden,
                onPressed: onToggleBankTotal!,
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        MoneyText(
          balance ?? expense,
          currency: currency,
          // Neutral ink, not a money tone, and a sign only when an account
          // is overdrawn: green stays reserved for Income.
          signed: balance != null && balance < 0,
          obscured: balance != null && bankTotalHidden,
          fit: true,
          // The hero figure on the whole app, and the one place a counting
          // transition is worth its frames.
          animate: true,
          style: theme.textTheme.displaySmall?.copyWith(
            fontSize: 36,
            color: hero.heroInk,
          ),
        ),
        if (balance != null) ...<Widget>[
          const SizedBox(height: AppSpacing.sm + 2),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  'So far this month',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              monthBadge,
            ],
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        Row(
          children: <Widget>[
            Expanded(
              child: _Leg(
                label: 'Income received',
                amount: income,
                currency: currency,
                tone: ToneColors.income(context),
                icon: Icons.south_west_rounded,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            // Without accounts the figure above is already the spending.
            Expanded(
              child: balance == null
                  ? const SizedBox.shrink()
                  : _Leg(
                      label: 'Spent this month',
                      amount: expense,
                      currency: currency,
                      tone: ToneColors.expense(context),
                      icon: Icons.north_east_rounded,
                    ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The month pill in the hero's top-right corner.
class _HeroBadge extends StatelessWidget {
  const _HeroBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final Color accent = PaletteTokens.of(context).heroAccent;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm + 2,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: accent.withOpacity(0.14),
        borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
        border: Border.all(color: accent.withOpacity(0.30), width: 0.75),
      ),
      child: Text(
        label.toUpperCase(),
        style: AppTypography.eyebrow(
          Theme.of(context).textTheme,
          color: accent,
        ),
      ),
    );
  }
}

/// The eye beside a masked balance.
///
/// Deliberately small and quiet — it sits next to a figure, not in a toolbar
/// — but its tap area is padded out to the full touch target so a 20px icon
/// is still comfortable to hit.
class _RevealButton extends StatelessWidget {
  const _RevealButton({required this.hidden, required this.onPressed});

  final bool hidden;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      tooltip: hidden ? 'Show balance' : 'Hide balance',
      iconSize: AppSpacing.iconMd - 2,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(
        minWidth: AppSpacing.minTouch - 20,
        minHeight: AppSpacing.minTouch - 20,
      ),
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      icon: Icon(
        hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined,
      ),
    );
  }
}

/// Income or expenses on the hero: an inset tile carrying its tone.
class _Leg extends StatelessWidget {
  const _Leg({
    required this.label,
    required this.amount,
    required this.currency,
    required this.tone,
    required this.icon,
  });

  final String label;
  final double amount;
  final String currency;
  final Color tone;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm + 2,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.06),
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: tone.withOpacity(0.22),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 14, color: tone),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  label,
                  style: theme.textTheme.labelSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 1),
                MoneyText(
                  amount,
                  currency: currency,
                  compact: true,
                  fit: true,
                  style: AppTypography.money(
                    theme.textTheme.titleMedium?.copyWith(color: tone),
                    emphasis: true,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Row of shortcut controls under the dashboard snapshot.
///
/// Each action is a raised white tile holding a colour-washed icon circle,
/// with its label beneath — it looks pressable, and scales on press, rather
/// than sitting flat and gray on the page.
class QuickActions extends StatelessWidget {
  const QuickActions({super.key, required this.actions});

  final List<QuickAction> actions;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (int i = 0; i < actions.length; i++) ...<Widget>[
          if (i != 0) const SizedBox(width: AppSpacing.sm),
          Expanded(child: _QuickActionButton(action: actions[i])),
        ],
      ],
    );
  }
}

class QuickAction {
  const QuickAction({
    required this.label,
    required this.icon,
    required this.onTap,
    this.tone,
    this.alert,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final Color? tone;

  /// Something needs attention there (a budget overspent): a red dot on the
  /// tile, and this in its accessible name.
  final String? alert;
}

class _QuickActionButton extends StatelessWidget {
  const _QuickActionButton({required this.action});

  static const double _tile = 52;
  static const double _well = 36;

  final QuickAction action;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color tone = action.tone ?? theme.colorScheme.primary;
    final BorderRadius shape =
        BorderRadius.circular(AppSpacing.radiusMd + 4);

    // The scale observes pointer events without recognising them, so the
    // InkWell keeps sole ownership of the tap.
    return AppPressEffect(
      child: Semantics(
        button: true,
        label: action.alert == null ? null : '${action.label}, ${action.alert}',
        excludeSemantics: action.alert != null,
        child: InkWell(
          onTap: action.onTap,
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    borderRadius: shape,
                    boxShadow: AppGlass.of(context).shadow,
                  ),
                  child: SizedBox(
                    width: _tile,
                    height: _tile,
                    child: Stack(
                      children: <Widget>[
                        Center(
                          child: Container(
                            width: _well,
                            height: _well,
                            decoration: BoxDecoration(
                              color: ToneColors.wash(context, tone),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(action.icon, size: 20, color: tone),
                          ),
                        ),
                        if (action.alert != null)
                          Positioned(
                            top: 3,
                            right: 3,
                            child: Container(
                              width: 15,
                              height: 15,
                              decoration: BoxDecoration(
                                color: ToneColors.expense(context),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: theme.colorScheme.surface,
                                  width: 2,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.xs + 2),
                Text(
                  action.label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact month navigator used by Reports, Budgets and Statements.
class MonthStepper extends StatelessWidget {
  const MonthStepper({
    super.key,
    required this.month,
    required this.onPrevious,
    this.onNext,
    this.trailing,
    this.label,
    this.unit = 'month',
  });

  final DateTime month;
  final VoidCallback onPrevious;

  /// Replaces the month name — a card statement steps by billing cycle.
  final String? label;

  /// What one step is, for the tooltips ("Previous month", "Previous cycle").
  final String unit;

  /// Null disables forward navigation — there is nothing after this month.
  final VoidCallback? onNext;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      child: Row(
        children: <Widget>[
          IconButton(
            onPressed: onPrevious,
            icon: const Icon(Icons.chevron_left_rounded),
            tooltip: 'Previous $unit',
            visualDensity: VisualDensity.compact,
          ),
          Expanded(
            child: Text(
              label ?? Formatters.monthYear(month),
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
          ),
          IconButton(
            onPressed: onNext,
            icon: const Icon(Icons.chevron_right_rounded),
            tooltip: 'Next $unit',
            visualDensity: VisualDensity.compact,
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}
