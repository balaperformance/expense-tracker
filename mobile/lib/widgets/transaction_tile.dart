import 'package:flutter/material.dart';

import '../core/theme/app_spacing.dart';
import '../core/utils/formatters.dart';
import '../models/expense.dart';
import '../models/income.dart';
import 'category_avatar.dart';
import 'common/money_text.dart';

/// Shared layout for every money row in the app.
///
/// Expenses, income and transfers all render through this, so the three read
/// as one family and differ only where they should: the leading icon, the
/// sign, and the colour of the amount. A user scanning a mixed list can tell
/// direction from the amount alone without reading the label.
///
/// The row is dense — 38px avatar, two text lines — but its minimum height is
/// still a full touch target.
class TransactionRow extends StatelessWidget {
  const TransactionRow({
    super.key,
    required this.leading,
    required this.title,
    required this.amount,
    required this.currency,
    required this.tone,
    this.meta = const <String>[],
    this.trailingBelow,
    this.onTap,
    this.onLongPress,
    this.signed = true,
    this.titleMaxLines = 1,
  });

  final Widget leading;
  final String title;
  final double amount;
  final String currency;
  final AmountTone tone;

  /// Secondary line, joined with a middot. Empty entries are dropped by the
  /// caller, so the separator never dangles.
  final List<String> meta;

  /// Small text under the amount — a running balance on a statement.
  final String? trailingBelow;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool signed;

  /// Lines the title may use before ellipsising. A statement sets 2, where a
  /// full description matters more than uniform row heights.
  final int titleMaxLines;

  /// Ceiling on the amount column.
  ///
  /// Wide enough for a nine-figure amount at the row's type size, so in
  /// practice only an absurd figure is ever scaled down by `fit`.
  static const double _amountMaxWidth = 128;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<String> parts =
        meta.where((String m) => m.trim().isNotEmpty).toList();

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: ConstrainedBox(
        // The row's own content already lands it just over the touch floor,
        // so this is a guarantee rather than the thing setting the height.
        constraints: const BoxConstraints(minHeight: AppSpacing.minTouch),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.rowPadY,
          ),
          child: Row(
            children: <Widget>[
              leading,
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      title,
                      style: theme.textTheme.titleMedium,
                      maxLines: titleMaxLines,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (parts.isNotEmpty) ...<Widget>[
                      const SizedBox(height: AppSpacing.xxs),
                      Text(
                        parts.join(' · '),
                        style: theme.textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              // Not flexible. A Flexible here carries flex 1 and therefore
              // takes *half* the remaining width whether the amount needs it
              // or not, which left the title about 120px on a 360px phone and
              // truncated ordinary descriptions. As an ordinary child the
              // column is laid out at its intrinsic width first and the title
              // gets everything else; the cap plus `fit` still keep a
              // nine-figure amount from overflowing a 320px row.
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _amountMaxWidth),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    MoneyText(
                      amount,
                      currency: currency,
                      tone: tone,
                      signed: signed,
                      emphasis: true,
                      fit: true,
                      textAlign: TextAlign.end,
                      style: theme.textTheme.titleMedium,
                    ),
                    if (trailingBelow != null) ...<Widget>[
                      const SizedBox(height: AppSpacing.xxs),
                      Text(
                        trailingBelow!,
                        style: theme.textTheme.labelSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One expense row.
class ExpenseTile extends StatelessWidget {
  const ExpenseTile({
    super.key,
    required this.expense,
    required this.currency,
    this.onTap,
    this.showDate = true,
    this.sourceLabel,
  });

  final Expense expense;
  final String currency;
  final VoidCallback? onTap;

  /// Hidden when the list already groups by day.
  final bool showDate;

  /// Payment source — a bank nickname, or "Cash". Resolved by the caller,
  /// which is the only layer that knows the account list.
  final String? sourceLabel;

  @override
  Widget build(BuildContext context) {
    return TransactionRow(
      leading: CategoryAvatar(
        icon: expense.category?.icon,
        color: expense.category?.color,
      ),
      title: expense.title,
      amount: -expense.amount,
      currency: currency,
      tone: AmountTone.negative,
      meta: <String>[
        if (showDate) Formatters.relativeDay(expense.expenseDate),
        expense.categoryName,
        if (sourceLabel != null)
          sourceLabel!
        else if (expense.paymentMethod != null)
          expense.paymentMethod!.name,
      ],
      onTap: onTap,
    );
  }
}

/// One income row. Same shape as an expense, opposite sign and colour.
class IncomeTile extends StatelessWidget {
  const IncomeTile({
    super.key,
    required this.income,
    required this.currency,
    this.onTap,
    this.showDate = true,
    this.destinationLabel,
  });

  final Income income;
  final String currency;
  final VoidCallback? onTap;
  final bool showDate;

  /// Bank account the money landed in, when one is linked.
  final String? destinationLabel;

  @override
  Widget build(BuildContext context) {
    return TransactionRow(
      leading: const IncomeAvatar(),
      title: income.title,
      amount: income.amount,
      currency: currency,
      tone: AmountTone.positive,
      meta: <String>[
        if (showDate) Formatters.relativeDay(income.incomeDate),
        if (income.subtitle != null) income.subtitle!,
        if (destinationLabel != null) destinationLabel!,
      ],
      onTap: onTap,
    );
  }
}

/// Sticky-feeling day header above a group of transactions.
///
/// Carries the day's total on the right so a long list can be scanned by day
/// without adding a summary row.
class DayHeader extends StatelessWidget {
  const DayHeader({
    super.key,
    required this.label,
    required this.total,
    required this.currency,
    this.tone = AmountTone.neutral,
    this.isFirst = false,
  });

  final String label;
  final double total;
  final String currency;
  final AmountTone tone;
  final bool isFirst;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.only(
        top: isFirst ? 0 : AppSpacing.md,
        bottom: AppSpacing.xs + 2,
        left: AppSpacing.xs,
        right: AppSpacing.xs,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.labelMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          MoneyText(
            total,
            currency: currency,
            compact: true,
            tone: tone,
            style: theme.textTheme.labelSmall,
          ),
        ],
      ),
    );
  }
}
