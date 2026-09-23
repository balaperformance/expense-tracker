import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/config/app_config.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../providers/ai_chat_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/bank_account_provider.dart';
import '../../providers/budget_provider.dart';
import '../../providers/dashboard_provider.dart';
import '../../providers/expense_provider.dart';
import '../../providers/income_provider.dart';
import '../../providers/reports_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/dev_auth_bypass.dart';
import '../../services/export/export_models.dart';
import '../../widgets/common/app_feedback.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/app_sheet.dart';
import '../../widgets/common/money_text.dart';
import '../../widgets/common/surface_card.dart';
import '../accounts/accounts_screen.dart';
import '../assistant/ai_chat_screen.dart';
import '../export/export_screen.dart';
import 'budgets_screen.dart';
import 'change_password_sheet.dart';
import 'categories_screen.dart';
import 'payment_methods_screen.dart';

/// Settings.
///
/// Grouped into Money, Appearance and About, with secondary detail kept
/// visually quiet — this screen should be scannable in one pass rather than
/// read.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final SettingsProvider settings = context.watch<SettingsProvider>();
    final AuthProvider auth = context.watch<AuthProvider>();
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.page,
          AppSpacing.sm,
          AppSpacing.page,
          AppSpacing.bottomListPaddingNoFab,
        ),
        children: <Widget>[
          // ---------------------------------------------------------------
          // Profile
          // ---------------------------------------------------------------
          SurfaceCard(
            onTap: () => _editName(context, settings),
            radius: AppSpacing.radiusXl,
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Row(
              children: <Widget>[
                _ProfileAvatar(initial: settings.profile?.initial ?? '?'),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        settings.profile?.fullName ?? 'Add your name',
                        style: theme.textTheme.headlineSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: AppSpacing.xxs),
                      Text(
                        auth.user?.email ?? 'Signed in',
                        style: theme.textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: ToneColors.wash(context, theme.colorScheme.primary),
                  ),
                  child: Icon(
                    Icons.edit_outlined,
                    size: AppSpacing.iconSm,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.section),

          // ---------------------------------------------------------------
          // Security
          // ---------------------------------------------------------------
          // Offered only to an account that has a password at all. An
          // anonymous development session has none, and showing a row that
          // could only ever fail would be worse than not showing it.
          if (auth.user?.email != null) ...<Widget>[
            const SectionHeader(title: 'Security'),
            CardList(
              dividerIndent:
                  AppSpacing.avatarSm + AppSpacing.md + AppSpacing.md,
              children: <Widget>[
                _row(
                  context,
                  icon: Icons.password_rounded,
                  title: 'Change password',
                  subtitle: 'Confirm your current password, then set a new one',
                  onTap: () => openChangePassword(context),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.section),
          ],

          // ---------------------------------------------------------------
          // Assistant
          // ---------------------------------------------------------------
          const SectionHeader(title: 'Assistant'),
          CardList(
            dividerIndent: AppSpacing.avatarSm + AppSpacing.md + AppSpacing.md,
            children: <Widget>[
              _row(
                context,
                icon: Icons.auto_awesome_outlined,
                title: 'Ask the assistant',
                subtitle: 'Totals, balances, budgets — or record an entry',
                onTap: () => _openAssistant(context),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.section),

          // ---------------------------------------------------------------
          // Money
          // ---------------------------------------------------------------
          const SectionHeader(title: 'Money'),
          CardList(
            dividerIndent: AppSpacing.avatarSm + AppSpacing.md + AppSpacing.md,
            children: <Widget>[
              _row(
                context,
                icon: Icons.account_balance_outlined,
                title: 'Bank accounts',
                subtitle: 'Balances, statements and transfers',
                onTap: () => _push(context, const AccountsScreen()),
              ),
              _row(
                context,
                icon: Icons.donut_small_outlined,
                title: 'Budgets',
                subtitle: 'Monthly limits',
                onTap: () => _push(context, const BudgetsScreen()),
              ),
              _row(
                context,
                icon: Icons.category_outlined,
                title: 'Categories',
                subtitle: 'Organise your spending',
                onTap: () => _push(context, const CategoriesScreen()),
              ),
              _row(
                context,
                icon: Icons.credit_card_outlined,
                title: 'Payment methods',
                subtitle: 'Cash, cards, UPI and more',
                onTap: () => _push(context, const PaymentMethodsScreen()),
              ),
              _row(
                context,
                icon: Icons.currency_exchange_rounded,
                title: 'Currency',
                subtitle: 'Used for every amount in the app',
                trailing: AppBadge(
                  label: '${settings.currency}  ${settings.currencySymbol}',
                ),
                onTap: () => _pickCurrency(context, settings),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.section),

          // ---------------------------------------------------------------
          // Data & Export
          // ---------------------------------------------------------------
          const SectionHeader(title: 'Data & Export'),
          CardList(
            dividerIndent: AppSpacing.avatarSm + AppSpacing.md + AppSpacing.md,
            children: <Widget>[
              _row(
                context,
                icon: Icons.ios_share_rounded,
                title: 'Export a report',
                subtitle: 'Statements, expenses, income and summaries',
                onTap: () => _push(
                  context,
                  const ExportScreen(initialType: ExportReportType.spendingReport),
                ),
              ),
              _row(
                context,
                icon: Icons.description_outlined,
                title: 'Export bank statement',
                subtitle: 'One account, with a running balance',
                onTap: () => _push(
                  context,
                  const ExportScreen(initialType: ExportReportType.bankStatement),
                ),
              ),
              _row(
                context,
                icon: Icons.table_chart_outlined,
                title: 'Export transactions',
                subtitle: 'Every expense or income entry as CSV or PDF',
                onTap: () => _push(
                  context,
                  const ExportScreen(initialType: ExportReportType.expenses),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          const AppNotice(
            icon: Icons.download_done_outlined,
            message: 'Exports are generated on this device and handed straight '
                'to the share sheet. Nothing is uploaded.',
          ),
          const SizedBox(height: AppSpacing.section),

          // ---------------------------------------------------------------
          // Appearance
          // ---------------------------------------------------------------
          const SectionHeader(title: 'Appearance'),
          SurfaceCard(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text('Theme', style: theme.textTheme.labelMedium),
                const SizedBox(height: AppSpacing.sm),
                // A segmented control rather than three radio rows: one tap
                // instead of two, in a third of the height.
                SegmentedButton<ThemeMode>(
                  segments: const <ButtonSegment<ThemeMode>>[
                    ButtonSegment<ThemeMode>(
                      value: ThemeMode.system,
                      label: Text('System'),
                      icon: Icon(Icons.brightness_auto_outlined, size: 15),
                    ),
                    ButtonSegment<ThemeMode>(
                      value: ThemeMode.light,
                      label: Text('Light'),
                      icon: Icon(Icons.light_mode_outlined, size: 15),
                    ),
                    ButtonSegment<ThemeMode>(
                      value: ThemeMode.dark,
                      label: Text('Dark'),
                      icon: Icon(Icons.dark_mode_outlined, size: 15),
                    ),
                  ],
                  selected: <ThemeMode>{settings.themeMode},
                  showSelectedIcon: false,
                  onSelectionChanged: (Set<ThemeMode> value) =>
                      settings.setThemeMode(value.first),
                ),
              ],
            ),
          ),

          // ---------------------------------------------------------------
          // Development
          // ---------------------------------------------------------------
          if (AppConfig.bypassAuth) ...<Widget>[
            const SizedBox(height: AppSpacing.section),
            const SectionHeader(title: 'Development'),
            AppNotice(
              icon: Icons.developer_mode_rounded,
              tone: ToneColors.warning(context),
              message: 'Auth bypass is ON — signed in via '
                  '${DevSessionBadge.source?.label ?? 'unknown'}. '
                  'Release builds always use the normal login.',
            ),
          ],

          // ---------------------------------------------------------------
          // About
          // ---------------------------------------------------------------
          const SizedBox(height: AppSpacing.section),
          const SectionHeader(title: 'About'),
          CardList(
            dividerIndent: AppSpacing.avatarSm + AppSpacing.md + AppSpacing.md,
            children: <Widget>[
              _row(
                context,
                icon: Icons.info_outline_rounded,
                title: AppConstants.appName,
                subtitle: 'Version ${AppConstants.appVersion}',
                onTap: () => _showAbout(context),
              ),
              _row(
                context,
                icon: Icons.logout_rounded,
                title: 'Sign out',
                subtitle: 'You will need to sign in again',
                destructive: true,
                onTap: () => _signOut(context),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// One settings row. Keeps the icon well, density and chevron identical
  /// across every group.
  Widget _row(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    Widget? trailing,
    bool destructive = false,
  }) {
    final ThemeData theme = Theme.of(context);

    return AppListRow(
      leading: IconWell(
        icon: icon,
        tone: destructive
            ? theme.colorScheme.error
            : theme.colorScheme.primary,
        size: AppSpacing.avatarSm,
      ),
      title: title,
      subtitle: subtitle,
      tone: destructive ? theme.colorScheme.error : null,
      trailing: trailing,
      showChevron: trailing == null,
      onTap: onTap,
    );
  }

  void _push(BuildContext context, Widget screen) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => screen),
    );
  }

  /// Mirrors the dashboard: if the assistant recorded anything, the cached
  /// figures behind every other tab are stale.
  Future<void> _openAssistant(BuildContext context) async {
    final AiChatProvider chat = context.read<AiChatProvider>();
    final int before = chat.dataRevision;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const AiChatScreen()),
    );
    if (!context.mounted || chat.dataRevision == before) return;
    context.read<ExpenseProvider>().refresh();
    context.read<IncomeProvider>().refresh();
    context.read<BankAccountProvider>().invalidate();
    context.read<DashboardProvider>().invalidate();
    context.read<BudgetProvider>().invalidate();
    context.read<ReportsProvider>().invalidate();
  }

  Future<void> _editName(
    BuildContext context,
    SettingsProvider settings,
  ) async {
    final TextEditingController controller =
        TextEditingController(text: settings.profile?.fullName ?? '');

    final String? name = await showAppDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Your name'),
          content: TextField(
            controller: controller,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(hintText: 'Full name'),
            onSubmitted: (String value) =>
                Navigator.of(dialogContext).pop(value),
          ),
          actions: <Widget>[
            AppButtonRow(
              expand: false,
              onCancel: () => Navigator.of(dialogContext).pop(),
              confirmLabel: 'Save',
              onConfirm: () =>
                  Navigator.of(dialogContext).pop(controller.text),
            ),
          ],
        );
      },
    );

    controller.dispose();

    if (name == null || name.trim().isEmpty || !context.mounted) return;

    final bool ok = await settings.updateName(name);
    if (!context.mounted) return;

    if (ok) {
      AppFeedback.success(context, 'Name updated');
    } else {
      AppFeedback.error(
        context,
        settings.errorMessage ?? 'Could not update your name.',
      );
    }
  }

  Future<void> _pickCurrency(
    BuildContext context,
    SettingsProvider settings,
  ) async {
    final String? picked = await showAppSheet<String>(
      context: context,
      builder: (BuildContext sheetContext) {
        final ThemeData theme = Theme.of(sheetContext);
        return AppSheet(
          title: 'Currency',
          subtitle: 'Applies to every amount in the app',
          children: <Widget>[
            CardList(
              dividerIndent: AppSpacing.md,
              children: AppConstants.supportedCurrencies.entries
                  .map((MapEntry<String, String> entry) {
                final bool selected = entry.key == settings.currency;
                return AppListRow(
                  title: entry.key,
                  subtitle: entry.value,
                  dense: true,
                  onTap: () => Navigator.of(sheetContext).pop(entry.key),
                  trailing: selected
                      ? Icon(
                          Icons.check_circle_rounded,
                          size: AppSpacing.iconMd,
                          color: theme.colorScheme.primary,
                        )
                      : null,
                );
              }).toList(),
            ),
          ],
        );
      },
    );

    if (picked == null || !context.mounted) return;

    final bool ok = await settings.updateCurrency(picked);
    if (!context.mounted) return;

    if (!ok) {
      AppFeedback.error(
        context,
        settings.errorMessage ?? 'Could not change the currency.',
      );
    }
  }

  void _showAbout(BuildContext context) {
    showAboutDialog(
      context: context,
      applicationName: AppConstants.appName,
      applicationVersion: AppConstants.appVersion,
      applicationIcon: Icon(
        Icons.account_balance_wallet_rounded,
        size: 32,
        color: Theme.of(context).colorScheme.primary,
      ),
      children: <Widget>[
        const SizedBox(height: AppSpacing.md),
        const Text(
          'A private expense tracker. Your data lives in your own Supabase '
          'project and is protected by row-level security.',
        ),
      ],
    );
  }

  Future<void> _signOut(BuildContext context) async {
    final bool confirmed = await AppFeedback.confirm(
      context,
      title: 'Sign out?',
      message: 'You will need your email and password to sign back in.',
      confirmLabel: 'Sign out',
      destructive: false,
    );

    if (!confirmed || !context.mounted) return;
    await context.read<AuthProvider>().signOut();
  }
}

/// The profile initial on a deep-olive disc with an olive-gray ring — the same
/// material as the brand mark, so the account reads as part of the app.
class _ProfileAvatar extends StatelessWidget {
  const _ProfileAvatar({required this.initial});

  final String initial;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 54,
      height: 54,
      padding: const EdgeInsets.all(2.5),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.accent, width: 1.2),
      ),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: AppColors.heroLight,
          ),
        ),
        child: Center(
          child: Text(
            initial,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: AppColors.heroAccent,
                ),
          ),
        ),
      ),
    );
  }
}
