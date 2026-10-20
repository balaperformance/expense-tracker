import 'package:flutter/material.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/utils/formatters.dart';
import '../../models/bank_account.dart';
import '../../models/credit_card.dart';
import '../../models/emi_reimbursement.dart';
import '../../models/receivable.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/app_fields.dart';
import '../../widgets/common/money_text.dart';
import '../../widgets/common/surface_card.dart';
import '../../widgets/paid_for_field.dart';

/// The "Card EMI reimbursement" half of the income form: which card and EMI
/// it pays back, who pays it, the account it arrived in, and what is still
/// owed after it. Holds no state of its own — the web app's
/// `EmiReimbursementFields`.
class EmiReimbursementFields extends StatelessWidget {
  const EmiReimbursementFields({
    super.key,
    required this.options,
    required this.cards,
    required this.cardId,
    required this.onCard,
    required this.planId,
    required this.onPlan,
    required this.person,
    required this.people,
    required this.accounts,
    required this.accountId,
    required this.onAccount,
    required this.amount,
    required this.onUseAmount,
    required this.note,
    required this.problem,
    required this.currency,
    required this.enabled,
  });

  final List<EmiReimbursementOption> options;
  final List<CreditCard> cards;
  final String? cardId;
  final ValueChanged<String?> onCard;
  final String? planId;
  final ValueChanged<String> onPlan;

  /// Who pays it back — asked for only when the chosen plan names no one.
  final TextEditingController person;
  final List<String> people;
  final List<BankAccount> accounts;
  final String? accountId;
  final ValueChanged<String> onAccount;
  final double? amount;
  final ValueChanged<double> onUseAmount;
  final TextEditingController note;

  /// What the last save attempt stopped at, to mark that field.
  final EmiReimbursementProblem? problem;
  final String currency;
  final bool enabled;

  String _money(double value, {bool compact = false}) =>
      Formatters.currency(value, currencyCode: currency, compact: compact);

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    if (options.isEmpty) {
      return const AppNotice(
        message: 'No EMI plan yet. Import a card statement from screenshots '
            '(its EMI rows become a plan), or add one from the card\'s screen '
            'and mark who pays it back.',
      );
    }
    final List<CreditCard> withPlans = cards
        .where((CreditCard c) =>
            options.any((EmiReimbursementOption o) => o.plan.cardId == c.id))
        .toList();
    final List<EmiReimbursementOption> shown = cardId == null
        ? options
        : options.where((EmiReimbursementOption o) => o.plan.cardId == cardId).toList();
    EmiReimbursementOption? option;
    for (final EmiReimbursementOption o in options) {
      if (o.plan.id == planId) option = o;
    }
    final ({double received, double left, ClaimStatus status, double rounding})? after =
        option == null ? null : afterReimbursement(option, amount);
    final List<BankAccount> usable =
        accounts.where((BankAccount a) => a.isActive).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (withPlans.length > 1) ...<Widget>[
          const FieldLabel('Credit card'),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: <Widget>[
              AppChoiceChip(
                label: 'All cards',
                selected: cardId == null,
                enabled: enabled,
                onSelected: () => onCard(null),
              ),
              for (final CreditCard c in withPlans)
                AppChoiceChip(
                  label: c.displayLabel,
                  selected: cardId == c.id,
                  enabled: enabled,
                  onSelected: () => onCard(c.id),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
        ],
        FieldLabel(
          'EMI it pays back',
          isRequired: true,
          hint: problem == EmiReimbursementProblem.plan ? 'Choose one' : null,
        ),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: <Widget>[
            for (final EmiReimbursementOption o in shown)
              AppChoiceChip(
                label: emiOptionLabel(o, (double v) => _money(v, compact: true)),
                selected: o.plan.id == planId,
                enabled: enabled,
                onSelected: () => onPlan(o.plan.id),
              ),
          ],
        ),
        if (option != null) ...<Widget>[
          if (option.plan.person == null) ...<Widget>[
            const SizedBox(height: AppSpacing.lg),
            FieldLabel(
              'Who pays it back',
              isRequired: true,
              hint: problem == EmiReimbursementProblem.person ? 'Add a name' : null,
            ),
            TextFormField(
              controller: person,
              enabled: enabled,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                hintText: 'Name',
                prefixIcon: Icon(Icons.person_outline_rounded, size: AppSpacing.iconMd),
              ),
            ),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: person,
              builder: (BuildContext context, TextEditingValue value, _) {
                final List<String> suggestions =
                    PaidForField.suggestionsFor(people, value.text);
                if (suggestions.isEmpty) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.sm),
                  child: Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
                    children: <Widget>[
                      for (final String p in suggestions)
                        AppChoiceChip(
                          label: p,
                          selected: false,
                          enabled: enabled,
                          onSelected: () => person.text = p,
                        ),
                    ],
                  ),
                );
              },
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          SurfaceCard(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  option.card == null
                      ? option.plan.title
                      : '${option.plan.title} · ${option.card!.displayLabel}',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '${_money(option.expected)} billed so far · '
                  '${_money(option.received)} received'
                  '${option.plan.person != null ? ' · ${option.status.label.toLowerCase()}' : ''}',
                  style: theme.textTheme.bodySmall,
                ),
                if (after != null) ...<Widget>[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    switch (after.status) {
                      ClaimStatus.settled => 'After this: fully reimbursed'
                          '${after.rounding > 0 ? ' (${_money(after.rounding)} rounding)' : ''}',
                      ClaimStatus.overpaid => 'After this: ${_money(-after.left)} more '
                          'than billed so far — more than rounding',
                      _ => 'After this: ${_money(after.left)} still owed',
                    },
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: switch (after.status) {
                        ClaimStatus.overpaid => theme.colorScheme.error,
                        ClaimStatus.settled => ToneColors.income(context),
                        _ => null,
                      },
                    ),
                  ),
                ],
                if (option.lastInstallment != null) ...<Widget>[
                  const SizedBox(height: AppSpacing.sm),
                  AppButton(
                    label: 'Use ${_money(option.lastInstallment!.amount)} · '
                        '${Formatters.dayMonth(option.lastInstallment!.date)} instalment',
                    icon: Icons.all_inclusive_rounded,
                    variant: AppButtonVariant.tonal,
                    size: AppButtonSize.small,
                    onPressed: enabled
                        ? () => onUseAmount(option!.lastInstallment!.amount)
                        : null,
                  ),
                ],
              ],
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        FieldLabel(
          'Received in',
          isRequired: true,
          hint: problem == EmiReimbursementProblem.account ? 'Choose the account' : null,
        ),
        if (usable.isEmpty)
          const AppNotice(
            message: 'Add a bank account (or a cash balance) first — a '
                'reimbursement is recorded on the account it arrived in.',
          )
        else
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: <Widget>[
              for (final BankAccount a in usable)
                AppChoiceChip(
                  label: a.nickname,
                  selected: accountId == a.id,
                  enabled: enabled,
                  onSelected: () => onAccount(a.id),
                ),
            ],
          ),
        const SizedBox(height: AppSpacing.lg),
        const FieldLabel('Note', hint: 'Optional'),
        TextFormField(
          controller: note,
          enabled: enabled,
          maxLines: 2,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            hintText: 'September instalment, UPI ref…',
            prefixIcon: Icon(Icons.short_text_rounded, size: AppSpacing.iconMd),
          ),
        ),
      ],
    );
  }
}
