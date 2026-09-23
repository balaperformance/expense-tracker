import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/utils/formatters.dart';
import '../../models/bank_account.dart';
import '../../models/ledger_entry.dart';
import '../../providers/auth_provider.dart';
import '../../providers/bank_account_provider.dart';
import '../../providers/settings_provider.dart';
import '../../providers/statement_provider.dart';
import '../../services/export/export_models.dart';
import '../../widgets/category_avatar.dart';
import '../../widgets/common/app_feedback.dart';
import '../../widgets/common/app_sheet.dart';
import '../../widgets/common/state_views.dart';
import '../../widgets/common/surface_card.dart';
import '../../widgets/stat_tiles.dart';
import '../../widgets/transaction_tile.dart';
import '../export/export_screen.dart';
import 'deposit_sheet.dart';
import 'transfer_sheet.dart';

/// Banking-style statement for one account.
///
/// Reads top to bottom the way a real statement does: period summary first
/// (opening, credits, debits, closing), then movements newest-first grouped
/// by day, each line carrying its debit/credit amount and the balance that
/// resulted from it.
class AccountStatementScreen extends StatefulWidget {
  const AccountStatementScreen({super.key, required this.account});

  final BankAccount account;

  @override
  State<AccountStatementScreen> createState() =>
      _AccountStatementScreenState();
}

class _AccountStatementScreenState extends State<AccountStatementScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  Future<void> _open() async {
    if (!mounted) return;
    final String? userId = context.read<AuthProvider>().userId;
    if (userId == null) return;
    await context
        .read<StatementProvider>()
        .open(userId: userId, account: widget.account);
  }

  @override
  Widget build(BuildContext context) {
    final StatementProvider provider = context.watch<StatementProvider>();
    final SettingsProvider settings = context.watch<SettingsProvider>();
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: <Widget>[
            BankAvatar(initial: widget.account.initial, size: 34),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    widget.account.nickname,
                    style: theme.textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    widget.account.last4 == null
                        ? widget.account.bankName
                        : '${widget.account.bankName} •••• ${widget.account.last4}',
                    style: theme.textTheme.labelSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: <Widget>[
          IconButton(
            tooltip: 'Export statement',
            onPressed: () => _openExport(provider),
            icon: const Icon(Icons.ios_share_rounded),
          ),
          if (context.watch<BankAccountProvider>().canTransfer)
            IconButton(
              tooltip: 'Transfer',
              onPressed: _openTransfer,
              icon: const Icon(Icons.swap_horiz_rounded),
            ),
          IconButton(
            tooltip: 'Add money',
            onPressed: _openDeposit,
            icon: const Icon(Icons.add_rounded),
          ),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      body: Column(
        children: <Widget>[
          _PeriodBar(provider: provider),
          const Divider(height: 1),
          Expanded(child: _buildBody(provider, settings)),
        ],
      ),
    );
  }

  Widget _buildBody(StatementProvider provider, SettingsProvider settings) {
    if (provider.isLoading && provider.statement == null) {
      return const ListSkeleton(rows: 5);
    }

    if (provider.hasError && provider.statement == null) {
      return ScrollableCentered(
        child: ErrorView(
          message: provider.errorMessage!,
          onRetry: () => provider.load(force: true),
        ),
      );
    }

    final AccountStatement? statement = provider.statement;
    if (statement == null) return const SizedBox.shrink();

    final String currency = settings.currency;
    final List<_DayGroup> groups = _groupByDay(statement.rows);

    return RefreshIndicator(
      onRefresh: () => provider.load(force: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.page,
          AppSpacing.md,
          AppSpacing.page,
          AppSpacing.xxxl,
        ),
        children: <Widget>[
          _SummaryCard(statement: statement, currency: currency),
          const SizedBox(height: AppSpacing.md),
          _TypeFilterBar(provider: provider),
          const SizedBox(height: AppSpacing.sm),
          if (statement.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xl),
              child: EmptyState(
                compact: true,
                icon: Icons.receipt_long_outlined,
                title: 'No transactions',
                message: provider.typeFilter == StatementTypeFilter.all
                    ? 'Nothing recorded for '
                        '${provider.periodLabel.toLowerCase()}.'
                    : 'No ${provider.typeFilter.label.toLowerCase()} in this '
                        'period.',
              ),
            )
          else ...<Widget>[
            for (int g = 0; g < groups.length; g++) ...<Widget>[
              DayHeader(
                label: Formatters.relativeDay(groups[g].day),
                total: groups[g].net,
                currency: currency,
                tone: AmountTone.auto,
                isFirst: g == 0,
              ),
              CardList(
                children: <Widget>[
                  for (final StatementRow row in groups[g].rows)
                    _StatementRowTile(
                      row: row,
                      currency: currency,
                      counterparty: context
                          .read<BankAccountProvider>()
                          .byId(row.entry.counterpartyAccountId)
                          ?.nickname,
                      onLongPress: () => _confirmDelete(row),
                    ),
                ],
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            Text(
              'Balance is calculated from the ledger, oldest first. '
              'Long-press a manual entry to delete it.',
              style: Theme.of(context).textTheme.labelSmall,
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }

  /// Groups statement rows by day, preserving the newest-first order the
  /// statement was built in.
  List<_DayGroup> _groupByDay(List<StatementRow> rows) {
    final List<_DayGroup> groups = <_DayGroup>[];

    for (final StatementRow row in rows) {
      if (groups.isEmpty || groups.last.day != row.entry.txnDate) {
        groups.add(_DayGroup(row.entry.txnDate));
      }
      groups.last.rows.add(row);
      groups.last.net += row.entry.signedAmount;
    }
    return groups;
  }

  /// Opens Export already set to this account and the period on screen, so
  /// exporting what is being looked at takes one tap rather than three
  /// choices.
  void _openExport(StatementProvider provider) {
    final DateTime month = provider.month;

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ExportScreen(
          initialType: ExportReportType.bankStatement,
          initialAccountId: widget.account.id,
          // "All transactions" has no bounded range to carry over, so the
          // export opens on the current month and the user widens it there.
          initialRange: provider.wholeHistory
              ? null
              : ExportDateRange.month(month),
        ),
      ),
    );
  }

  Future<void> _openDeposit() async {
    final bool? changed = await showAppSheet<bool>(
      context: context,
      builder: (_) => DepositSheet(account: widget.account),
    );
    if (changed == true && mounted) {
      await context.read<StatementProvider>().load(force: true);
    }
  }

  Future<void> _openTransfer() async {
    final bool? changed = await showAppSheet<bool>(
      context: context,
      builder: (_) => TransferSheet(fromAccount: widget.account),
    );
    if (changed == true && mounted) {
      await context.read<StatementProvider>().load(force: true);
    }
  }

  /// Only manual movements can be deleted here. One created by an expense or
  /// income row belongs to that record, and deleting it separately would make
  /// the statement disagree with the transaction list.
  Future<void> _confirmDelete(StatementRow row) async {
    final LedgerEntry entry = row.entry;

    if (entry.isDocumentBacked) {
      AppFeedback.info(
        context,
        'This came from ${entry.expenseId != null ? 'an expense' : 'an income'} '
        'entry. Delete it there instead.',
      );
      return;
    }

    final SettingsProvider settings = context.read<SettingsProvider>();
    final String amountText =
        Formatters.currency(entry.amount, currencyCode: settings.currency);

    final bool confirmed = await AppFeedback.confirm(
      context,
      title: entry.isTransfer ? 'Delete transfer?' : 'Delete transaction?',
      message: entry.isTransfer
          // Deleting one side alone would make the money look created or
          // destroyed, so both legs always go together and the confirmation
          // says so before the user commits.
          ? 'This removes both sides of the $amountText transfer on '
              '${Formatters.dayMonthYear(entry.txnDate)} — the '
              '${entry.isDebit ? 'debit' : 'credit'} here and the matching '
              '${entry.isDebit ? 'credit' : 'debit'} on the other account. '
              'Both balances will be recalculated.'
          : '${entry.isCredit ? 'Credit' : 'Debit'} of $amountText '
              'on ${Formatters.dayMonthYear(entry.txnDate)}. '
              'The balance will be recalculated.',
    );

    if (!confirmed || !mounted) return;

    final BankAccountProvider accounts = context.read<BankAccountProvider>();
    final bool ok = entry.isTransfer
        ? await accounts.deleteTransfer(entry.transferGroupId!)
        : await accounts.deleteEntry(entry.id);

    if (!mounted) return;

    if (ok) {
      AppFeedback.success(
        context,
        entry.isTransfer ? 'Transfer deleted' : 'Transaction deleted',
      );
      await context.read<StatementProvider>().load(force: true);
    } else {
      AppFeedback.error(
        context,
        accounts.errorMessage ?? 'Could not delete the transaction.',
      );
    }
  }
}

class _DayGroup {
  _DayGroup(this.day);

  final DateTime day;
  final List<StatementRow> rows = <StatementRow>[];
  double net = 0;
}

class _PeriodBar extends StatelessWidget {
  const _PeriodBar({required this.provider});

  final StatementProvider provider;

  @override
  Widget build(BuildContext context) {
    if (provider.wholeHistory) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.page,
          AppSpacing.xs,
          AppSpacing.sm,
          AppSpacing.xs,
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                'All transactions',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            TextButton(
              onPressed: () => provider.setWholeHistory(false),
              child: const Text('By month'),
            ),
          ],
        ),
      );
    }

    return MonthStepper(
      month: provider.month,
      onPrevious: () => provider.stepMonth(-1),
      onNext: provider.canGoForward ? () => provider.stepMonth(1) : null,
      trailing: TextButton(
        onPressed: () => provider.setWholeHistory(true),
        child: const Text('All'),
      ),
    );
  }
}

class _TypeFilterBar extends StatelessWidget {
  const _TypeFilterBar({required this.provider});

  final StatementProvider provider;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<StatementTypeFilter>(
        segments: StatementTypeFilter.values
            .map((StatementTypeFilter filter) =>
                ButtonSegment<StatementTypeFilter>(
                  value: filter,
                  label: Text(filter.label),
                ))
            .toList(),
        selected: <StatementTypeFilter>{provider.typeFilter},
        showSelectedIcon: false,
        onSelectionChanged: (Set<StatementTypeFilter> value) =>
            provider.setTypeFilter(value.first),
      ),
    );
  }
}

/// Opening / credits / debits / closing, the way a statement header reads.
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.statement, required this.currency});

  final AccountStatement statement;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return SurfaceCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        children: <Widget>[
          _line(context, 'Opening balance', statement.openingBalance),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
            child: Divider(height: 1),
          ),
          Row(
            children: <Widget>[
              Expanded(
                child: StatTile(
                  label: 'Credits',
                  amount: statement.totalCredits,
                  currency: currency,
                  icon: Icons.south_west_rounded,
                  tone: ToneColors.income(context),
                  colouredAmount: true,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: StatTile(
                  label: 'Debits',
                  amount: statement.totalDebits,
                  currency: currency,
                  icon: Icons.north_east_rounded,
                  tone: ToneColors.expense(context),
                  colouredAmount: true,
                ),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
            child: Divider(height: 1),
          ),
          Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      'Closing balance',
                      style: theme.textTheme.labelMedium,
                    ),
                    Text(
                      '${statement.movementCount} '
                      '${statement.movementCount == 1 ? 'transaction' : 'transactions'}',
                      style: theme.textTheme.labelSmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Flexible(
                child: MoneyText(
                  statement.closingBalance,
                  currency: currency,
                  fit: true,
                  textAlign: TextAlign.end,
                  tone: statement.closingBalance < 0
                      ? AmountTone.negative
                      : AmountTone.neutral,
                  style: theme.textTheme.headlineMedium,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _line(BuildContext context, String label, double value) {
    final ThemeData theme = Theme.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        Text(label, style: theme.textTheme.bodySmall),
        MoneyText(
          value,
          currency: currency,
          style: theme.textTheme.titleSmall,
        ),
      ],
    );
  }
}

/// One statement line: description, category, amount, resulting balance.
class _StatementRowTile extends StatelessWidget {
  const _StatementRowTile({
    required this.row,
    required this.currency,
    this.counterparty,
    this.onLongPress,
  });

  final StatementRow row;
  final String currency;

  /// Nickname of the other account in a transfer, if it still exists.
  final String? counterparty;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final LedgerEntry entry = row.entry;

    // A transfer's stored description is already "Transfer to Savings", so
    // appending "to Savings" to the meta line printed the counterparty
    // twice and pushed both lines into an ellipsis. It is added only when
    // the user wrote their own note, where the other account is genuinely
    // missing from the title.
    final String? other = counterparty;
    final bool titleNamesCounterparty = other != null &&
        entry.title.toLowerCase().contains(other.toLowerCase());

    return TransactionRow(
      leading: _leading(entry),
      title: entry.title,
      // A statement is a detail view: a description that runs long should
      // wrap rather than be cut off.
      titleMaxLines: 2,
      amount: entry.signedAmount,
      currency: currency,
      // A transfer is neutral slate on both sides: the credit leg must not
      // read as income, and the debit leg must not read as spending.
      tone: entry.isTransfer
          ? AmountTone.transfer
          : (entry.isCredit ? AmountTone.positive : AmountTone.negative),
      meta: <String>[
        if (entry.categoryLabel != null) entry.categoryLabel!,
        if (entry.isTransfer && other != null && !titleNamesCounterparty)
          entry.isDebit ? 'to $other' : 'from $other',
      ],
      trailingBelow: Formatters.currency(
        row.balanceAfter,
        currencyCode: currency,
        compact: true,
      ),
      onLongPress: onLongPress,
    );
  }

  Widget _leading(LedgerEntry entry) {
    if (entry.isTransfer) return const TransferAvatar();
    if (entry.category != null) {
      return CategoryAvatar(
        icon: entry.category!.icon,
        color: entry.category!.color,
      );
    }
    return LedgerAvatar(isCredit: entry.isCredit);
  }
}
