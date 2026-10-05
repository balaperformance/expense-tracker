import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/date_utils.dart';
import '../../core/utils/formatters.dart';
import '../../models/bank_account.dart';
import '../../models/card_statement.dart';
import '../../models/credit_card.dart';
import '../../providers/auth_provider.dart';
import '../../providers/bank_account_provider.dart';
import '../../providers/credit_card_provider.dart';
import '../../providers/settings_provider.dart';
import '../../widgets/card_widgets.dart';
import '../../widgets/category_avatar.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/app_feedback.dart';
import '../../widgets/common/app_sheet.dart';
import '../../widgets/common/hero_surface.dart';
import '../../widgets/common/state_views.dart';
import '../../widgets/common/surface_card.dart';
import '../../widgets/stat_tiles.dart';
import '../../widgets/transaction_tile.dart';
import '../accounts/account_statement_screen.dart';
import '../expenses/expense_form_screen.dart';
import 'card_form_sheet.dart';
import 'card_payment_sheet.dart';
import 'card_transaction_sheet.dart';

/// One card: what is owed, the latest bill, and a statement by billing cycle
/// with the outstanding after every line.
class CardStatementScreen extends StatefulWidget {
  const CardStatementScreen({super.key, required this.cardId});

  final String cardId;

  @override
  State<CardStatementScreen> createState() => _CardStatementScreenState();
}

class _CardStatementScreenState extends State<CardStatementScreen> {
  DateTime _anchor = AppDateUtils.today();
  bool _wholeHistory = false;
  CardStatementFilter _filter = CardStatementFilter.all;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load({bool force = false}) async {
    if (!mounted) return;
    final String? userId = context.read<AuthProvider>().userId;
    if (userId == null) return;
    await Future.wait(<Future<void>>[
      context.read<CreditCardProvider>().load(userId: userId, force: force),
      context.read<BankAccountProvider>().load(userId: userId),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final CreditCardProvider provider = context.watch<CreditCardProvider>();
    final String currency = context.watch<SettingsProvider>().currency;
    final CardOverview? overview = provider.overviewFor(widget.cardId);

    if (overview == null) {
      final Widget body;
      if (provider.isLoading || provider.isIdle) {
        body = const ListSkeleton(rows: 5);
      } else if (provider.hasError) {
        // A failed read is not "deleted": offer a retry.
        body = ScrollableCentered(
          child: ErrorView(
            message: provider.errorMessage!,
            onRetry: () => _load(force: true),
          ),
        );
      } else {
        body = ScrollableCentered(
          child: EmptyState(
            icon: Icons.credit_card_rounded,
            title: 'Card not found',
            message: 'It may have been deleted.',
            actionLabel: 'All cards',
            onAction: () => Navigator.of(context).pop(),
          ),
        );
      }
      return Scaffold(appBar: AppBar(title: const Text('Card')), body: body);
    }

    final CreditCard card = overview.card;
    final List<CardEntry> entries = provider.entriesFor(card.id);
    final BillingCycle cycle = cardCycleContaining(card, _anchor);
    final BillingCycle current = overview.summary.currentCycle;
    final bool openCycle =
        !_wholeHistory && !cycle.end.isBefore(current.end);
    final CardStatement statement = buildCardStatement(
      openingOutstanding: card.openingOutstanding,
      entries: entries,
      from: _wholeHistory ? null : cycle.start,
      to: _wholeHistory ? null : cycle.end,
      filter: _filter,
    );
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: <Widget>[
            const CardAvatar(size: 34),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    card.cardName,
                    style: theme.textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    card.issuerLine,
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
            tooltip: 'Edit card',
            onPressed: () => _openForm(card),
            icon: const Icon(Icons.edit_outlined),
          ),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      body: Column(
        children: <Widget>[
          _wholeHistory
              ? Padding(
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
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                      TextButton(
                        onPressed: () => setState(() => _wholeHistory = false),
                        child: const Text('By cycle'),
                      ),
                    ],
                  ),
                )
              : MonthStepper(
                  month: cycle.start,
                  unit: 'cycle',
                  label:
                      '${Formatters.dayMonth(cycle.start)} – ${Formatters.dayMonth(cycle.end)}',
                  onPrevious: () => setState(() => _anchor =
                      DateTime(cycle.start.year, cycle.start.month, cycle.start.day - 1)),
                  onNext: openCycle
                      ? null
                      : () => setState(() => _anchor = DateTime(
                          cycle.end.year, cycle.end.month, cycle.end.day + 1)),
                  trailing: TextButton(
                    onPressed: () => setState(() => _wholeHistory = true),
                    child: const Text('All'),
                  ),
                ),
          const Divider(height: 1),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => _load(force: true),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.page,
                  AppSpacing.md,
                  AppSpacing.page,
                  AppSpacing.xxxl,
                ),
                children: <Widget>[
                  _OutstandingHero(overview: overview, currency: currency),
                  const SizedBox(height: AppSpacing.md),
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
                    children: <Widget>[
                      AppButton(
                        label: 'Pay bill',
                        icon: Icons.swap_horiz_rounded,
                        onPressed: () => _openPay(overview),
                      ),
                      if (card.isActive)
                        AppButton(
                          label: 'Add purchase',
                          icon: Icons.remove_circle_outline_rounded,
                          variant: AppButtonVariant.tonal,
                          onPressed: () => _addPurchase(card),
                        ),
                      AppButton(
                        label: 'Refund, fee…',
                        icon: Icons.add_rounded,
                        variant: AppButtonVariant.tonal,
                        onPressed: () => _openTransaction(card, entries, null),
                      ),
                    ],
                  ),
                  if (!card.isActive) ...<Widget>[
                    const SizedBox(height: AppSpacing.md),
                    const AppNotice(
                      message: 'This card is inactive: it keeps its history '
                          'and can be paid off, but is not offered for new '
                          'purchases.',
                    ),
                  ],
                  const SizedBox(height: AppSpacing.md),
                  _LatestBill(overview: overview, currency: currency),
                  const SizedBox(height: AppSpacing.md),
                  _PeriodSummary(
                    statement: statement,
                    currency: currency,
                    openingLabel: _wholeHistory
                        ? 'Opening outstanding'
                        : 'Outstanding on ${Formatters.dayMonth(DateTime(cycle.start.year, cycle.start.month, cycle.start.day - 1))}',
                    closingLabel: _wholeHistory || openCycle
                        ? 'Outstanding now'
                        : 'Outstanding on ${Formatters.dayMonth(cycle.end)}',
                  ),
                  const SizedBox(height: AppSpacing.md),
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<CardStatementFilter>(
                      segments: CardStatementFilter.values
                          .map((CardStatementFilter f) =>
                              ButtonSegment<CardStatementFilter>(
                                value: f,
                                label: Text(
                                  f == CardStatementFilter.credits
                                      ? 'Credits'
                                      : f.label,
                                ),
                              ))
                          .toList(),
                      selected: <CardStatementFilter>{_filter},
                      showSelectedIcon: false,
                      onSelectionChanged: (Set<CardStatementFilter> v) =>
                          setState(() => _filter = v.first),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  if (statement.rows.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.xl),
                      child: EmptyState(
                        compact: true,
                        icon: Icons.credit_card_rounded,
                        title: 'No transactions',
                        message: _filter == CardStatementFilter.all
                            ? 'Nothing recorded for ${_wholeHistory ? 'this card' : 'this cycle'}.'
                            : 'None of this type in this period.',
                      ),
                    )
                  else
                    ..._rows(context, statement, currency),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _rows(
    BuildContext context,
    CardStatement statement,
    String currency,
  ) {
    final BankAccountProvider accounts = context.read<BankAccountProvider>();
    final List<Widget> out = <Widget>[];
    int g = 0;
    int i = 0;
    while (i < statement.rows.length) {
      final DateTime day = statement.rows[i].entry.date;
      final List<CardStatementRow> group = <CardStatementRow>[];
      double net = 0;
      while (i < statement.rows.length && statement.rows[i].entry.date == day) {
        group.add(statement.rows[i]);
        net -= statement.rows[i].entry.outstandingDelta;
        i++;
      }
      out.add(DayHeader(
        label: Formatters.relativeDay(day),
        total: net,
        currency: currency,
        tone: AmountTone.auto,
        isFirst: g == 0,
      ));
      out.add(CardList(
        children: group
            .map((CardStatementRow row) => _CardLine(
                  row: row,
                  currency: currency,
                  accountName: accounts.byId(row.entry.accountId)?.nickname,
                  onTap: row.entry.expense != null
                      ? () => _openExpense(row.entry)
                      : null,
                  onLongPress: () => _onLongPress(row.entry),
                ))
            .toList(),
      ));
      g++;
    }
    out.add(const SizedBox(height: AppSpacing.lg));
    out.add(Text(
      'Outstanding is calculated oldest first from the opening outstanding. '
      'Tap a purchase to edit it; long-press any line for more.',
      style: Theme.of(context).textTheme.labelSmall,
      textAlign: TextAlign.center,
    ));
    return out;
  }

  // ---- Actions -------------------------------------------------------------

  Future<void> _reloadAfter(bool? changed) async {
    if (changed == true && mounted) {
      context.read<BankAccountProvider>().invalidate();
      await _load(force: true);
    }
  }

  Future<void> _openForm(CreditCard card) async {
    final bool? changed = await showAppSheet<bool>(
      context: context,
      builder: (_) => CardFormSheet(card: card),
    );
    await _reloadAfter(changed);
  }

  Future<void> _openPay(CardOverview overview) async {
    final bool? changed = await showAppSheet<bool>(
      context: context,
      builder: (_) => CardPaymentSheet(overview: overview),
    );
    await _reloadAfter(changed);
  }

  Future<void> _openTransaction(
    CreditCard card,
    List<CardEntry> entries,
    CardEntry? refundOf,
  ) async {
    final List<CardEntry> purchases = entries
        .where((CardEntry e) => e.kind == CardEntryKind.purchase)
        .toList()
      ..sort((CardEntry a, CardEntry b) => b.date.compareTo(a.date));
    final bool? changed = await showAppSheet<bool>(
      context: context,
      builder: (_) => CardTransactionSheet(
        card: card,
        purchases: purchases,
        refundOf: refundOf,
      ),
    );
    await _reloadAfter(changed);
  }

  Future<void> _addPurchase(CreditCard card) async {
    final bool? saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => ExpenseFormScreen(initialCardId: card.id),
      ),
    );
    await _reloadAfter(saved);
  }

  Future<void> _openExpense(CardEntry entry) async {
    final bool? changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => ExpenseFormScreen(expense: entry.expense),
      ),
    );
    await _reloadAfter(changed);
  }

  Future<void> _onLongPress(CardEntry entry) async {
    switch (entry.source) {
      case CardEntrySource.expense:
        await _purchaseActions(entry);
      case CardEntrySource.account:
        await _paymentActions(entry);
      case CardEntrySource.card:
        await _confirmDelete(entry);
    }
  }

  Future<void> _purchaseActions(CardEntry entry) async {
    final CreditCardProvider provider = context.read<CreditCardProvider>();
    final CreditCard? card = provider.byId(entry.cardId);
    final String? choice = await showAppSheet<String>(
      context: context,
      builder: (BuildContext sheet) => AppSheet(
        title: 'Purchase',
        subtitle: '${entry.title} · ${Formatters.dayMonthYear(entry.date)}',
        children: <Widget>[
          CardList(
            dividerIndent: AppSpacing.md,
            children: <Widget>[
              AppListRow(
                title: 'Open the expense',
                subtitle: 'Edit or delete it there',
                showChevron: true,
                onTap: () => Navigator.of(sheet).pop('open'),
              ),
              AppListRow(
                title: 'Record a refund',
                subtitle: 'Money back on the card for this purchase',
                showChevron: true,
                onTap: () => Navigator.of(sheet).pop('refund'),
              ),
            ],
          ),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'open') await _openExpense(entry);
    if (choice == 'refund' && card != null) {
      await _openTransaction(card, provider.entriesFor(card.id), entry);
    }
  }

  Future<void> _paymentActions(CardEntry entry) async {
    final BankAccount? account =
        context.read<BankAccountProvider>().byId(entry.accountId);
    final String currency = context.read<SettingsProvider>().currency;
    final String? choice = await showAppSheet<String>(
      context: context,
      builder: (BuildContext sheet) => AppSheet(
        title:
            'Payment · ${Formatters.currency(entry.amount, currencyCode: currency)}',
        subtitle: Formatters.dayMonthYear(entry.date),
        children: <Widget>[
          CardList(
            dividerIndent: AppSpacing.md,
            children: <Widget>[
              if (account != null)
                AppListRow(
                  title: 'Open ${account.displayLabel}',
                  subtitle: 'The account this payment came from',
                  showChevron: true,
                  onTap: () => Navigator.of(sheet).pop('account'),
                ),
              AppListRow(
                title: 'Unlink from this card',
                subtitle: 'Keeps the debit on the account; the card no longer '
                    'counts it as paid',
                onTap: () => Navigator.of(sheet).pop('unlink'),
              ),
              AppListRow(
                title: 'Delete payment',
                subtitle: 'Removes it from the card and the account',
                tone: Theme.of(sheet).colorScheme.error,
                onTap: () => Navigator.of(sheet).pop('delete'),
              ),
            ],
          ),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'account' && account != null) {
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => AccountStatementScreen(account: account),
      ));
      if (mounted) await _load(force: true);
    } else if (choice == 'unlink') {
      final CreditCardProvider provider = context.read<CreditCardProvider>();
      final bool ok = await provider.link(entryId: entry.id, cardId: null);
      if (!mounted) return;
      if (ok) {
        context.read<BankAccountProvider>().invalidate();
        AppFeedback.success(context, 'Unlinked — the debit stays on the account');
      } else {
        AppFeedback.error(
            context, provider.errorMessage ?? 'Could not unlink the payment.');
      }
    } else if (choice == 'delete') {
      await _confirmDelete(entry);
    }
  }

  Future<void> _confirmDelete(CardEntry entry) async {
    final String currency = context.read<SettingsProvider>().currency;
    final String amountText =
        Formatters.currency(entry.amount, currencyCode: currency);
    final String? from = entry.source == CardEntrySource.account
        ? (context.read<BankAccountProvider>().byId(entry.accountId)?.nickname ??
            'its account')
        : null;
    final bool ok = await AppFeedback.confirm(
      context,
      title: entry.kind == CardEntryKind.payment
          ? 'Delete payment?'
          : 'Delete ${entry.kind.label.toLowerCase()}?',
      message: from != null
          ? 'The $amountText payment on ${Formatters.dayMonthYear(entry.date)} '
              'is one record: deleting it removes it from this card and from '
              '$from, and both are recalculated. To keep the debit on $from, '
              'unlink it instead.'
          : '${entry.kind.label} of $amountText on '
              '${Formatters.dayMonthYear(entry.date)}. The outstanding will be '
              'recalculated.',
    );
    if (!ok || !mounted) return;
    final CreditCardProvider provider = context.read<CreditCardProvider>();
    final bool done = await provider.deleteEntry(entry);
    if (!mounted) return;
    if (done) {
      context.read<BankAccountProvider>().invalidate();
      AppFeedback.success(context, 'Deleted');
    } else {
      AppFeedback.error(
          context, provider.errorMessage ?? 'Could not delete the transaction.');
    }
  }
}

class _OutstandingHero extends StatelessWidget {
  const _OutstandingHero({required this.overview, required this.currency});

  final CardOverview overview;
  final String currency;

  @override
  Widget build(BuildContext context) =>
      HeroSurface(child: Builder(builder: _content));

  Widget _content(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final CardSummary s = overview.summary;
    final bool credit = s.hasCreditBalance;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          credit ? 'CREDIT BALANCE' : 'OUTSTANDING',
          style: AppTypography.eyebrow(theme.textTheme, color: PaletteTokens.of(context).heroAccent),
        ),
        const SizedBox(height: AppSpacing.xs),
        MoneyText(
          credit ? -s.outstanding : s.outstanding,
          currency: currency,
          fit: true,
          style: theme.textTheme.displaySmall,
        ),
        const SizedBox(height: AppSpacing.xxs),
        Text(
          s.unbilled > 0
              ? '${Formatters.currency(s.unbilled, currencyCode: currency)} spent since the last statement'
              : 'Next statement ${Formatters.dayMonthYear(s.currentCycle.end)}',
          style: theme.textTheme.bodySmall,
        ),
        if (overview.card.creditLimit > 0) ...<Widget>[
          const SizedBox(height: AppSpacing.md),
          UtilisationBar(ratio: s.utilisation),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      s.overLimit > 0 ? 'Over the limit' : 'Available credit',
                      style: theme.textTheme.labelSmall,
                    ),
                    MoneyText(
                      s.overLimit > 0 ? s.overLimit : s.available,
                      currency: currency,
                      style: theme.textTheme.titleSmall,
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Text('Credit limit', style: theme.textTheme.labelSmall),
                  MoneyText(
                    overview.card.creditLimit,
                    currency: currency,
                    style: theme.textTheme.titleSmall,
                  ),
                ],
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _LatestBill extends StatelessWidget {
  const _LatestBill({required this.overview, required this.currency});

  final CardOverview overview;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final StatementDue bill = overview.summary.lastStatement;
    final BillingCycle current = overview.summary.currentCycle;
    Widget fact(String label, Widget value) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(label, style: theme.textTheme.labelSmall),
            const SizedBox(height: AppSpacing.xxs),
            DefaultTextStyle.merge(style: theme.textTheme.titleSmall, child: value),
          ],
        );
    return SurfaceCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: Text('Latest bill', style: theme.textTheme.titleMedium)),
              AppBadge(label: 'Statement ${Formatters.dayMonth(bill.cycle.end)}'),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: <Widget>[
              Expanded(
                child: fact(
                  'Statement balance',
                  MoneyText(bill.balance > 0 ? bill.balance : 0, currency: currency),
                ),
              ),
              Expanded(
                child: fact('Due date', Text(Formatters.dayMonthYear(bill.cycle.dueDate))),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: <Widget>[
              Expanded(
                child: fact(
                  'Paid & credited since',
                  MoneyText(bill.credited, currency: currency),
                ),
              ),
              Expanded(
                child: fact(
                  'Still to pay',
                  MoneyText(
                    bill.remaining,
                    currency: currency,
                    tone: bill.status == DueStatus.overdue
                        ? AmountTone.negative
                        : AmountTone.neutral,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          DueLine(summary: overview.summary, currency: currency),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Cycle ${Formatters.dayMonth(current.start)} – '
            '${Formatters.dayMonth(current.end)} is open: '
            '${Formatters.currency(overview.summary.unbilled, currencyCode: currency)} '
            'charged so far, billed on ${Formatters.dayMonthYear(current.end)} '
            'and due ${Formatters.dayMonthYear(current.dueDate)}.',
            style: theme.textTheme.labelSmall,
          ),
        ],
      ),
    );
  }
}

class _PeriodSummary extends StatelessWidget {
  const _PeriodSummary({
    required this.statement,
    required this.currency,
    required this.openingLabel,
    required this.closingLabel,
  });

  final CardStatement statement;
  final String currency;
  final String openingLabel;
  final String closingLabel;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SurfaceCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        children: <Widget>[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Flexible(child: Text(openingLabel, style: theme.textTheme.bodySmall)),
              MoneyText(statement.opening, currency: currency, style: theme.textTheme.titleSmall),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
            child: Divider(height: 1),
          ),
          Row(
            children: <Widget>[
              Expanded(
                child: StatTile(
                  label: 'Purchases',
                  amount: statement.purchases,
                  currency: currency,
                  icon: Icons.north_east_rounded,
                  tone: ToneColors.expense(context),
                  colouredAmount: true,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: StatTile(
                  label: 'Fees & interest',
                  amount: statement.charges,
                  currency: currency,
                  icon: Icons.north_east_rounded,
                  tone: ToneColors.warning(context),
                  colouredAmount: true,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: <Widget>[
              Expanded(
                child: StatTile(
                  label: 'Payments',
                  amount: statement.payments,
                  currency: currency,
                  icon: Icons.swap_horiz_rounded,
                  tone: ToneColors.transfer(context),
                  colouredAmount: true,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: StatTile(
                  label: 'Refunds & credits',
                  amount: statement.credits,
                  currency: currency,
                  icon: Icons.south_west_rounded,
                  tone: ToneColors.income(context),
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
                  children: <Widget>[
                    Text(closingLabel, style: theme.textTheme.labelMedium),
                    Text(
                      '${statement.rows.length} ${statement.rows.length == 1 ? 'transaction' : 'transactions'}',
                      style: theme.textTheme.labelSmall,
                    ),
                  ],
                ),
              ),
              Flexible(
                child: MoneyText(
                  statement.closing,
                  currency: currency,
                  fit: true,
                  textAlign: TextAlign.end,
                  tone: statement.closing < 0 ? AmountTone.positive : AmountTone.neutral,
                  style: theme.textTheme.headlineMedium,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CardLine extends StatelessWidget {
  const _CardLine({
    required this.row,
    required this.currency,
    required this.accountName,
    required this.onTap,
    required this.onLongPress,
  });

  final CardStatementRow row;
  final String currency;
  final String? accountName;
  final VoidCallback? onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final CardEntry entry = row.entry;
    final Widget leading = entry.kind == CardEntryKind.purchase
        ? CategoryAvatar(
            icon: entry.category?.icon,
            color: entry.category?.color,
          )
        : CardMovementAvatar(entry: entry);
    final String? source = entry.kind == CardEntryKind.payment
        ? (entry.source == CardEntrySource.account
            ? (accountName != null ? 'from $accountName' : 'from a bank account')
            : 'in cash')
        : null;
    return TransactionRow(
      leading: leading,
      title: entry.title,
      titleMaxLines: 2,
      amount: -entry.outstandingDelta,
      currency: currency,
      tone: entry.kind == CardEntryKind.payment
          ? AmountTone.transfer
          : (entry.isCharge ? AmountTone.negative : AmountTone.positive),
      meta: <String>[
        entry.kind == CardEntryKind.purchase
            ? (entry.category?.name ?? 'Purchase')
            : entry.kind.label,
        if (source != null) source,
      ],
      trailingBelow:
          'Owed ${Formatters.currency(row.outstandingAfter, currencyCode: currency, compact: true)}',
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}
