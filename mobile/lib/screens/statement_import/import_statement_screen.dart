import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/utils/formatters.dart';
import '../../models/bank_account.dart';
import '../../models/expense_category.dart';
import '../../providers/auth_provider.dart';
import '../../providers/bank_account_provider.dart';
import '../../providers/budget_provider.dart';
import '../../providers/category_provider.dart';
import '../../providers/credit_card_provider.dart';
import '../../providers/dashboard_provider.dart';
import '../../providers/expense_provider.dart';
import '../../providers/income_provider.dart';
import '../../providers/payment_method_provider.dart';
import '../../providers/reports_provider.dart';
import '../../providers/settings_provider.dart';
import '../../providers/statement_import_provider.dart';
import '../../services/schema_capabilities.dart';
import '../../widgets/category_avatar.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/app_feedback.dart';
import '../../widgets/common/app_sheet.dart';
import '../../widgets/common/money_text.dart';
import '../../widgets/common/state_views.dart';
import '../../widgets/common/surface_card.dart';
import '../../widgets/transaction_tile.dart';
import 'import_row_sheet.dart';

enum _Filter { all, selected, duplicates, attention }

/// Import a bank statement (PDF or Excel .xlsx) into one account.
///
/// The file is read on this phone by the same parsers the web app uses; it
/// is never uploaded, and nothing is written until the user confirms.
class ImportStatementScreen extends StatefulWidget {
  const ImportStatementScreen({super.key, this.initialAccountId});

  final String? initialAccountId;

  @override
  State<ImportStatementScreen> createState() => _ImportStatementScreenState();
}

class _ImportStatementScreenState extends State<ImportStatementScreen> {
  final TextEditingController _password = TextEditingController();
  _Filter _filter = _Filter.all;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final String? userId = context.read<AuthProvider>().userId;
    if (userId == null) return;
    await Future.wait(<Future<void>>[
      // Categories and payment methods are loaded when the session starts.
      context.read<BankAccountProvider>().load(userId: userId),
      if (SchemaCapabilities.creditCards)
        context.read<CreditCardProvider>().load(userId: userId),
    ]);
    if (!mounted) return;
    final List<BankAccount> accounts = _activeAccounts();
    BankAccount? initial;
    for (final BankAccount a in accounts) {
      if (a.id == widget.initialAccountId) initial = a;
    }
    if (initial != null) _choose(initial);
  }

  List<BankAccount> _activeAccounts() => context
      .read<BankAccountProvider>()
      .accounts
      .where((BankAccount a) => a.isActive)
      .toList();

  void _choose(BankAccount account) {
    final String? userId = context.read<AuthProvider>().userId;
    if (userId == null) return;
    context.read<StatementImportProvider>().begin(
          userId: userId,
          account: account,
          accounts: context.read<BankAccountProvider>().accounts,
          categories: context.read<CategoryProvider>().categories,
          cards: context.read<CreditCardProvider>().cards,
        );
  }

  @override
  Widget build(BuildContext context) {
    final StatementImportProvider provider =
        context.watch<StatementImportProvider>();
    final BankAccountProvider accounts = context.watch<BankAccountProvider>();
    final String currency = context.watch<SettingsProvider>().currency;
    final BankAccount? account = provider.account;
    final bool busy = provider.reading != null || provider.importing != null;

    return PopScope(
      canPop: provider.importing == null,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Import statement'),
          actions: <Widget>[
            if (account != null && provider.hasRows && provider.outcome == null)
              IconButton(
                tooltip: 'Add another statement',
                onPressed: busy ? null : provider.addFile,
                icon: const Icon(Icons.note_add_outlined),
              ),
            const SizedBox(width: AppSpacing.xs),
          ],
        ),
        bottomNavigationBar: account != null &&
                provider.hasRows &&
                provider.outcome == null
            ? _ImportBar(
                count: provider.selectedCount,
                busy: busy,
                blocked: provider.checkFailed,
                importing: provider.importing,
                onImport: () => _import(provider, currency),
              )
            : null,
        body: _body(provider, accounts, currency, busy),
      ),
    );
  }

  Widget _body(
    StatementImportProvider provider,
    BankAccountProvider accounts,
    String currency,
    bool busy,
  ) {
    if (!SchemaCapabilities.phase2Ready) {
      return const ScrollableCentered(
        child: EmptyState(
          icon: Icons.account_balance_outlined,
          title: 'Bank accounts needed',
          message: 'Statement import links every row to a bank account. Set '
              'up bank accounts first.',
        ),
      );
    }
    final BankAccount? account = provider.account;
    if (account == null) {
      if (accounts.isInitialLoad) return const ListSkeleton(rows: 3);
      final List<BankAccount> active =
          accounts.accounts.where((BankAccount a) => a.isActive).toList();
      if (active.isEmpty) {
        return const ScrollableCentered(
          child: EmptyState(
            icon: Icons.account_balance_outlined,
            title: 'Bank accounts needed',
            message: 'Add a bank account first — every imported row is linked '
                'to one.',
          ),
        );
      }
      return ListView(
        padding: const EdgeInsets.all(AppSpacing.page),
        children: <Widget>[
          Text('Which account is this statement for?',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpacing.md),
          CardList(
            children: active
                .map((BankAccount a) => AppListRow(
                      leading: BankAvatar(initial: a.initial),
                      title: a.nickname,
                      subtitle: a.last4 == null
                          ? a.bankName
                          : '${a.bankName} •••• ${a.last4}',
                      showChevron: true,
                      onTap: () => _choose(a),
                    ))
                .toList(),
          ),
          const SizedBox(height: AppSpacing.lg),
          const _PrivacyNote(),
        ],
      );
    }

    final ImportOutcome? outcome = provider.outcome;
    if (outcome != null) return _ResultView(outcome: outcome, account: account);

    final List<Widget> children = <Widget>[
      AppListRow(
        leading: BankAvatar(initial: account.initial),
        title: account.displayLabel,
        subtitle: account.bankName,
        trailing: provider.hasRows || busy
            ? null
            : TextButton(
                onPressed: () => provider.reset(),
                child: const Text('Change'),
              ),
      ),
      const SizedBox(height: AppSpacing.md),
    ];

    if (provider.reading != null) {
      children.addAll(<Widget>[
        const LinearProgressIndicator(),
        const SizedBox(height: AppSpacing.sm),
        Text('Reading ${provider.reading}…',
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: AppSpacing.md),
      ]);
    }
    if (provider.pending != null) {
      children.addAll(<Widget>[_passwordCard(provider), const SizedBox(height: AppSpacing.md)]);
    }
    if (provider.problem != null) {
      children.addAll(<Widget>[
        AppNotice(
          icon: Icons.error_outline_rounded,
          tone: Theme.of(context).colorScheme.error,
          message: provider.problem!,
        ),
        const SizedBox(height: AppSpacing.md),
      ]);
    }

    if (!provider.hasRows) {
      children.addAll(<Widget>[
        SurfaceCard(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            children: <Widget>[
              const Icon(Icons.description_outlined, size: 40),
              const SizedBox(height: AppSpacing.md),
              Text(
                'Add a statement',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'A PDF, or the Excel (.xlsx) download from net banking. '
                'Weekly, monthly or overlapping statements are fine.',
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.lg),
              AppButton(
                label: 'Choose file',
                icon: Icons.upload_file_rounded,
                onPressed: busy || provider.pending != null ? null : provider.addFile,
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        const _PrivacyNote(),
      ]);
      return ListView(padding: const EdgeInsets.all(AppSpacing.page), children: children);
    }

    for (final ImportedStatement s in provider.statements) {
      children.add(_StatementTile(statement: s));
      children.add(const SizedBox(height: AppSpacing.sm));
    }
    children.add(_SummaryCard(summary: provider.summary, currency: currency));
    children.add(const SizedBox(height: AppSpacing.md));
    if (provider.checkFailed) {
      children.addAll(<Widget>[
        AppNotice(
          icon: Icons.cloud_off_outlined,
          tone: ToneColors.warning(context),
          message: 'Could not check these rows against what is already '
              'recorded, so importing is paused to avoid duplicates.',
          action: TextButton(
            onPressed: provider.rechecking ? null : provider.recheck,
            child: Text(provider.rechecking ? 'Checking…' : 'Retry'),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
      ]);
    }
    children.add(SizedBox(
      width: double.infinity,
      child: SegmentedButton<_Filter>(
        segments: const <ButtonSegment<_Filter>>[
          ButtonSegment<_Filter>(value: _Filter.all, label: Text('All')),
          ButtonSegment<_Filter>(value: _Filter.selected, label: Text('Import')),
          ButtonSegment<_Filter>(value: _Filter.duplicates, label: Text('Dupes')),
          ButtonSegment<_Filter>(value: _Filter.attention, label: Text('Check')),
        ],
        selected: <_Filter>{_filter},
        showSelectedIcon: false,
        onSelectionChanged: (Set<_Filter> v) => setState(() => _filter = v.first),
      ),
    ));
    children.add(const SizedBox(height: AppSpacing.sm));
    children.addAll(_rows(provider, currency, busy));
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.page,
        AppSpacing.md,
        AppSpacing.page,
        AppSpacing.xxxl,
      ),
      children: children,
    );
  }

  List<Widget> _rows(StatementImportProvider provider, String currency, bool busy) {
    final List<ImportRow> visible = provider.rows.where((ImportRow r) {
      switch (_filter) {
        case _Filter.all:
          return true;
        case _Filter.selected:
          return r.selected;
        case _Filter.duplicates:
          return r.isDuplicate;
        case _Filter.attention:
          return r.attention || r.uncategorized;
      }
    }).toList()
      ..sort((ImportRow a, ImportRow b) => b.isoDate.compareTo(a.isoDate));
    if (visible.isEmpty) {
      return <Widget>[
        const Padding(
          padding: EdgeInsets.only(top: AppSpacing.xl),
          child: EmptyState(
            compact: true,
            icon: Icons.filter_list_off_rounded,
            title: 'Nothing here',
            message: 'No rows match this filter.',
          ),
        ),
      ];
    }
    final Map<String, ExpenseCategory> categories = <String, ExpenseCategory>{
      for (final ExpenseCategory c in context.read<CategoryProvider>().categories) c.id: c,
    };
    final List<Widget> out = <Widget>[];
    int i = 0;
    while (i < visible.length) {
      final String day = visible[i].isoDate;
      final List<ImportRow> group = <ImportRow>[];
      double net = 0;
      while (i < visible.length && visible[i].isoDate == day) {
        group.add(visible[i]);
        net += visible[i].isDebit ? -visible[i].amount : visible[i].amount;
        i++;
      }
      out.add(DayHeader(
        label: Formatters.relativeDay(group.first.date),
        total: net,
        currency: currency,
        tone: AmountTone.auto,
        isFirst: out.isEmpty,
      ));
      out.add(CardList(
        children: group
            .map((ImportRow r) => _ImportRowTile(
                  row: r,
                  currency: currency,
                  category: categories[r.categoryId],
                  enabled: !busy,
                  onToggle: () => provider.toggle(r.id),
                  onEdit: () => _editRow(r),
                ))
            .toList(),
      ));
    }
    return out;
  }

  Widget _passwordCard(StatementImportProvider provider) {
    final PendingPassword pending = provider.pending!;
    return SurfaceCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            pending.incorrect
                ? 'That password did not open ${pending.file.name}'
                : '${pending.file.name} is password protected',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Banks often use part of your name and date of birth. The '
            'password is used once to open the file and is never saved.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _password,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(hintText: 'Statement password'),
            onSubmitted: (_) => _unlock(provider),
          ),
          const SizedBox(height: AppSpacing.md),
          AppButtonRow(
            confirmLabel: 'Open',
            onConfirm: provider.reading != null ? null : () => _unlock(provider),
            onCancel: () {
              _password.clear();
              provider.cancelPassword();
            },
          ),
        ],
      ),
    );
  }

  Future<void> _unlock(StatementImportProvider provider) async {
    final String value = _password.text;
    _password.clear();
    await provider.unlock(value);
  }

  Future<void> _editRow(ImportRow row) async {
    final String? result = await showAppSheet<String>(
      context: context,
      builder: (_) => ImportRowSheet(row: row),
    );
    if (result == 'removed' && mounted) {
      await context.read<StatementImportProvider>().remove(row.id);
    }
  }

  Future<void> _import(StatementImportProvider provider, String currency) async {
    final ImportPreview? plan = await provider.preview(
      paymentMethods: context.read<PaymentMethodProvider>().methods,
    );
    if (plan == null || !mounted) return;
    String money(double v) => Formatters.currency(v, currencyCode: currency);
    final List<Map<String, Object?>> expenses = plan.ofType('expense').toList();
    final List<Map<String, Object?>> income = plan.ofType('income').toList();
    final List<Map<String, Object?>> movements = plan.ofType('movement').toList();
    final int cardBills = movements
        .where((Map<String, Object?> op) => op['creditCardId'] != null)
        .length;
    final String? skippedReason = plan.skipped.isEmpty
        ? null
        : (plan.skipped.first['reason'] as String?)?.toLowerCase();
    final bool ok = await AppFeedback.confirm(
      context,
      title: 'Import ${plan.operations.length} '
          '${plan.operations.length == 1 ? 'transaction' : 'transactions'}?',
      message: <String>[
        'Into ${provider.account!.displayLabel}:',
        if (expenses.isNotEmpty)
          '• ${expenses.length} expenses · ${money(ImportPreview.total(expenses))}',
        if (income.isNotEmpty)
          '• ${income.length} income · ${money(ImportPreview.total(income))}',
        if (movements.isNotEmpty)
          '• ${movements.length} refunds and transfers (balance only)'
              '${cardBills > 0 ? ', including $cardBills card bill ${cardBills == 1 ? 'payment' : 'payments'}' : ''}',
        if (plan.skipped.isNotEmpty)
          '${plan.skipped.length} selected rows will be skipped: $skippedReason.',
        'Rows recorded meanwhile are checked again and left out.',
      ].join('\n'),
      confirmLabel: 'Import',
      destructive: false,
    );
    if (!ok || !mounted) return;
    final ImportOutcome? outcome = await provider.execute(plan);
    if (!mounted) return;
    // Some rows may have been written even if others failed.
    context.read<BankAccountProvider>().invalidate();
    context.read<CreditCardProvider>().invalidate();
    context.read<DashboardProvider>().invalidate();
    context.read<BudgetProvider>().invalidate();
    context.read<ReportsProvider>().invalidate();
    context.read<ExpenseProvider>().refresh();
    context.read<IncomeProvider>().refresh();
    if (outcome != null && outcome.written > 0) {
      AppFeedback.success(context, 'Imported ${outcome.written} transactions');
    }
  }
}

class _PrivacyNote extends StatelessWidget {
  const _PrivacyNote();

  @override
  Widget build(BuildContext context) => const AppNotice(
        icon: Icons.lock_outline_rounded,
        message: 'The statement is read on this phone with the same rules as '
            'the web app. It is never uploaded or sent to an AI service, and '
            'nothing is saved until you confirm the import.',
      );
}

class _StatementTile extends StatelessWidget {
  const _StatementTile({required this.statement});

  final ImportedStatement statement;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SurfaceCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.description_outlined, size: AppSpacing.iconMd),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  statement.fileName,
                  style: theme.textTheme.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              AppBadge(label: '${statement.transactionCount} rows'),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            <String>[
              statement.periodLabel,
              if (statement.bankName != null) statement.bankName!,
              statement.parserLabel,
            ].where((String s) => s.isNotEmpty).join(' · '),
            style: theme.textTheme.labelSmall,
          ),
          if (statement.accountMismatch) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            AppNotice(
              icon: Icons.warning_amber_rounded,
              tone: ToneColors.warning(context),
              message: 'The account number on this statement does not match '
                  'the account you chose. Check it is the right account.',
            ),
          ],
          for (final String w in statement.warnings) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            AppNotice(
              icon: Icons.fact_check_outlined,
              tone: ToneColors.warning(context),
              message: w,
            ),
          ],
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary, required this.currency});

  final Map<String, Object?> summary;
  final String currency;

  int _n(String key) => (summary[key] as num?)?.toInt() ?? 0;

  (int, double) _pair(String key) {
    final Map<String, Object?> v =
        (summary[key] as Map<String, Object?>?) ?? const <String, Object?>{};
    return ((v['count'] as num?)?.toInt() ?? 0, (v['amount'] as num?)?.toDouble() ?? 0);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final (int incomeCount, double incomeAmount) = _pair('income');
    final (int expenseCount, double expenseAmount) = _pair('expense');
    String money(double v) => Formatters.currency(v, currencyCode: currency);
    Widget line(String label, String value, {Color? tone}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
          child: Row(
            children: <Widget>[
              Expanded(child: Text(label, style: theme.textTheme.bodySmall)),
              Text(value, style: theme.textTheme.titleSmall?.copyWith(color: tone)),
            ],
          ),
        );
    return SurfaceCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        children: <Widget>[
          line('Found', '${_n('total')} transactions'),
          line('Income', '$incomeCount · ${money(incomeAmount)}',
              tone: ToneColors.income(context)),
          line('Expenses', '$expenseCount · ${money(expenseAmount)}',
              tone: ToneColors.expense(context)),
          line('Refunds · transfers', '${_n('refunds')} · ${_n('transfers')}'),
          if (_n('duplicates') > 0)
            line('Already recorded', '${_n('duplicates')} left out',
                tone: ToneColors.warning(context)),
          if (_n('needsAttention') + _n('uncategorized') > 0)
            line('To check', '${_n('needsAttention') + _n('uncategorized')}'),
          const Divider(height: AppSpacing.lg),
          line('Selected to import', '${_n('selected')}'),
        ],
      ),
    );
  }
}

class _ImportRowTile extends StatelessWidget {
  const _ImportRowTile({
    required this.row,
    required this.currency,
    required this.category,
    required this.enabled,
    required this.onToggle,
    required this.onEdit,
  });

  final ImportRow row;
  final String currency;
  final ExpenseCategory? category;
  final bool enabled;
  final VoidCallback onToggle;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool balanceOnly = row.kind == 'refund' || row.kind == 'transfer';
    return Opacity(
      opacity: row.selected ? 1 : 0.55,
      child: InkWell(
        onTap: enabled ? onEdit : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.rowPadY,
          ),
          child: Row(
            children: <Widget>[
              Checkbox(
                value: row.selected,
                onChanged: enabled ? (_) => onToggle() : null,
                visualDensity: VisualDensity.compact,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      row.counterparty?.isNotEmpty == true
                          ? row.counterparty!
                          : row.description,
                      style: theme.textTheme.titleSmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: AppSpacing.xxs),
                    Text(
                      <String>[
                        row.kindLabel,
                        if (row.kind == 'expense')
                          category?.name ?? 'Choose a category',
                        if (row.kind == 'income' && (row.category ?? '').isNotEmpty)
                          row.category!,
                        if (row.creditCardId != null) 'Card bill payment',
                        if (row.duplicateBadge != null) row.duplicateBadge!,
                        if (row.attention) 'Check this row',
                      ].join(' · '),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: row.blocking || row.attention
                            ? ToneColors.warning(context)
                            : null,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              MoneyText(
                row.isDebit ? -row.amount : row.amount,
                currency: currency,
                signed: true,
                tone: balanceOnly
                    ? AmountTone.transfer
                    : (row.isDebit ? AmountTone.negative : AmountTone.positive),
                style: theme.textTheme.titleSmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ImportBar extends StatelessWidget {
  const _ImportBar({
    required this.count,
    required this.busy,
    required this.blocked,
    required this.importing,
    required this.onImport,
  });

  final int count;
  final bool busy;
  final bool blocked;
  final (int, int)? importing;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final (int, int)? progress = importing;
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(top: BorderSide(color: theme.colorScheme.outline)),
      ),
      padding: EdgeInsets.fromLTRB(
        AppSpacing.page,
        AppSpacing.md,
        AppSpacing.page,
        AppSpacing.md + MediaQuery.paddingOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (progress != null) ...<Widget>[
            LinearProgressIndicator(
              value: progress.$2 == 0 ? null : progress.$1 / progress.$2,
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
          AppButton.submit(
            label: progress != null
                ? 'Importing ${progress.$1} of ${progress.$2}…'
                : (count == 0 ? 'Select rows to import' : 'Import $count'),
            busy: progress != null,
            onPressed: busy || blocked || count == 0 ? null : onImport,
          ),
        ],
      ),
    );
  }
}

class _ResultView extends StatelessWidget {
  const _ResultView({required this.outcome, required this.account});

  final ImportOutcome outcome;
  final BankAccount account;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final StatementImportProvider provider = context.read<StatementImportProvider>();
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.page),
      children: <Widget>[
        SurfaceCard(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            children: <Widget>[
              Icon(
                outcome.failures.isEmpty
                    ? Icons.check_circle_outline_rounded
                    : Icons.warning_amber_rounded,
                size: 44,
                color: outcome.failures.isEmpty
                    ? ToneColors.income(context)
                    : ToneColors.warning(context),
              ),
              const SizedBox(height: AppSpacing.md),
              Text('Import complete', style: theme.textTheme.titleLarge),
              const SizedBox(height: AppSpacing.sm),
              Text(
                '${outcome.expenses} expenses · ${outcome.income} income · '
                '${outcome.movements} balance-only movements into '
                '${account.displayLabel}.',
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              if (outcome.skipped > 0) ...<Widget>[
                const SizedBox(height: AppSpacing.sm),
                Text(
                  '${outcome.skipped} rows were left out (already recorded or '
                  'not importable).',
                  style: theme.textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        ),
        if (outcome.failures.isNotEmpty || outcome.notAttempted > 0) ...<Widget>[
          const SizedBox(height: AppSpacing.md),
          AppNotice(
            icon: Icons.error_outline_rounded,
            tone: theme.colorScheme.error,
            message: '${outcome.failures.length} rows could not be saved'
                '${outcome.notAttempted > 0 ? ' and ${outcome.notAttempted} were not attempted' : ''}: '
                '${outcome.failures.isEmpty ? 'the connection kept failing' : outcome.failures.first} '
                'Import the statement again — rows already saved are '
                'recognised and left out.',
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        AppButton(
          label: 'Import another statement',
          icon: Icons.upload_file_rounded,
          variant: AppButtonVariant.tonal,
          onPressed: provider.startOver,
        ),
        const SizedBox(height: AppSpacing.sm),
        AppButton(
          label: 'Done',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}
