import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../core/theme/app_glass.dart';
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

/// The dashboard's financial snapshot, on the espresso [HeroSurface].
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
                  color: AppColors.tan,
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
          tone: AmountTone.auto,
          fit: true,
          // The hero figure on the whole app, and the one place a counting
          // transition is worth its frames.
          animate: true,
          style: theme.textTheme.displaySmall?.copyWith(fontSize: 31),
        ),
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
                color: AppColors.tan,
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
        color: AppColors.tan.withOpacity(0.14),
        borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
        border: Border.all(color: AppColors.tan.withOpacity(0.30), width: 0.75),
      ),
      child: Text(
        label.toUpperCase(),
        style: AppTypography.eyebrow(
          Theme.of(context).textTheme,
          color: AppColors.tan,
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

/// Income or expenses on the hero: a quiet inset tile carrying its tone.
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
        color: AppColors.cream.withOpacity(0.06),
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border:
            Border.all(color: AppColors.cream.withOpacity(0.08), width: 0.75),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: tone.withOpacity(0.18),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 13, color: tone),
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
                    theme.textTheme.titleSmall?.copyWith(color: tone),
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

/// Row of shortcut tiles under the dashboard snapshot.
///
/// Each action is a small glass tile with its label underneath — the premium
/// shortcut idiom — rather than a bordered button, so the row reads as a
/// palette of destinations instead of four competing calls to action.
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

  static const double _tile = 48;

  final QuickAction action;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color tone = action.tone ?? theme.colorScheme.primary;

    return InkWell(
      onTap: action.onTap,
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            GlassSurface(
              radius: AppSpacing.radiusMd + 2,
              child: SizedBox(
                width: _tile,
                height: _tile,
                child: Icon(action.icon, size: 21, color: tone),
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
