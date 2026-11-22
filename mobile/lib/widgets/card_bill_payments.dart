import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme/app_spacing.dart';
import '../core/utils/formatters.dart';
import '../models/bank_account.dart';
import '../models/card_statement.dart';
import '../providers/auth_provider.dart';
import '../providers/bank_account_provider.dart';
import '../providers/credit_card_provider.dart';
import '../providers/settings_provider.dart';
import '../services/schema_capabilities.dart';
import 'common/app_buttons.dart';
import 'common/app_feedback.dart';
import 'common/money_text.dart';
import 'common/surface_card.dart';

/// The credit card bill payments in a period, for the record: what was paid,
/// when, from which account, to which card, and whether it settled that
/// card's bill. Informational only — a bill payment lowered the card's
/// outstanding (and, from an account, its balance) once, and is never
/// spending, so nothing here is added to any total.
///
/// A payment stored twice — from an account and on the card alone, for the
/// same card and amount within 10 days — is flagged "Possible duplicate" and
/// can be merged, only on the user's say (migration 022). Nothing is ever
/// corrected on its own; October's history stays as it is.
///
/// Shows nothing when there are no cards or no payments in the period.
class CardBillPaymentsSection extends StatefulWidget {
  const CardBillPaymentsSection({
    super.key,
    required this.from,
    required this.to,
    this.accountId,
    this.title = 'Credit card bill payments',
    this.gap = AppSpacing.section,
  });

  /// The period, inclusive.
  final DateTime from;
  final DateTime to;

  /// Only the payments drawn from this account (its statement), when set.
  final String? accountId;
  final String title;

  /// Space above the section, only when it shows.
  final double gap;

  @override
  State<CardBillPaymentsSection> createState() => _CardBillPaymentsSectionState();
}

class _CardBillPaymentsSectionState extends State<CardBillPaymentsSection> {
  bool _merging = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !SchemaCapabilities.creditCards) return;
      final String? userId = context.read<AuthProvider?>()?.userId;
      if (userId != null) context.read<CreditCardProvider?>()?.load(userId: userId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // Shown only where the app's card and account state is at hand.
    final CreditCardProvider? cards = context.watch<CreditCardProvider?>();
    final BankAccountProvider? accounts = context.watch<BankAccountProvider?>();
    final String currency = context.watch<SettingsProvider>().currency;
    if (!SchemaCapabilities.creditCards || cards == null || !cards.hasCards) {
      return const SizedBox.shrink();
    }
    final List<CardBillPaymentRow> rows = cards.billPayments(
      accounts: accounts?.accounts ?? const <BankAccount>[],
      from: widget.from,
      to: widget.to,
      accountId: widget.accountId,
    );
    if (rows.isEmpty) return const SizedBox.shrink();
    String money(double v) => Formatters.currency(v, currencyCode: currency);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(height: widget.gap),
        SectionHeader(title: widget.title, caption: '${rows.length}'),
        SurfaceCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: <Widget>[
              for (int i = 0; i < rows.length; i++) ...<Widget>[
                if (i > 0) const Divider(height: 1, indent: AppSpacing.md),
                _PaymentRow(
                  row: rows[i],
                  currency: currency,
                  onMerge: rows[i].possibleDuplicate &&
                          SchemaCapabilities.cardAccounting &&
                          !_merging
                      ? () => _merge(rows[i], rows, money)
                      : null,
                ),
              ],
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Text(
                  'Total paid to cards: ${money(billPaymentsTotal(rows))} — not counted as spending',
                  style: theme.textTheme.labelSmall,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Keeps the bank payment of a pair and removes the card-only copy — after
  /// the user confirms. Nothing else changes.
  Future<void> _merge(
    CardBillPaymentRow row,
    List<CardBillPaymentRow> rows,
    String Function(double) money,
  ) async {
    CardBillPaymentRow? other;
    for (final CardBillPaymentRow r in rows) {
      if (r.id == row.duplicateOfId) other = r;
    }
    final CardBillPaymentRow bank = row.source == BillPaymentSource.bank ? row : (other ?? row);
    final CardBillPaymentRow card = row.source == BillPaymentSource.card ? row : (other ?? row);
    // The other record may fall outside the period shown: read it off its key.
    final String cardTxnId = card.source == BillPaymentSource.card
        ? card.entryId
        : (row.duplicateOfId ?? '').replaceFirst('card:', '');
    final String bankEntryId = bank.source == BillPaymentSource.bank
        ? bank.entryId
        : (row.duplicateOfId ?? '').replaceFirst('account:', '');
    if (cardTxnId.isEmpty || bankEntryId.isEmpty) return;
    final String bankText = bank.source == BillPaymentSource.bank
        ? '${money(bank.amount)} from ${bank.accountLabel} on ${Formatters.dayMonthYear(bank.date)}'
        : 'The bank payment';
    final String cardText = card.source == BillPaymentSource.card
        ? '${money(card.amount)} on the card on ${Formatters.dayMonthYear(card.date)}'
        : 'the card-only payment';
    final bool ok = await AppFeedback.confirm(
      context,
      title: 'Merge duplicate payment?',
      message: '$bankText and $cardText look like the same bill payment. Keep the bank '
          'payment and remove the card-only copy? The card outstanding then counts it '
          'once. Nothing else changes.',
      confirmLabel: 'Merge',
      destructive: false,
    );
    if (!ok || !mounted) return;
    setState(() => _merging = true);
    final CreditCardProvider cards = context.read<CreditCardProvider>();
    final bool merged = await cards.mergePayments(
      bankEntryId: bankEntryId,
      cardTransactionId: cardTxnId,
    );
    if (!mounted) return;
    setState(() => _merging = false);
    if (merged) {
      context.read<BankAccountProvider>().invalidate();
      AppFeedback.success(context, 'Duplicate payment merged');
    } else {
      AppFeedback.error(context, cards.errorMessage ?? 'Could not merge the payments.');
    }
  }
}

class _PaymentRow extends StatelessWidget {
  const _PaymentRow({required this.row, required this.currency, this.onMerge});

  final CardBillPaymentRow row;
  final String currency;
  final VoidCallback? onMerge;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              row.source == BillPaymentSource.bank
                  ? Icons.account_balance_outlined
                  : Icons.credit_card_rounded,
              size: AppSpacing.iconMd,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '${row.accountLabel} → ${row.cardLabel}',
                  style: theme.textTheme.bodyMedium,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '${Formatters.dayDate(row.date)} · ${row.status.label}',
                  style: theme.textTheme.labelSmall,
                ),
                if (row.possibleDuplicate) ...<Widget>[
                  const SizedBox(height: AppSpacing.xs),
                  // A line of its own, so it never crowds a 360 dp row.
                  Text(
                    possibleDuplicateLabel,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: ToneColors.warning(context),
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (onMerge != null)
                    AppButton(
                      label: 'Merge',
                      icon: Icons.merge_rounded,
                      size: AppButtonSize.small,
                      variant: AppButtonVariant.ghost,
                      onPressed: onMerge,
                    ),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          MoneyText(row.amount, currency: currency, tone: AmountTone.transfer),
        ],
      ),
    );
  }
}
