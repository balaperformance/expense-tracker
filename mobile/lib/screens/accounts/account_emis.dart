import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/money.dart';
import '../../models/bank_account.dart';
import '../../models/emi_plan.dart';
import '../../providers/credit_card_provider.dart';
import '../../providers/settings_provider.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/app_sheet.dart';
import '../../widgets/common/surface_card.dart';
import '../cards/emi_plan_sheet.dart';

/// The EMIs paid from one bank account (migration 020): each with what is
/// still pending — which falls by itself as every month's EMI expense is
/// recorded — and whatever else is known about it. Everything but the name
/// is optional, so a row shows only what was given.
class AccountEmis extends StatelessWidget {
  const AccountEmis({super.key, required this.account});

  final BankAccount account;

  Future<void> _open(BuildContext context, EmiPlan? plan) =>
      showAppSheet<bool>(
        context: context,
        builder: (_) => EmiPlanSheet(account: account, plan: plan),
      );

  /// The total still pending across the account's EMIs, else how many run.
  String _caption(
    CreditCardProvider cards,
    List<EmiPlan> plans,
    int running,
    String currency,
  ) {
    if (plans.isEmpty) return 'Loans and purchases paid from this account';
    int cents = 0;
    bool any = false;
    for (final EmiPlan plan in plans.where((EmiPlan p) => !p.isClosed)) {
      final double? left = cards.pendingLeftFor(plan);
      if (left == null) continue;
      any = true;
      cents += toCents(left);
    }
    return any
        ? emiPendingText(cents / 100, (double v) => Formatters.currency(v, currencyCode: currency))!
        : '$running running';
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final CreditCardProvider cards = context.watch<CreditCardProvider>();
    final String currency = context.watch<SettingsProvider>().currency;
    final List<EmiPlan> plans = cards.plansForAccount(account.id);
    final int running = plans.where((EmiPlan p) => !p.isClosed).length;

    return SurfaceCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.md, AppSpacing.md, AppSpacing.sm, 0),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('EMIs', style: theme.textTheme.titleSmall),
                      Text(
                        _caption(cards, plans, running, currency),
                        style: theme.textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
                AppButton(
                  label: 'Add',
                  icon: Icons.add_rounded,
                  size: AppButtonSize.small,
                  variant: AppButtonVariant.ghost,
                  onPressed: () => _open(context, null),
                ),
              ],
            ),
          ),
          if (plans.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.md),
              child: Text(
                'Add an EMI paid from this account, enter what is pending, and '
                "pick it when you record each month's EMI — the pending "
                'amount goes down by itself.',
                style: theme.textTheme.bodySmall,
              ),
            )
          else
            for (int i = 0; i < plans.length; i++) ...<Widget>[
              if (i > 0)
                const Divider(height: 1, indent: AppSpacing.rowDividerIndent),
              _EmiRow(
                plan: plans[i],
                left: cards.pendingLeftFor(plans[i]),
                payments: cards.paymentsFor(plans[i]),
                currency: currency,
                onTap: () => _open(context, plans[i]),
              ),
            ],
        ],
      ),
    );
  }
}

class _EmiRow extends StatelessWidget {
  const _EmiRow({
    required this.plan,
    required this.left,
    required this.payments,
    required this.currency,
    required this.onTap,
  });

  final EmiPlan plan;

  /// What is still pending; null when no pending amount was given.
  final double? left;

  /// EMI expenses recorded since the pending amount was set.
  final int payments;
  final String currency;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    String money(double v) =>
        Formatters.currency(v, currencyCode: currency, compact: true);
    final String? pending = emiPendingText(left, money);
    final int? tenure = plan.tenureMonths;
    // Only what is known: how far it has run, and the monthly amount.
    final String details = <String>[
      if (tenure != null && tenure > 0 && payments > 0)
        '$payments of $tenure months paid'
      else if (payments > 0)
        '$payments ${payments == 1 ? 'payment' : 'payments'} recorded',
      if (plan.monthlyAmount != null) '${money(plan.monthlyAmount!)} a month',
      if (plan.isClosed) 'closed',
    ].join(' · ');
    final Color tone = theme.colorScheme.primary;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding:
            const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 10),
        child: Row(
          children: <Widget>[
            IconWell(icon: Icons.all_inclusive_rounded, tone: tone),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(plan.title,
                      style: theme.textTheme.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  if (pending != null) ...<Widget>[
                    const SizedBox(height: AppSpacing.xxs),
                    Text(pending,
                        style: theme.textTheme.titleMedium
                            ?.copyWith(color: tone)),
                  ],
                  if (details.isNotEmpty) ...<Widget>[
                    const SizedBox(height: AppSpacing.xxs),
                    Text(details,
                        style: theme.textTheme.labelSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ],
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Icon(Icons.chevron_right_rounded,
                color: theme.colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
