import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../models/bank_account.dart';
import '../../providers/auth_provider.dart';
import '../../providers/bank_account_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/schema_capabilities.dart';
import '../../widgets/category_avatar.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/app_sheet.dart';
import '../../widgets/common/hero_surface.dart';
import '../../widgets/common/money_text.dart';
import '../../widgets/common/state_views.dart';
import '../../widgets/common/surface_card.dart';
import 'account_form_sheet.dart';
import 'account_statement_screen.dart';
import 'deposit_sheet.dart';
import 'transfer_sheet.dart';

/// Bank accounts, presented the way a banking app presents them.
///
/// One total at the top, then a card per account with its balance dominant
/// and its two common actions inline. Cash is intentionally absent: it is not
/// an account and never carries a balance.
class AccountsScreen extends StatefulWidget {
  const AccountsScreen({super.key});

  @override
  State<AccountsScreen> createState() => _AccountsScreenState();
}

class _AccountsScreenState extends State<AccountsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load({bool force = false}) async {
    if (!mounted) return;
    final String? userId = context.read<AuthProvider>().userId;
    if (userId == null) return;
    await context
        .read<BankAccountProvider>()
        .load(userId: userId, force: force);
  }

  @override
  Widget build(BuildContext context) {
    final BankAccountProvider provider = context.watch<BankAccountProvider>();
    final SettingsProvider settings = context.watch<SettingsProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Accounts'),
        actions: <Widget>[
          if (provider.canTransfer)
            IconButton(
              tooltip: 'Transfer',
              onPressed: () => _openTransfer(),
              icon: const Icon(Icons.swap_horiz_rounded),
            ),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      floatingActionButton: provider.available && provider.hasAccounts
          ? AppFab(
              heroTag: 'account_fab',
              onPressed: () => _openForm(null),
              label: 'Account',
            )
          : null,
      body: _buildBody(provider, settings),
    );
  }

  Widget _buildBody(
    BankAccountProvider provider,
    SettingsProvider settings,
  ) {
    if (!provider.available) {
      return ScrollableCentered(
        child: _MigrationRequired(onRecheck: () => _load(force: true)),
      );
    }

    if (provider.isInitialLoad) return const ListSkeleton(rows: 4);

    if (provider.hasError && !provider.hasAccounts) {
      return ScrollableCentered(
        child: ErrorView(
          message: provider.errorMessage!,
          onRetry: () => _load(force: true),
        ),
      );
    }

    if (!provider.hasAccounts) {
      return ScrollableCentered(
        child: EmptyState(
          icon: Icons.account_balance_outlined,
          title: 'No accounts yet',
          message: 'Add an account to track its balance and see a full '
              'transaction statement.',
          actionLabel: 'Add account',
          onAction: () => _openForm(null),
        ),
      );
    }

    final String currency = settings.currency;

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
            total: provider.totalBalance,
            accountCount: provider.balances.length,
            currency: currency,
          ),
          if (provider.transfersAvailable) ...<Widget>[
            const SizedBox(height: AppSpacing.md),
            Align(
              alignment: Alignment.centerLeft,
              child: AppButton(
                label: provider.canTransfer
                    ? 'Transfer'
                    : 'Add a second account to transfer',
                icon: Icons.swap_horiz_rounded,
                variant: AppButtonVariant.tonal,
                onPressed: provider.canTransfer ? _openTransfer : null,
              ),
            ),
          ] else ...<Widget>[
            const SizedBox(height: AppSpacing.md),
            const AppNotice(
              icon: Icons.swap_horiz_rounded,
              message: 'Transfers need supabase/003_phase2_transfers.sql. '
                  'Everything else here works without it.',
            ),
          ],
          const SizedBox(height: AppSpacing.section),
          const SectionHeader(title: 'Your accounts'),
          for (final BankAccountBalance balance
              in provider.balances) ...<Widget>[
            _AccountCard(
              balance: balance,
              currency: currency,
              onOpen: () => _openStatement(balance.account),
              onDeposit: () => _openDeposit(balance.account),
              onTransfer: provider.canTransfer
                  ? () => _openTransfer(from: balance.account)
                  : null,
              onEdit: () => _openForm(balance.account),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Cash is tracked separately and never affects these balances.',
            style: Theme.of(context).textTheme.labelSmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Future<void> _openForm(BankAccount? account) async {
    final bool? changed = await showAppSheet<bool>(
      context: context,
      builder: (_) => AccountFormSheet(account: account),
    );
    if (changed == true) await _load(force: true);
  }

  Future<void> _openDeposit(BankAccount account) async {
    final bool? changed = await showAppSheet<bool>(
      context: context,
      builder: (_) => DepositSheet(account: account),
    );
    if (changed == true) await _load(force: true);
  }

  Future<void> _openTransfer({BankAccount? from}) async {
    final bool? changed = await showAppSheet<bool>(
      context: context,
      builder: (_) => TransferSheet(fromAccount: from),
    );
    if (changed == true) await _load(force: true);
  }

  Future<void> _openStatement(BankAccount account) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AccountStatementScreen(account: account),
      ),
    );
    if (mounted) await _load(force: true);
  }
}

/// Combined balance across every account.
class _TotalCard extends StatelessWidget {
  const _TotalCard({
    required this.total,
    required this.accountCount,
    required this.currency,
  });

  final double total;
  final int accountCount;
  final String currency;

  @override
  Widget build(BuildContext context) {
    // Builder so everything inside reads the hero's dark theme.
    return HeroSurface(
      child: Builder(builder: _content),
    );
  }

  Widget _content(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                'TOTAL BALANCE',
                style: AppTypography.eyebrow(
                  theme.textTheme,
                  color: AppColors.tan,
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              MoneyText(
                total,
                currency: currency,
                fit: true,
                tone: total < 0 ? AmountTone.negative : AmountTone.neutral,
                style: theme.textTheme.displaySmall,
              ),
              const SizedBox(height: AppSpacing.xxs),
              Text(
                'Across $accountCount '
                '${accountCount == 1 ? 'account' : 'accounts'}',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        const IconWell(
          icon: Icons.account_balance_rounded,
          tone: AppColors.tan,
          size: 44,
        ),
      ],
    );
  }
}

/// One account: identity, balance, and the two actions people actually use.
class _AccountCard extends StatelessWidget {
  const _AccountCard({
    required this.balance,
    required this.currency,
    required this.onOpen,
    required this.onDeposit,
    required this.onTransfer,
    required this.onEdit,
  });

  final BankAccountBalance balance;
  final String currency;
  final VoidCallback onOpen;
  final VoidCallback onDeposit;
  final VoidCallback? onTransfer;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final BankAccount account = balance.account;

    return SurfaceCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          InkWell(
            onTap: onOpen,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Row(
                children: <Widget>[
                  BankAvatar(initial: account.initial, size: 42),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          account.nickname,
                          style: theme.textTheme.titleMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: AppSpacing.xxs),
                        Text(
                          account.last4 == null
                              ? account.bankName
                              : '${account.bankName} •••• ${account.last4}',
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
                        balance.currentBalance,
                        currency: currency,
                        tone: balance.isOverdrawn
                            ? AmountTone.negative
                            : AmountTone.neutral,
                        style: theme.textTheme.headlineSmall,
                      ),
                      const SizedBox(height: AppSpacing.xxs),
                      Text(
                        'Available',
                        style: theme.textTheme.labelSmall,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          // Icons alone. Four labelled actions could not fit one line without
          // shrinking the type below readable, and these four glyphs are
          // unambiguous. The name survives as a tooltip and as the
          // accessibility label, so nothing is lost to a screen reader.
          Row(
            children: <Widget>[
              _CardAction(
                icon: Icons.receipt_long_outlined,
                label: 'Statement',
                onTap: onOpen,
              ),
              _divider(context),
              _CardAction(
                icon: Icons.add_rounded,
                label: 'Add money',
                onTap: onDeposit,
              ),
              _divider(context),
              if (onTransfer != null) ...<Widget>[
                _CardAction(
                  icon: Icons.swap_horiz_rounded,
                  label: 'Transfer',
                  onTap: onTransfer!,
                ),
                _divider(context),
              ],
              _CardAction(
                icon: Icons.edit_outlined,
                label: 'Edit',
                onTap: onEdit,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _divider(BuildContext context) => Container(
        width: 1,
        height: 22,
        color: Theme.of(context).colorScheme.outline,
      );
}

/// One icon-only action in an account card's footer bar.
class _CardAction extends StatelessWidget {
  const _CardAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;

  /// Not painted. Carried as the tooltip and the semantic label, which is
  /// the whole reason an icon-only control stays usable.
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Expanded(
      child: Tooltip(
        message: label,
        child: Semantics(
          button: true,
          label: label,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              // Full touch target: without a label beside it the glyph is the
              // only thing to aim at, so the row cannot be as short as it was
              // when it also carried text.
              height: AppSpacing.minTouch,
              child: Icon(
                icon,
                size: AppSpacing.iconMd,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown until the Phase 2 migration has been applied.
class _MigrationRequired extends StatelessWidget {
  const _MigrationRequired({required this.onRecheck});

  final VoidCallback onRecheck;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

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
            'Bank accounts need the Phase 2 tables. Run '
            'supabase/002_phase2_bank_accounts_and_ledger.sql and then '
            'supabase/003_phase2_transfers.sql in the Supabase SQL editor.',
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
