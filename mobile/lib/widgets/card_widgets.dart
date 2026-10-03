import 'package:flutter/material.dart';

import '../core/theme/app_spacing.dart';
import '../core/utils/formatters.dart';
import '../models/card_statement.dart';
import '../models/credit_card.dart';
import 'common/app_fields.dart';
import 'common/money_text.dart';
import 'common/surface_card.dart';

/// A credit card in a list or a title bar.
class CardAvatar extends StatelessWidget {
  const CardAvatar({super.key, this.size = AppSpacing.avatar, this.tone});

  final double size;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final Color colour = tone ?? Theme.of(context).colorScheme.secondary;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: ToneColors.wash(context, colour),
        borderRadius: BorderRadius.circular(size * 0.29),
      ),
      child: Icon(Icons.credit_card_rounded, size: size * 0.48, color: colour),
    );
  }
}

/// A movement on a card statement that is not a purchase (those carry their
/// category): payments read as transfers, credits as money in, charges as
/// money out.
class CardMovementAvatar extends StatelessWidget {
  const CardMovementAvatar({super.key, required this.entry});

  final CardEntry entry;

  @override
  Widget build(BuildContext context) {
    final (IconData icon, Color tone) = switch (entry.kind) {
      CardEntryKind.payment => (
          entry.source == CardEntrySource.account
              ? Icons.account_balance_outlined
              : Icons.payments_outlined,
          ToneColors.transfer(context),
        ),
      CardEntryKind.refund ||
      CardEntryKind.cashback =>
        (Icons.south_west_rounded, ToneColors.income(context)),
      CardEntryKind.fee ||
      CardEntryKind.interest =>
        (Icons.north_east_rounded, ToneColors.expense(context)),
      _ => (
          Icons.tune_rounded,
          Theme.of(context).colorScheme.onSurfaceVariant
        ),
    };
    return Container(
      width: AppSpacing.avatar,
      height: AppSpacing.avatar,
      decoration: BoxDecoration(
        color: ToneColors.wash(context, tone),
        borderRadius: BorderRadius.circular(AppSpacing.avatar * 0.29),
      ),
      child: Icon(icon, size: AppSpacing.avatar * 0.46, color: tone),
    );
  }
}

/// Utilisation colour: calm below 30%, caution from 70%, alarm from 90%.
Color utilisationTone(BuildContext context, double ratio) {
  if (ratio >= 0.9) return ToneColors.expense(context);
  if (ratio >= 0.7) return ToneColors.warning(context);
  if (ratio >= 0.3) return Theme.of(context).colorScheme.primary;
  return ToneColors.income(context);
}

/// How much of the limit is used.
class UtilisationBar extends StatelessWidget {
  const UtilisationBar({super.key, required this.ratio});

  final double ratio;

  @override
  Widget build(BuildContext context) {
    final Color tone = utilisationTone(context, ratio);
    return Semantics(
      label: '${Formatters.percent(ratio)} of the limit used',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
        child: LinearProgressIndicator(
          value: ratio.clamp(0, 1).toDouble(),
          minHeight: 6,
          color: tone,
          backgroundColor: ToneColors.wash(context, tone),
        ),
      ),
    );
  }
}

/// One line on the bill: what is due and when, or that it is paid.
class DueLine extends StatelessWidget {
  const DueLine({super.key, required this.summary, required this.currency});

  final CardSummary summary;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final StatementDue due = summary.lastStatement;
    final (IconData icon, Color tone) = switch (due.status) {
      DueStatus.overdue => (
          Icons.warning_amber_rounded,
          ToneColors.expense(context)
        ),
      DueStatus.due => (
          Icons.event_outlined,
          due.daysToDue <= 3
              ? ToneColors.warning(context)
              : theme.colorScheme.primary,
        ),
      DueStatus.paid => (
          Icons.check_circle_outline_rounded,
          ToneColors.income(context)
        ),
      DueStatus.nothingDue => (
          Icons.check_circle_outline_rounded,
          theme.colorScheme.onSurfaceVariant,
        ),
    };
    final bool owing =
        due.status == DueStatus.due || due.status == DueStatus.overdue;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: ToneColors.wash(context, tone),
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      ),
      child: Row(
        children: <Widget>[
          Icon(icon, size: AppSpacing.iconSm, color: tone),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              dueSummaryText(
                summary,
                (double v) => Formatters.currency(v, currencyCode: currency),
                Formatters.dayMonth,
              ),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurface),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (owing) ...<Widget>[
            const SizedBox(width: AppSpacing.sm),
            Text(
              due.statusText,
              style: theme.textTheme.labelMedium?.copyWith(color: tone),
            ),
          ],
        ],
      ),
    );
  }
}

/// "Cash or account" / "Credit card" — the first choice under Paid from.
class FundingToggle extends StatelessWidget {
  const FundingToggle({
    super.key,
    required this.byCard,
    required this.onChanged,
    this.enabled = true,
  });

  final bool byCard;
  final ValueChanged<bool> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<bool>(
        segments: const <ButtonSegment<bool>>[
          ButtonSegment<bool>(
            value: false,
            label: Text('Cash or account'),
            icon: Icon(Icons.account_balance_outlined, size: 15),
          ),
          ButtonSegment<bool>(
            value: true,
            label: Text('Credit card'),
            icon: Icon(Icons.credit_card_rounded, size: 15),
          ),
        ],
        selected: <bool>{byCard},
        showSelectedIcon: false,
        onSelectionChanged:
            enabled ? (Set<bool> value) => onChanged(value.first) : null,
      ),
    );
  }
}

/// One chip per card.
class CardChoiceChips extends StatelessWidget {
  const CardChoiceChips({
    super.key,
    required this.cards,
    required this.selectedId,
    required this.onSelected,
    this.enabled = true,
  });

  final List<CreditCard> cards;
  final String? selectedId;
  final ValueChanged<String> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: cards
          .map((CreditCard card) => AppChoiceChip(
                label: card.displayLabel,
                icon: Icons.credit_card_rounded,
                selected: card.id == selectedId,
                enabled: enabled,
                onSelected: () => onSelected(card.id),
              ))
          .toList(),
    );
  }
}

/// The chosen card's headroom, and a warning — never a block — when the
/// amount is more than it: a card can go over its limit. [alreadyCounted] is
/// the part already in the outstanding (the saved amount when editing a
/// purchase on this card).
class AvailableCreditLine extends StatelessWidget {
  const AvailableCreditLine({
    super.key,
    required this.card,
    required this.summary,
    required this.amount,
    required this.currency,
    this.alreadyCounted = 0,
  });

  final CreditCard card;
  final CardSummary summary;
  final double? amount;
  final String currency;
  final double alreadyCounted;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    if (card.creditLimit <= 0) {
      return Text(
        "Adds to the card's outstanding, not to any bank balance",
        style: theme.textTheme.labelSmall,
      );
    }
    final double headroom =
        card.creditLimit - summary.outstanding + alreadyCounted;
    final String headroomText = Formatters.currency(
      headroom < 0 ? 0 : headroom,
      currencyCode: currency,
    );
    final double? typed = amount;
    if (typed != null &&
        typed > 0 &&
        (typed * 100).round() > (headroom * 100).round()) {
      return AppNotice(
        icon: Icons.warning_amber_rounded,
        tone: ToneColors.warning(context),
        message: 'That is more than the $headroomText of credit left on this '
            'card. It is still recorded — the card will show as over its '
            'limit.',
      );
    }
    return Text(
      "$headroomText available · adds to the card's outstanding, not to any "
      'bank balance',
      style: theme.textTheme.labelSmall,
    );
  }
}
