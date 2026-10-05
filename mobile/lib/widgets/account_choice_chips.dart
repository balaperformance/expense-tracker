import 'package:flutter/material.dart';

import '../core/theme/app_spacing.dart';
import '../models/bank_account.dart';
import 'common/app_fields.dart';

/// The account a payment came from or went to, as one row of chips.
///
/// The [noneLabel] chip (null: no account) leads by default — "Cash" on an
/// expense, the safe choice that moves no balance. Once the user keeps a cash
/// balance (migration 011) that account leads instead, with the cash glyph,
/// and a "Cash" null chip becomes "Not tracked" at the end: the app would
/// otherwise offer two different "Cash" choices. Same order as the web app.
class AccountChoiceChips extends StatelessWidget {
  const AccountChoiceChips({
    super.key,
    required this.accounts,
    required this.selectedId,
    required this.onSelected,
    this.enabled = true,
    this.noneLabel = 'Cash',
    this.fullLabels = false,
  });

  final List<BankAccount> accounts;
  final String? selectedId;
  final ValueChanged<String?> onSelected;
  final bool enabled;
  final String noneLabel;

  /// "Nickname •••• 1234" rather than the nickname alone.
  final bool fullLabels;

  @override
  Widget build(BuildContext context) {
    final BankAccount? cash = BankAccount.cashOf(accounts);
    final List<BankAccount> ordered = cash == null
        ? accounts
        : <BankAccount>[cash, ...accounts.where((BankAccount a) => a.id != cash.id)];
    final String untracked =
        cash != null && noneLabel == 'Cash' ? 'Not tracked' : noneLabel;
    final Widget none = AppChoiceChip(
      label: untracked,
      icon: untracked == 'Cash' ? Icons.payments_outlined : null,
      selected: selectedId == null,
      enabled: enabled,
      onSelected: () => onSelected(null),
    );

    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: <Widget>[
        if (cash == null) none,
        for (final BankAccount account in ordered)
          AppChoiceChip(
            label: fullLabels ? account.displayLabel : account.nickname,
            icon: account.isCash
                ? Icons.payments_outlined
                : Icons.account_balance_outlined,
            selected: selectedId == account.id,
            enabled: enabled,
            onSelected: () => onSelected(account.id),
          ),
        if (cash != null) none,
      ],
    );
  }
}
