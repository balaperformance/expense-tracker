import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/formatters.dart';
import '../../models/card_statement.dart';
import '../../models/credit_card.dart';
import '../../providers/auth_provider.dart';
import '../../providers/bank_account_provider.dart';
import '../../providers/credit_card_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/schema_capabilities.dart';
import '../../widgets/card_widgets.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/app_sheet.dart';
import '../../widgets/common/hero_surface.dart';
import '../../widgets/common/money_text.dart';
import '../../widgets/common/state_views.dart';
import '../../widgets/common/surface_card.dart';
import 'card_form_sheet.dart';
import 'card_payment_sheet.dart';
import 'card_statement_screen.dart';

/// Every credit card: what is owed, the headroom left and whether a bill is
/// due — compact, one card per tile, with its common actions inline.
class CreditCardsScreen extends StatefulWidget {
  const CreditCardsScreen({super.key});

  @override
  State<CreditCardsScreen> createState() => _CreditCardsScreenState();
}

class _CreditCardsScreenState extends State<CreditCardsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load({bool force = false}) async {
    if (!mounted) return;
    final String? userId = context.read<AuthProvider>().userId;
    if (userId == null) return;
    // Accounts are needed for the Pay bill sheet and the card form.
    await Future.wait(<Future<void>>[
      context.read<CreditCardProvider>().load(userId: userId, force: force),
      context.read<BankAccountProvider>().load(userId: userId),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final CreditCardProvider provider = context.watch<CreditCardProvider>();
    final String currency = context.watch<SettingsProvider>().currency;

    return Scaffold(
      appBar: AppBar(title: const Text('Credit cards')),
      floatingActionButton: provider.available && provider.hasCards
          ? AppFab(
              heroTag: 'card_fab',
              onPressed: () => _openForm(null),
              label: 'Card',
            )
          : null,
      body: _buildBody(provider, currency),
    );
  }

  Widget _buildBody(CreditCardProvider provider, String currency) {
    if (!provider.available) {
      return ScrollableCentered(
        child: _MigrationRequired(
          onRecheck: () => _load(force: true),
          hasError: provider.hasError,
          errorMessage: provider.errorMessage,
        ),
      );
    }
    if (provider.isInitialLoad) return const ListSkeleton(rows: 4);
    if (provider.hasError && !provider.hasCards) {
      return ScrollableCentered(
        child: ErrorView(
          message: provider.errorMessage!,
          onRetry: () => _load(force: true),
        ),
      );
    }
    if (!provider.hasCards) {
      return ScrollableCentered(
        child: EmptyState(
          icon: Icons.credit_card_rounded,
          title: 'No credit cards yet',
          message: 'Add a card to track what you owe on it, its bills and due '
              'dates, and a full statement.',
          actionLabel: 'Add card',
          onAction: () => _openForm(null),
        ),
      );
    }

    final List<CardOverview> all = provider.overviews;
    final List<CardOverview> active =
        all.where((CardOverview o) => o.card.isActive).toList();
    final List<CardOverview> inactive =
        all.where((CardOverview o) => !o.card.isActive).toList();
    // Everything owed counts, including a closed card still being paid off;
    // the limit and headroom only make sense for cards in use.
    final double owed = all.fold<double>(
        0, (double s, CardOverview o) => s + o.summary.outstanding);
    final double limit =
        active.fold<double>(0, (double s, CardOverview o) => s + o.card.creditLimit);
    final double available =
        active.fold<double>(0, (double s, CardOverview o) => s + o.summary.available);
    final double activeOwed = active.fold<double>(0,
        (double s, CardOverview o) => s + (o.summary.outstanding > 0 ? o.summary.outstanding : 0));

    return RefreshIndicator(
      onRefresh: () => _load(force: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.page,
          AppSpacing.sm,
          AppSpacing.page,
          AppSpacing.bottomListPaddingPage,
        ),
        children: <Widget>[
          _TotalCard(
            owed: owed,
            count: all.length,
            limit: limit,
            available: available,
            utilisation: limit > 0 ? activeOwed / limit : 0,
            currency: currency,
          ),
          for (final CardOverview o in all.where((CardOverview o) =>
              o.summary.lastStatement.status == DueStatus.overdue)) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            AppNotice(
              icon: Icons.warning_amber_rounded,
              tone: ToneColors.expense(context),
              message: '${o.card.displayLabel}: '
                  '${Formatters.currency(o.summary.lastStatement.remaining, currencyCode: currency)} '
                  '— ${o.summary.lastStatement.statusText.toLowerCase()}.',
            ),
          ],
          if (active.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppSpacing.section),
            const SectionHeader(title: 'Your cards'),
            for (final CardOverview o in active) ...<Widget>[
              _CardTile(
                overview: o,
                currency: currency,
                onOpen: () => _openStatement(o.card),
                onPay: () => _openPay(o),
                onEdit: () => _openForm(o.card),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
          ],
          if (inactive.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppSpacing.section),
            const SectionHeader(title: 'Inactive', caption: 'Kept for their history'),
            for (final CardOverview o in inactive) ...<Widget>[
              _CardTile(
                overview: o,
                currency: currency,
                onOpen: () => _openStatement(o.card),
                onPay: () => _openPay(o),
                onEdit: () => _openForm(o.card),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
          ],
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Card purchases count as spending when you make them. Paying the '
            'bill moves money from your account to the card, so it is not '
            'counted again.',
            style: Theme.of(context).textTheme.labelSmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Future<void> _openForm(CreditCard? card) async {
    final bool? changed = await showAppSheet<bool>(
      context: context,
      builder: (_) => CardFormSheet(card: card),
    );
    if (changed == true) await _load(force: true);
  }

  Future<void> _openPay(CardOverview overview) async {
    final bool? changed = await showAppSheet<bool>(
      context: context,
      builder: (_) => CardPaymentSheet(overview: overview),
    );
    if (changed == true) await _load(force: true);
  }

  Future<void> _openStatement(CreditCard card) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => CardStatementScreen(cardId: card.id)),
    );
    if (mounted) await _load(force: true);
  }
}

class _TotalCard extends StatelessWidget {
  const _TotalCard({
    required this.owed,
    required this.count,
    required this.limit,
    required this.available,
    required this.utilisation,
    required this.currency,
  });

  final double owed;
  final int count;
  final double limit;
  final double available;
  final double utilisation;
  final String currency;

  @override
  Widget build(BuildContext context) =>
      HeroSurface(child: Builder(builder: _content));

  Widget _content(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    'TOTAL OUTSTANDING',
                    style: AppTypography.eyebrow(
                      theme.textTheme,
                      color: AppColors.heroAccent,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  MoneyText(
                    owed,
                    currency: currency,
                    fit: true,
                    style: theme.textTheme.displaySmall,
                  ),
                  const SizedBox(height: AppSpacing.xxs),
                  Text(
                    'Across $count ${count == 1 ? 'card' : 'cards'}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            const IconWell(
              icon: Icons.credit_card_rounded,
              tone: AppColors.heroAccent,
              size: 44,
            ),
          ],
        ),
        if (limit > 0) ...<Widget>[
          const SizedBox(height: AppSpacing.md),
          UtilisationBar(ratio: utilisation),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: <Widget>[
              Expanded(child: _leg(context, 'Available', available, false)),
              _leg(context, 'Total limit', limit, true),
            ],
          ),
        ],
      ],
    );
  }

  Widget _leg(BuildContext context, String label, double value, bool end) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: end ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(label, style: theme.textTheme.labelSmall),
        MoneyText(value, currency: currency, style: theme.textTheme.titleSmall),
      ],
    );
  }
}

/// One card: identity, what is owed, headroom, bill status, actions.
class _CardTile extends StatelessWidget {
  const _CardTile({
    required this.overview,
    required this.currency,
    required this.onOpen,
    required this.onPay,
    required this.onEdit,
  });

  final CardOverview overview;
  final String currency;
  final VoidCallback onOpen;
  final VoidCallback onPay;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final CreditCard card = overview.card;
    final bool credit = overview.summary.hasCreditBalance;
    final double owed = overview.summary.outstanding;

    return SurfaceCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          InkWell(
            onTap: onOpen,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.md,
                AppSpacing.md,
                AppSpacing.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      const CardAvatar(size: 42),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Row(
                              children: <Widget>[
                                Flexible(
                                  child: Text(
                                    card.cardName,
                                    style: theme.textTheme.titleMedium,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (!card.isActive) ...<Widget>[
                                  const SizedBox(width: AppSpacing.xs),
                                  const AppBadge(label: 'Inactive'),
                                ],
                              ],
                            ),
                            const SizedBox(height: AppSpacing.xxs),
                            Text(
                              card.issuerLine,
                              style: theme.textTheme.bodySmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          MoneyText(
                            credit ? -owed : owed,
                            currency: currency,
                            tone: credit ? AmountTone.positive : AmountTone.neutral,
                            style: theme.textTheme.headlineSmall,
                          ),
                          Text(
                            credit ? 'Credit balance' : 'Outstanding',
                            style: theme.textTheme.labelSmall,
                          ),
                        ],
                      ),
                    ],
                  ),
                  if (card.creditLimit > 0) ...<Widget>[
                    const SizedBox(height: AppSpacing.md),
                    UtilisationBar(ratio: overview.summary.utilisation),
                    const SizedBox(height: AppSpacing.xs),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            overview.summary.overLimit > 0
                                ? '${Formatters.currency(overview.summary.overLimit, currencyCode: currency)} over the limit'
                                : '${Formatters.currency(overview.summary.available, currencyCode: currency)} available',
                            style: theme.textTheme.labelSmall,
                          ),
                        ),
                        Text(
                          'Limit ${Formatters.currency(card.creditLimit, currencyCode: currency, compact: true)}',
                          style: theme.textTheme.labelSmall,
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: AppSpacing.sm),
                  DueLine(summary: overview.summary, currency: currency),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Row(
            children: <Widget>[
              _TileAction(icon: Icons.receipt_long_outlined, label: 'Statement', onTap: onOpen),
              _TileAction(icon: Icons.swap_horiz_rounded, label: 'Pay bill', onTap: onPay),
              _TileAction(icon: Icons.edit_outlined, label: 'Edit', onTap: onEdit),
            ],
          ),
        ],
      ),
    );
  }
}

class _TileAction extends StatelessWidget {
  const _TileAction({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color tone = Theme.of(context).colorScheme.primary;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: AppSpacing.minTouch,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(icon, size: AppSpacing.iconMd - 2, color: tone),
              const SizedBox(width: AppSpacing.xs),
              // A third of a 360dp phone is tight once the text is scaled up.
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(color: tone),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MigrationRequired extends StatelessWidget {
  const _MigrationRequired({
    required this.onRecheck,
    required this.hasError,
    required this.errorMessage,
  });

  final VoidCallback onRecheck;
  final bool hasError;
  final String? errorMessage;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // A failed probe (offline, signed out) is not a missing migration.
    if (hasError && errorMessage != null) {
      return ErrorView(message: errorMessage!, onRetry: onRecheck);
    }
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xxl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          IconWell(
            icon: Icons.dataset_outlined,
            tone: theme.colorScheme.primary,
            size: 54,
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            'One migration away',
            style: theme.textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Credit cards need their tables. Run ui/supabase/'
            '004_credit_cards.sql in the Supabase SQL editor (after the bank '
            'account migrations 002 and 003).',
            style: theme.textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.lg),
          AppNotice(
            icon: Icons.dataset_outlined,
            message: 'Missing: ${SchemaCapabilities.missingSummary}',
          ),
          const SizedBox(height: AppSpacing.lg),
          AppButton(
            label: 'Check again',
            icon: Icons.refresh_rounded,
            onPressed: onRecheck,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Every other feature keeps working without this.',
            style: theme.textTheme.labelSmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
