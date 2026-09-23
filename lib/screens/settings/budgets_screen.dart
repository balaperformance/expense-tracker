import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/validators.dart';
import '../../models/budget.dart';
import '../../models/expense_category.dart';
import '../../providers/auth_provider.dart';
import '../../providers/budget_provider.dart';
import '../../providers/category_provider.dart';
import '../../providers/dashboard_provider.dart';
import '../../providers/settings_provider.dart';
import '../../widgets/budget_progress_tile.dart';
import '../../widgets/category_avatar.dart';
import '../../widgets/common/app_feedback.dart';
import '../../widgets/common/app_fields.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/app_sheet.dart';
import '../../widgets/common/state_views.dart';
import '../../widgets/common/surface_card.dart';
import '../../widgets/stat_tiles.dart';

/// Monthly spending limits.
///
/// One overall limit at the top, then per-category limits. Each is a compact
/// progress card rather than a decorative ring: the numbers are what matter,
/// and colour carries the warning.
class BudgetsScreen extends StatefulWidget {
  const BudgetsScreen({super.key});

  @override
  State<BudgetsScreen> createState() => _BudgetsScreenState();
}

class _BudgetsScreenState extends State<BudgetsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load({bool force = false}) async {
    if (!mounted) return;
    final String? userId = context.read<AuthProvider>().userId;
    if (userId == null) return;
    await context.read<BudgetProvider>().load(userId: userId, force: force);
  }

  @override
  Widget build(BuildContext context) {
    final BudgetProvider provider = context.watch<BudgetProvider>();
    final SettingsProvider settings = context.watch<SettingsProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Budgets'),
        actions: <Widget>[
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (String value) {
              if (value == 'copy') _copyPrevious();
            },
            itemBuilder: (_) => const <PopupMenuEntry<String>>[
              PopupMenuItem<String>(
                value: 'copy',
                child: Text('Copy last month'),
              ),
            ],
          ),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      floatingActionButton: AppFab(
        heroTag: 'budget_fab',
        onPressed: () => _openEditor(null),
        label: 'Budget',
      ),
      body: Column(
        children: <Widget>[
          MonthStepper(
            month: provider.month,
            onPrevious: () => _stepMonth(-1),
            onNext: () => _stepMonth(1),
          ),
          const Divider(height: 1),
          Expanded(child: _buildBody(provider, settings)),
        ],
      ),
    );
  }

  Widget _buildBody(BudgetProvider provider, SettingsProvider settings) {
    if (provider.isLoading && !provider.hasAny) {
      return const ListSkeleton(rows: 4);
    }

    if (provider.hasError && !provider.hasAny) {
      return ScrollableCentered(
        child: ErrorView(
          message: provider.errorMessage!,
          onRetry: () => _load(force: true),
        ),
      );
    }

    if (!provider.hasAny) {
      return ScrollableCentered(
        child: EmptyState(
          icon: Icons.donut_small_outlined,
          title: 'No budgets this month',
          message: 'Set an overall limit, or one per category, to track how '
              'much of your plan you have used.',
          actionLabel: 'Set a budget',
          onAction: () => _openEditor(null),
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
          AppSpacing.md,
          AppSpacing.page,
          AppSpacing.bottomListPaddingPage,
        ),
        children: <Widget>[
          if (provider.alerts.isNotEmpty) ...<Widget>[
            BudgetAlertBanner(
              alerts: provider.alerts,
              currency: currency,
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          if (provider.overall != null) ...<Widget>[
            const SectionHeader(title: 'Overall'),
            BudgetCard(
              progress: provider.overall!,
              currency: currency,
              showAvatar: false,
              onTap: () => _openEditor(provider.overall!.budget),
            ),
            const SizedBox(height: AppSpacing.section),
          ],
          if (provider.categoryBudgets.isNotEmpty) ...<Widget>[
            SectionHeader(
              title: 'By category',
              caption: '${provider.categoryBudgets.length}',
            ),
            for (final BudgetProgress progress
                in provider.categoryBudgets) ...<Widget>[
              BudgetCard(
                progress: progress,
                currency: currency,
                onTap: () => _openEditor(progress.budget),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
          ],
        ],
      ),
    );
  }

  Future<void> _stepMonth(int delta) async {
    final BudgetProvider provider = context.read<BudgetProvider>();
    provider.setMonth(
      DateTime(provider.month.year, provider.month.month + delta, 1),
    );
    await _load(force: true);
  }

  Future<void> _copyPrevious() async {
    final BudgetProvider provider = context.read<BudgetProvider>();
    final int copied = await provider.copyFromPreviousMonth();

    if (!mounted) return;

    if (copied < 0) {
      AppFeedback.error(
        context,
        provider.errorMessage ?? 'Could not copy last month.',
      );
    } else if (copied == 0) {
      AppFeedback.info(context, 'Nothing to copy from last month.');
    } else {
      AppFeedback.success(
        context,
        'Copied $copied ${copied == 1 ? 'budget' : 'budgets'}.',
      );
      _invalidateDashboard();
    }
  }

  Future<void> _openEditor(Budget? existing) async {
    final bool? changed = await showAppSheet<bool>(
      context: context,
      builder: (_) => BudgetEditorSheet(existing: existing),
    );

    if (changed == true && mounted) _invalidateDashboard();
  }

  void _invalidateDashboard() {
    context.read<DashboardProvider>().invalidate();
  }
}

/// Create, update or delete one budget.
class BudgetEditorSheet extends StatefulWidget {
  const BudgetEditorSheet({super.key, this.existing});

  final Budget? existing;

  @override
  State<BudgetEditorSheet> createState() => _BudgetEditorSheetState();
}

class _BudgetEditorSheetState extends State<BudgetEditorSheet> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _amount = TextEditingController(
    text: widget.existing == null ? '' : _trim(widget.existing!.amount),
  );

  late String? _categoryId = widget.existing?.categoryId;
  late final bool _isEditing = widget.existing != null;

  bool _saving = false;
  String? _error;

  static String _trim(double value) {
    final String text = value.toStringAsFixed(2);
    return text.endsWith('.00') ? text.substring(0, text.length - 3) : text;
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final SettingsProvider settings = context.watch<SettingsProvider>();
    final BudgetProvider budgets = context.watch<BudgetProvider>();
    final List<ExpenseCategory> categories =
        context.watch<CategoryProvider>().categories;

    // Categories that already have a budget this month, so the picker cannot
    // create a duplicate.
    final Set<String> taken = budgets.categoryBudgets
        .map((BudgetProgress p) => p.budget.categoryId)
        .whereType<String>()
        .where((String id) => id != widget.existing?.categoryId)
        .toSet();

    final List<ExpenseCategory> selectable = categories
        .where((ExpenseCategory c) => !taken.contains(c.id))
        .toList();

    return Form(
      key: _formKey,
      child: AppSheet(
        title: _isEditing ? 'Edit budget' : 'New budget',
        subtitle: Formatters.monthYear(budgets.month),
        action: _isEditing
            ? IconButton(
                tooltip: 'Delete budget',
                onPressed: _saving ? null : _delete,
                icon: const Icon(Icons.delete_outline_rounded),
                color: theme.colorScheme.error,
              )
            : null,
        footer: AppButton.submit(
          label: _isEditing ? 'Save changes' : 'Set budget',
          busy: _saving,
          busyLabel: 'Saving…',
          onPressed: _saving ? null : _save,
        ),
        children: <Widget>[
          AmountField(
            controller: _amount,
            symbol: settings.currencySymbol,
            enabled: !_saving,
            tone: theme.colorScheme.primary,
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            'Monthly limit',
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall,
          ),
          const SizedBox(height: AppSpacing.lg),

          FieldLabel(
            'Applies to',
            isRequired: true,
            hint: _isEditing ? 'Locked' : null,
          ),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: <Widget>[
              AppChoiceChip(
                label: 'Everything',
                icon: Icons.all_inclusive_rounded,
                selected: _categoryId == null,
                enabled: !_saving && !_isEditing,
                onSelected: () => setState(() => _categoryId = null),
              ),
              ...selectable.map((ExpenseCategory category) {
                return AppChoiceChip(
                  label: category.name,
                  selected: _categoryId == category.id,
                  enabled: !_saving && !_isEditing,
                  tone: AppColors.readableOn(
                    AppColors.fromHex(category.color),
                    theme.brightness,
                  ),
                  avatar: CategoryAvatar(
                    icon: category.icon,
                    color: category.color,
                    size: 20,
                  ),
                  onSelected: () =>
                      setState(() => _categoryId = category.id),
                );
              }),
            ],
          ),
          if (_isEditing) ...<Widget>[
            const SizedBox(height: AppSpacing.md),
            const AppNotice(
              message: 'Create a new budget to change what it applies to.',
            ),
          ],

          if (_error != null) ...<Widget>[
            const SizedBox(height: AppSpacing.lg),
            InlineError(message: _error!),
          ],
        ],
      ),
    );
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _saving = true;
      _error = null;
    });

    final BudgetProvider provider = context.read<BudgetProvider>();
    final bool ok = await provider.setBudget(
      categoryId: _categoryId,
      amount: Validators.parseAmount(_amount.text)!,
    );

    if (!mounted) return;

    if (ok) {
      AppFeedback.success(context, 'Budget saved');
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _saving = false;
        _error = provider.errorMessage ?? 'Could not save the budget.';
      });
    }
  }

  Future<void> _delete() async {
    final Budget? existing = widget.existing;
    if (existing == null) return;

    final bool confirmed = await AppFeedback.confirm(
      context,
      title: 'Delete budget?',
      message: 'The limit for ${existing.label.toLowerCase()} will be removed '
          'for this month.',
    );

    if (!confirmed || !mounted) return;

    setState(() => _saving = true);
    final BudgetProvider provider = context.read<BudgetProvider>();
    final bool ok = await provider.delete(existing.id);

    if (!mounted) return;

    if (ok) {
      AppFeedback.success(context, 'Budget deleted');
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _saving = false;
        _error = provider.errorMessage ?? 'Could not delete the budget.';
      });
    }
  }
}
