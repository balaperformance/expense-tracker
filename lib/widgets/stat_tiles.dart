import 'package:flutter/material.dart';

import '../core/theme/app_glass.dart';
import '../core/theme/app_spacing.dart';
import '../core/theme/app_typography.dart';
import '../core/utils/formatters.dart';
import 'common/money_text.dart';
import 'common/surface_card.dart';

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

/// The dashboard's financial snapshot.
///
/// Flat and tonal rather than a gradient panel: a gradient reads as marketing,
/// and it forces every figure on top of it to fight a shifting background.
/// One dominant number, two supporting figures, nothing else.
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
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final double net = income - expense;

    return SurfaceCard(
      // The one card in the app that blurs. Content scrolls behind it on the
      // dashboard, so the effect is visibly doing work rather than being an
      // expensive tint.
      blur: AppGlass.blurCard,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  'Net this month',
                  style: theme.textTheme.labelMedium,
                ),
              ),
              AppBadge(label: monthLabel),
            ],
          ),
          const SizedBox(height: AppSpacing.xxs),
          MoneyText(
            net,
            currency: currency,
            signed: net != 0,
            tone: AmountTone.auto,
            fit: true,
            // The hero figure on the whole app, and the one place a counting
            // transition is worth its frames.
            animate: true,
            style: theme.textTheme.displaySmall,
          ),
          const SizedBox(height: AppSpacing.md),
          // A plain row with a hairline rather than a sunken well inside a
          // card: one less nested surface, and about 16px of height back.
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
              Container(
                width: 1,
                height: 24,
                color: scheme.outline,
                margin: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              ),
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
            const SizedBox(height: AppSpacing.sm),
            Divider(height: 1, color: scheme.outline),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: <Widget>[
                Icon(
                  Icons.account_balance_rounded,
                  size: AppSpacing.iconSm,
                  color: scheme.onSurfaceVariant,
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
        hidden
            ? Icons.visibility_outlined
            : Icons.visibility_off_outlined,
      ),
    );
  }
}

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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(icon, size: 12, color: tone),
            const SizedBox(width: AppSpacing.xs),
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
        const SizedBox(height: AppSpacing.xxs),
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
    );
  }
}

/// Row of shortcut buttons under the dashboard snapshot.
class QuickActions extends StatelessWidget {
  const QuickActions({super.key, required this.actions});

  final List<QuickAction> actions;

  @override
  Widget build(BuildContext context) {
    return Row(
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

  final QuickAction action;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color tone = action.tone ?? theme.colorScheme.onSurface;

    return Material(
      color: theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(AppSpacing.radiusButton),
      child: InkWell(
        onTap: action.onTap,
        borderRadius: BorderRadius.circular(AppSpacing.radiusButton),
        child: Container(
          height: 54,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppSpacing.radiusButton),
            border: Border.all(color: theme.colorScheme.outline),
          ),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(action.icon, size: AppSpacing.buttonIcon, color: tone),
              const SizedBox(height: AppSpacing.xs),
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
