import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../core/theme/app_glass.dart';
import '../core/theme/app_motion.dart';
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

/// The dashboard's financial snapshot, on the black [HeroSurface].
///
/// One dominant figure, two supporting legs, and the bank total when
/// accounts exist.
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

  /// Total across bank accounts, shown as a footer line when accounts exist.
  final double? bankTotal;

  /// Masks [bankTotal] behind dots until the eye is tapped.
  final bool bankTotalHidden;

  /// Null hides the eye entirely, for callers with nothing to protect.
  final VoidCallback? onToggleBankTotal;

  @override
  Widget build(BuildContext context) {
    final double net = income - expense;

    // Builder so the content reads the hero's dark theme, not the page's.
    return HeroSurface(
      glow: AppColors.heroGlow,
      child: Builder(
        builder: (BuildContext context) => _content(context, net),
      ),
    );
  }

  Widget _content(BuildContext context, double net) {
    final ThemeData theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                'NET THIS MONTH',
                style: AppTypography.eyebrow(
                  theme.textTheme,
                  color: AppColors.heroAccent,
                ),
              ),
            ),
            _HeroBadge(label: monthLabel),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        MoneyText(
          net,
          currency: currency,
          signed: net != 0,
          // Neutral ink, not a money tone: the sign says which way the
          // month went, and green stays reserved for Income.
          fit: true,
          // The hero figure on the whole app, and the one place a counting
          // transition is worth its frames.
          animate: true,
          style: theme.textTheme.displaySmall?.copyWith(
            fontSize: 36,
            color: AppColors.heroInk,
          ),
        ),
        if (income > 0) ...<Widget>[
          const SizedBox(height: AppSpacing.sm),
          _SpendBar(
            share: expense / income,
            spent: ToneColors.expense(context),
            track: AppColors.heroTrack,
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        Row(
          children: <Widget>[
            Expanded(
              child: _Leg(
                label: 'Income',
                amount: income,
                currency: currency,
                tone: ToneColors.income(context),
                icon: Icons.south_west_rounded,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: _Leg(
                label: 'Expenses',
                amount: expense,
                currency: currency,
                tone: ToneColors.expense(context),
                icon: Icons.north_east_rounded,
              ),
            ),
          ],
        ),
        if (bankTotal != null) ...<Widget>[
          const SizedBox(height: AppSpacing.sm + 2),
          Row(
            children: <Widget>[
              const Icon(
                Icons.account_balance_rounded,
                size: AppSpacing.iconSm,
                color: AppColors.heroAccent,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  'In bank accounts',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              MoneyText(
                bankTotal!,
                currency: currency,
                obscured: bankTotalHidden,
                style: theme.textTheme.titleSmall,
              ),
              if (onToggleBankTotal != null) ...<Widget>[
                const SizedBox(width: AppSpacing.xs),
                _RevealButton(
                  hidden: bankTotalHidden,
                  onPressed: onToggleBankTotal!,
                ),
              ],
            ],
          ),
        ],
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
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm + 2,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: AppColors.heroAccent.withOpacity(0.14),
        borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
        border: Border.all(color: AppColors.heroAccent.withOpacity(0.30), width: 0.75),
      ),
      child: Text(
        label.toUpperCase(),
        style: AppTypography.eyebrow(
          Theme.of(context).textTheme,
          color: AppColors.heroAccent,
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

/// How much of the month's income has gone: a thin two-tone bar under the
/// hero figure. Rose for spent over a soft white track for what is left,
/// at 5px of height.
class _SpendBar extends StatelessWidget {
  const _SpendBar({
    required this.share,
    required this.spent,
    required this.track,
  });

  final double share;
  final Color spent;
  final Color track;

  @override
  Widget build(BuildContext context) {
    final double clamped = share.clamp(0.0, 1.0);

    return Semantics(
      label: 'Spent ${(share * 100).round()} percent of income',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
        child: SizedBox(
          height: 5,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              ColoredBox(color: track),
              FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: clamped,
                child: ColoredBox(color: spent),
              ),
            ],
          ),
        ),
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
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final Color? tone;
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
                  child: Center(
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
  });

  final DateTime month;
  final VoidCallback onPrevious;

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
            tooltip: 'Previous month',
            visualDensity: VisualDensity.compact,
          ),
          Expanded(
            child: Text(
              Formatters.monthYear(month),
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
          ),
          IconButton(
            onPressed: onNext,
            icon: const Icon(Icons.chevron_right_rounded),
            tooltip: 'Next month',
            visualDensity: VisualDensity.compact,
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}
