import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/utils/formatters.dart';
import '../../models/bank_account.dart';
import '../../models/card_statement.dart';
import '../../models/credit_card.dart';
import '../../models/ledger_entry.dart';
import '../../providers/auth_provider.dart';
import '../../providers/bank_account_provider.dart';
import '../../providers/budget_provider.dart';
import '../../providers/credit_card_provider.dart';
import '../../providers/dashboard_provider.dart';
import '../../providers/expense_provider.dart';
import '../../providers/income_provider.dart';
import '../../providers/insights_provider.dart';
import '../../providers/receivable_provider.dart';
import '../../providers/reports_provider.dart';
import '../../providers/settings_provider.dart';
import '../../providers/statement_provider.dart';
import '../../services/export/export_models.dart';
import '../../services/schema_capabilities.dart';
import '../../widgets/card_widgets.dart';
import '../../widgets/category_avatar.dart';
import '../../widgets/common/app_feedback.dart';
import '../../widgets/common/app_sheet.dart';
import '../../widgets/common/state_views.dart';
import '../../widgets/common/surface_card.dart';
import '../../widgets/stat_tiles.dart';
import '../../widgets/transaction_tile.dart';
import '../cards/card_statement_screen.dart';
import '../export/export_screen.dart';
import '../statement_import/import_statement_screen.dart';
import 'deposit_sheet.dart';
import 'edit_movement_sheet.dart';
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
    // Cards name the bill payments on this statement and back the
    // "mark as card payment" action.
    if (SchemaCapabilities.creditCards) {
      context.read<CreditCardProvider>().load(userId: userId);
    }
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
            AccountAvatar(account: widget.account, size: 34),
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
                    widget.account.bankLine,
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
          // Import and export share one menu so the account's name keeps
          // room in the title on a 360dp phone.
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (String value) {
              if (value == 'import') _openImport();
              if (value == 'export') _openExport(provider);
            },
            itemBuilder: (_) => <PopupMenuEntry<String>>[
              // Cash has no bank statement to import.
              if (!widget.account.isCash)
                const PopupMenuItem<String>(
                  value: 'import',
                  child: ListTile(
                    leading: Icon(Icons.upload_file_rounded),
                    title: Text('Import statement'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              const PopupMenuItem<String>(
                value: 'export',
                child: ListTile(
                  leading: Icon(Icons.ios_share_rounded),
                  title: Text('Export statement'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
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
                      counterparty: row.entry.isCardPayment
                          ? _cardName(row.entry.creditCardId)
                          : context
                              .read<BankAccountProvider>()
                              .byId(row.entry.counterpartyAccountId)
                              ?.nickname,
                      // Changing how a movement is recorded needs 005.
                      onTap: SchemaCapabilities.treatments
                          ? () => _openEditor(row)
                          : null,
                      onLongPress: () => _onLongPress(row),
                    ),
                ],
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            Text(
              'Balance is calculated from the ledger, oldest first. '
              '${SchemaCapabilities.treatments ? 'Tap a transaction to change how it is recorded — transfer, loan, reimbursement and more. ' : ''}'
              'Long-press a manual entry to delete it'
              '${_linkableCards().isNotEmpty ? ', or to mark it as a credit card bill payment' : ''}.',
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

  Future<void> _openImport() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ImportStatementScreen(initialAccountId: widget.account.id),
    ));
    if (!mounted) return;
    await context.read<StatementProvider>().load(force: true);
  }

  String _cardName(String? cardId) =>
      context.read<CreditCardProvider>().byId(cardId)?.displayLabel ??
      'the card';

  List<CreditCard> _linkableCards() => SchemaCapabilities.creditCards
      ? context
          .read<CreditCardProvider>()
          .cards
          .where((CreditCard c) => c.isActive)
          .toList()
      : const <CreditCard>[];

  /// Changes how a movement is recorded — expense, income, transfer (to
  /// another account, the cash account or a card's bill), money lent, a
  /// repayment or a reimbursement — in one database transaction.
  Future<void> _openEditor(StatementRow row) async {
    final List<BankAccount> accounts =
        context.read<BankAccountProvider>().accounts;
    final EditMovementResult? result = await showAppSheet<EditMovementResult>(
      context: context,
      builder: (_) => EditMovementSheet(
        entry: row.entry,
        account: widget.account,
        // The provider's list holds the cash account too; this account is
        // always offered to the sheet, which leaves it out as a target.
        accounts: accounts.any((BankAccount a) => a.id == widget.account.id)
            ? accounts
            : <BankAccount>[widget.account, ...accounts],
        cards: SchemaCapabilities.creditCards
            ? context.read<CreditCardProvider>().cards
            : const <CreditCard>[],
      ),
    );
    if (!mounted || result == null) return;
    if (result == EditMovementResult.delete) {
      await _confirmDelete(row);
      return;
    }
    _afterTreatment();
  }

  /// A treatment can add or remove an expense, an income row, the other leg
  /// of a transfer, a card payment or a claim: everything that reads them is
  /// out of date. The statement itself was reloaded by the save.
  void _afterTreatment() {
    final String? userId = context.read<AuthProvider>().userId;
    final BankAccountProvider accounts = context.read<BankAccountProvider>()
      ..invalidate();
    if (userId != null) accounts.load(userId: userId, force: true);
    context.read<CreditCardProvider>().invalidate();
    context.read<DashboardProvider>().invalidate();
    context.read<BudgetProvider>().invalidate();
    context.read<ReportsProvider>().invalidate();
    context.read<InsightsProvider>().invalidate();
    context.read<ReceivableProvider?>()?.invalidate();
    context.read<ExpenseProvider>().refresh();
    context.read<IncomeProvider>().refresh();
  }

  /// Card payments and linkable debits get a menu; everything else keeps the
  /// direct delete.
  Future<void> _onLongPress(StatementRow row) async {
    final LedgerEntry entry = row.entry;
    final bool linkable =
        isLinkableDebit(entry) && _linkableCards().isNotEmpty;
    if (!SchemaCapabilities.creditCards || (!entry.isCardPayment && !linkable)) {
      await _confirmDelete(row);
      return;
    }
    final String? choice = await showAppSheet<String>(
      context: context,
      builder: (BuildContext sheet) => AppSheet(
        title: Formatters.currency(
          entry.amount,
          currencyCode: context.read<SettingsProvider>().currency,
        ),
        subtitle:
            '${entry.title} · ${Formatters.dayMonthYear(entry.txnDate)}',
        children: <Widget>[
          CardList(
            dividerIndent: AppSpacing.md,
            children: <Widget>[
              if (entry.isCardPayment) ...<Widget>[
                AppListRow(
                  leading: const CardAvatar(size: 30),
                  title: 'Open ${_cardName(entry.creditCardId)}',
                  subtitle: 'Its statement and outstanding',
                  showChevron: true,
                  onTap: () => Navigator.of(sheet).pop('card'),
                ),
                AppListRow(
                  title: 'Unlink from the card',
                  subtitle:
                      'Keeps this debit; the card no longer counts it as paid',
                  onTap: () => Navigator.of(sheet).pop('unlink'),
                ),
              ] else
                AppListRow(
                  leading: const CardAvatar(size: 30),
                  title: 'Mark as a card bill payment',
                  subtitle: "Lowers that card's outstanding — no new "
                      'transaction',
                  onTap: () => Navigator.of(sheet).pop('mark'),
                ),
              AppListRow(
                title: 'Delete',
                tone: Theme.of(sheet).colorScheme.error,
                onTap: () => Navigator.of(sheet).pop('delete'),
              ),
            ],
          ),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'card':
        await Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => CardStatementScreen(cardId: entry.creditCardId!),
        ));
        if (mounted) await context.read<StatementProvider>().load(force: true);
      case 'unlink':
        await _setCard(entry, null);
      case 'mark':
        final String? cardId = await _chooseCard();
        if (cardId != null) await _setCard(entry, cardId);
      case 'delete':
        await _confirmDelete(row);
    }
  }

  Future<String?> _chooseCard() => showAppSheet<String>(
        context: context,
        builder: (BuildContext sheet) => AppSheet(
          title: 'Which card did this pay?',
          subtitle: "The debit stays as it is; the card's outstanding goes "
              'down by the same amount.',
          children: <Widget>[
            CardList(
              dividerIndent: AppSpacing.md,
              children: _linkableCards()
                  .map((CreditCard c) => AppListRow(
                        leading: const CardAvatar(size: 30),
                        title: c.displayLabel,
                        subtitle: c.issuerLine,
                        onTap: () => Navigator.of(sheet).pop(c.id),
                      ))
                  .toList(),
            ),
          ],
        ),
      );

  Future<void> _setCard(LedgerEntry entry, String? cardId) async {
    final CreditCardProvider cards = context.read<CreditCardProvider>();
    final bool ok = await cards.link(entryId: entry.id, cardId: cardId);
    if (!mounted) return;
    if (ok) {
      AppFeedback.success(
        context,
        cardId != null
            ? 'Marked as a payment to ${_cardName(cardId)}'
            : 'Unlinked from the card',
      );
      await context.read<StatementProvider>().load(force: true);
    } else {
      AppFeedback.error(
        context,
        cards.errorMessage ?? 'Could not update the transaction.',
      );
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

    final String? paidCard =
        entry.isCardPayment ? _cardName(entry.creditCardId) : null;
    final bool confirmed = await AppFeedback.confirm(
      context,
      title: entry.isTransfer
          ? 'Delete transfer?'
          : (paidCard != null ? 'Delete card payment?' : 'Delete transaction?'),
      message: paidCard != null
          // One record, read by both sides: deleting it here removes it from
          // the card too.
          ? 'The $amountText payment on ${Formatters.dayMonthYear(entry.txnDate)} '
              'is one record: deleting it removes it from this account and '
              'from $paidCard, and both are recalculated. To keep the debit '
              'here, unlink it instead.'
          : entry.isTransfer
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
        entry.isTransfer
            ? 'Transfer deleted'
            : (paidCard != null ? 'Card payment deleted' : 'Transaction deleted'),
      );
      if (paidCard != null) context.read<CreditCardProvider>().invalidate();
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
    this.onTap,
    this.onLongPress,
  });

  final StatementRow row;
  final String currency;

  /// Nickname of the other account in a transfer, if it still exists.
  final String? counterparty;

  /// Opens the edit sheet (migration 005); null leaves the row inert.
  final VoidCallback? onTap;
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

    final bool linkedRow = entry.isTransfer || entry.isCardPayment;
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
      tone: linkedRow
          ? AmountTone.transfer
          : (entry.isCredit ? AmountTone.positive : AmountTone.negative),
      meta: <String>[
        if (entry.categoryLabel != null) entry.categoryLabel!,
        if (linkedRow && other != null && !titleNamesCounterparty)
          entry.isDebit ? 'to $other' : 'from $other',
      ],
      trailingBelow: Formatters.currency(
        row.balanceAfter,
        currencyCode: currency,
        compact: true,
      ),
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }

  Widget _leading(LedgerEntry entry) {
    if (entry.isTransfer) return const TransferAvatar();
    if (entry.isCardPayment) return const CardAvatar();
    if (entry.category != null) {
      return CategoryAvatar(
        icon: entry.category!.icon,
        color: entry.category!.color,
      );
    }
    return LedgerAvatar(isCredit: entry.isCredit);
  }
}
