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
import '../../models/emi_plan.dart';
import '../../models/receivable.dart';
import '../../providers/auth_provider.dart';
import '../../providers/bank_account_provider.dart';
import '../../providers/credit_card_provider.dart';
import '../../providers/receivable_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/schema_capabilities.dart';
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
import '../statement_import/import_statement_screen.dart';
import 'card_form_sheet.dart';
import 'card_import_screen.dart';
import 'card_payment_sheet.dart';
import 'card_transaction_sheet.dart';
import 'emi_plan_sheet.dart';

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
      // Someone else's EMI: what they have paid back comes from their claim.
      if (SchemaCapabilities.emi)
        context.read<ReceivableProvider?>()?.load(userId: userId, force: force) ??
            Future<void>.value(),
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
          if (SchemaCapabilities.emi)
            IconButton(
              tooltip: 'Import statement from screenshots',
              onPressed: () => _openImport(card),
              icon: const Icon(Icons.document_scanner_outlined),
            ),
          IconButton(
            tooltip: 'Reconcile with a statement',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => ImportStatementScreen(initialCardId: card.id),
            )),
            icon: const Icon(Icons.fact_check_outlined),
          ),
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
                      if (SchemaCapabilities.emi)
                        AppButton(
                          label: 'Import screenshots',
                          icon: Icons.document_scanner_outlined,
                          variant: AppButtonVariant.tonal,
                          onPressed: () => _openImport(card),
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
                  if (SchemaCapabilities.emi) ...<Widget>[
                    const SizedBox(height: AppSpacing.md),
                    _EmiPlans(
                      card: card,
                      summaries: _planSummaries(context, card, entries),
                      currency: currency,
                      onAdd: () => _openPlanForm(card, null),
                      onOpen: (EmiPlanSummary s) => _openPlan(card, s),
                    ),
                  ],
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
                    ..._rows(context, card, statement, currency),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// One plan's figures from its components, and its claim when someone
  /// else pays it back.
  List<EmiPlanSummary> _planSummaries(
    BuildContext context,
    CreditCard card,
    List<CardEntry> entries,
  ) {
    final List<EmiPlan> plans = context.read<CreditCardProvider>().plansFor(card.id);
    if (plans.isEmpty) return const <EmiPlanSummary>[];
    final List<ClaimSummary> claims =
        context.read<ReceivableProvider?>()?.claims ?? const <ClaimSummary>[];
    return plans
        .map((EmiPlan plan) => summariseEmiPlan(
              plan: plan,
              entries: entries,
              card: card,
              claim: claims
                  .where((ClaimSummary c) => c.source?.emiPlanId == plan.id)
                  .firstOrNull,
            ))
        .toList();
  }

  List<Widget> _rows(
    BuildContext context,
    CreditCard card,
    CardStatement statement,
    String currency,
  ) {
    final BankAccountProvider accounts = context.read<BankAccountProvider>();
    final CreditCardProvider cards = context.read<CreditCardProvider>();
    // One plan's components billed in one cycle are a single instalment line.
    final List<StatementLine> lines = statementLines(statement.rows, card);
    DateTime dateOf(StatementLine line) => switch (line) {
          EntryLine(row: final CardStatementRow row) => row.entry.date,
          InstallmentLine(installment: final EmiInstallment i) => i.date,
        };
    double deltaOf(StatementLine line) => switch (line) {
          EntryLine(row: final CardStatementRow row) => -row.entry.outstandingDelta,
          InstallmentLine(installment: final EmiInstallment i) => -i.total,
        };
    final List<Widget> out = <Widget>[];
    int g = 0;
    int i = 0;
    while (i < lines.length) {
      final DateTime day = dateOf(lines[i]);
      final List<StatementLine> group = <StatementLine>[];
      double net = 0;
      while (i < lines.length && dateOf(lines[i]) == day) {
        group.add(lines[i]);
        net += deltaOf(lines[i]);
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
            .map((StatementLine line) => switch (line) {
                  EntryLine(row: final CardStatementRow row) => _CardLine(
                      row: row,
                      currency: currency,
                      accountName: accounts.byId(row.entry.accountId)?.nickname,
                      badge: _planBadge(row.entry, cards),
                      onTap: row.entry.expense != null
                          ? () => _openExpense(row.entry)
                          : null,
                      onLongPress: () => _onLongPress(row.entry),
                    ),
                  InstallmentLine() => _InstallmentLine(
                      line: line,
                      plan: cards.planById(line.installment.planId),
                      currency: currency,
                      onTap: () => _openInstallment(card, line),
                    ),
                })
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

  /// "EMI principal · paid for Arun" on a component of an EMI someone else
  /// pays back; the component's part on any plan's row.
  static String? _planBadge(CardEntry entry, CreditCardProvider cards) {
    final String? planId = entry.emiPlanId;
    if (planId == null) return null;
    final EmiPlan? plan = cards.planById(planId);
    final String part = entry.emiComponent == null
        ? 'EMI'
        : 'EMI ${(emiComponentLabels[entry.emiComponent] ?? entry.emiComponent!).toLowerCase()}';
    if (plan == null) return part;
    return plan.person != null ? '$part · paid for ${plan.person}' : '$part · ${plan.title}';
  }

  // ---- Actions -------------------------------------------------------------

  Future<void> _openImport(CreditCard card) async {
    final bool? changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => CardImportScreen(card: card)),
    );
    await _reloadAfter(changed ?? true);
  }

  Future<void> _openPlanForm(CreditCard card, EmiPlan? plan) async {
    final bool? changed = await showAppSheet<bool>(
      context: context,
      builder: (_) => EmiPlanSheet(card: card, plan: plan),
    );
    await _reloadAfter(changed);
  }

  Future<void> _openPlan(CreditCard card, EmiPlanSummary summary) async {
    final String currency = context.read<SettingsProvider>().currency;
    final bool? edit = await showAppSheet<bool>(
      context: context,
      builder: (_) => _EmiPlanDetailSheet(summary: summary, currency: currency),
    );
    if (edit == true && mounted) await _openPlanForm(card, summary.plan);
  }

  Future<void> _openInstallment(CreditCard card, InstallmentLine line) async {
    final String currency = context.read<SettingsProvider>().currency;
    final CreditCardProvider cards = context.read<CreditCardProvider>();
    final EmiPlan? plan = cards.planById(line.installment.planId);
    final Object? choice = await showAppSheet<Object>(
      context: context,
      builder: (BuildContext sheet) => _InstallmentSheet(
        line: line,
        plan: plan,
        currency: currency,
        onOpenEntry: (CardEntry entry) => Navigator.of(sheet).pop(entry),
        onOpenPlan: plan == null ? null : () => Navigator.of(sheet).pop(plan),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice is CardEntry) {
      if (choice.source == CardEntrySource.expense) {
        await _openExpense(choice);
      } else {
        await _confirmDelete(choice);
      }
    } else if (choice is EmiPlan) {
      final EmiPlanSummary? summary = _planSummaries(context, card, cards.entriesFor(card.id))
          .where((EmiPlanSummary s) => s.plan.id == choice.id)
          .firstOrNull;
      if (summary != null) await _openPlan(card, summary);
    }
  }

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
    this.badge,
  });

  final CardStatementRow row;
  final String currency;
  final String? accountName;
  final VoidCallback? onTap;
  final VoidCallback onLongPress;

  /// The EMI plan the row belongs to, in a few words.
  final String? badge;

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
        if (badge != null) badge!,
      ],
      trailingBelow:
          'Owed ${Formatters.currency(row.outstandingAfter, currencyCode: currency, compact: true)}',
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}

/// One month's EMI as a single line: the total, with its breakdown underneath.
class _InstallmentLine extends StatelessWidget {
  const _InstallmentLine({
    required this.line,
    required this.plan,
    required this.currency,
    required this.onTap,
  });

  final InstallmentLine line;
  final EmiPlan? plan;
  final String currency;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final EmiInstallment i = line.installment;
    final String title = plan == null
        ? 'EMI instalment'
        : plan!.person != null
            ? 'EMI · ${plan!.title} · paid for ${plan!.person}'
            : 'EMI · ${plan!.title}';
    return TransactionRow(
      leading: IconWell(
        icon: Icons.all_inclusive_rounded,
        tone: plan?.person != null
            ? ToneColors.transfer(context)
            : Theme.of(context).colorScheme.primary,
      ),
      title: title,
      titleMaxLines: 2,
      amount: -i.total,
      currency: currency,
      tone: plan?.person != null ? AmountTone.transfer : AmountTone.negative,
      meta: <String>[
        installmentBreakdown(
            i, (double v) => Formatters.currency(v, currencyCode: currency, compact: true)),
        '${i.entries.length} rows',
      ],
      trailingBelow:
          'Owed ${Formatters.currency(line.outstandingAfter, currencyCode: currency, compact: true)}',
      onTap: onTap,
    );
  }
}

/// The components of one instalment, each its own row on the card.
class _InstallmentSheet extends StatelessWidget {
  const _InstallmentSheet({
    required this.line,
    required this.plan,
    required this.currency,
    required this.onOpenEntry,
    required this.onOpenPlan,
  });

  final InstallmentLine line;
  final EmiPlan? plan;
  final String currency;
  final ValueChanged<CardEntry> onOpenEntry;
  final VoidCallback? onOpenPlan;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final EmiInstallment i = line.installment;
    Widget fact(String label, double value) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(label, style: theme.textTheme.labelSmall),
            const SizedBox(height: AppSpacing.xxs),
            MoneyText(value, currency: currency, style: theme.textTheme.titleSmall),
          ],
        );
    return AppSheet(
      title: 'EMI instalment · ${Formatters.currency(i.total, currencyCode: currency)}',
      subtitle: '${Formatters.dayMonthYear(i.date)} · ${plan?.label ?? 'No plan'}',
      children: <Widget>[
        AppNotice(
          message: plan?.person != null
              ? 'Paid by ${plan!.person} month by month: the principal is not your '
                  'spending, and what they send you is a repayment of this EMI.'
              : 'The principal counts as your spending; the interest and GST are '
                  "card charges. Each is its own row, shown here as one month's EMI.",
        ),
        const SizedBox(height: AppSpacing.md),
        Wrap(
          spacing: AppSpacing.xl,
          runSpacing: AppSpacing.md,
          children: <Widget>[
            fact('Principal', i.principal),
            fact('Interest', i.interest),
            fact('GST', i.tax),
            if (i.fee != 0) fact('Fees', i.fee),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        CardList(
          dividerIndent: AppSpacing.md,
          children: line.rows.reversed
              .map((CardStatementRow row) => AppListRow(
                    dense: true,
                    title: row.entry.title,
                    subtitle:
                        '${emiComponentLabels[row.entry.emiComponent] ?? row.entry.kind.label} · ${Formatters.dayMonth(row.entry.date)}',
                    trailing: MoneyText(row.entry.amount,
                        currency: currency, style: theme.textTheme.titleSmall),
                    showChevron: true,
                    onTap: () => onOpenEntry(row.entry),
                  ))
              .toList(),
        ),
        if (onOpenPlan != null) ...<Widget>[
          const SizedBox(height: AppSpacing.md),
          AppButton(
            label: 'Open the EMI plan',
            icon: Icons.all_inclusive_rounded,
            variant: AppButtonVariant.tonal,
            onPressed: onOpenPlan,
          ),
        ],
      ],
    );
  }
}

/// The card's EMI plans: each with how far it has run and, for someone
/// else's EMI, what they owe.
class _EmiPlans extends StatelessWidget {
  const _EmiPlans({
    required this.card,
    required this.summaries,
    required this.currency,
    required this.onAdd,
    required this.onOpen,
  });

  final CreditCard card;
  final List<EmiPlanSummary> summaries;
  final String currency;
  final VoidCallback onAdd;
  final ValueChanged<EmiPlanSummary> onOpen;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    if (summaries.isEmpty && !card.isActive) return const SizedBox.shrink();
    final int running = summaries.where((EmiPlanSummary s) => !s.plan.isClosed).length;
    return SurfaceCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.sm, 0),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('EMI plans', style: theme.textTheme.titleSmall),
                      Text(
                        summaries.isEmpty
                            ? 'Purchases converted to monthly instalments'
                            : '$running running',
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
                  onPressed: onAdd,
                ),
              ],
            ),
          ),
          if (summaries.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.md),
              child: Text(
                'Import a statement from screenshots and its EMI rows are grouped '
                'into instalments; or add a plan here and mark whose EMI it is.',
                style: theme.textTheme.bodySmall,
              ),
            )
          else
            for (int i = 0; i < summaries.length; i++) ...<Widget>[
              if (i > 0) const Divider(height: 1, indent: AppSpacing.rowDividerIndent),
              _EmiPlanRow(summary: summaries[i], currency: currency, onTap: () => onOpen(summaries[i])),
            ],
        ],
      ),
    );
  }
}

class _EmiPlanRow extends StatelessWidget {
  const _EmiPlanRow({required this.summary, required this.currency, required this.onTap});

  final EmiPlanSummary summary;
  final String currency;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final EmiPlan plan = summary.plan;
    final int? tenure = plan.tenureMonths;
    final double? ratio = tenure == null || tenure == 0
        ? null
        : (summary.billedMonths / tenure).clamp(0, 1).toDouble();
    final String? repayment = emiRepaymentText(
        summary, (double v) => Formatters.currency(v, currencyCode: currency, compact: true));
    final Color tone = plan.person != null ? ToneColors.transfer(context) : theme.colorScheme.primary;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 10),
        child: Row(
          children: <Widget>[
            IconWell(
              icon: plan.person != null ? Icons.handshake_outlined : Icons.all_inclusive_rounded,
              tone: tone,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(plan.label, style: theme.textTheme.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: AppSpacing.xxs),
                  Text(
                    '${emiProgressText(summary)}'
                    '${summary.billedTotal > 0 ? ' · ${Formatters.currency(summary.billedTotal, currencyCode: currency, compact: true)} billed' : ''}'
                    '${plan.isClosed ? ' · closed' : ''}',
                    style: theme.textTheme.labelSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (ratio != null) ...<Widget>[
                    const SizedBox(height: AppSpacing.xs),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
                      child: LinearProgressIndicator(value: ratio, minHeight: 5, color: tone),
                    ),
                  ],
                  if (repayment != null) ...<Widget>[
                    const SizedBox(height: AppSpacing.xs),
                    AppBadge(
                      label: repayment,
                      icon: Icons.handshake_outlined,
                      tone: summary.repayment != null && summary.repayment!.status.isOpen ? tone : null,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Icon(Icons.chevron_right_rounded, color: theme.colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

/// One plan's figures: what has been billed, what is left, and — for someone
/// else's EMI — what they owe. Pops true to edit the plan.
class _EmiPlanDetailSheet extends StatelessWidget {
  const _EmiPlanDetailSheet({required this.summary, required this.currency});

  final EmiPlanSummary summary;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final EmiPlan plan = summary.plan;
    final EmiRepayment? repayment = summary.repayment;
    String money(double v) => Formatters.currency(v, currencyCode: currency);
    Widget fact(String label, String value) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(label, style: theme.textTheme.labelSmall),
            const SizedBox(height: AppSpacing.xxs),
            Text(value, style: theme.textTheme.titleSmall),
          ],
        );
    return AppSheet(
      title: plan.title,
      subtitle: plan.person != null ? 'Paid back by ${plan.person}' : 'Your own EMI',
      footer: Row(
        children: <Widget>[
          const Spacer(),
          AppButton(
            label: 'Edit plan',
            icon: Icons.edit_outlined,
            variant: AppButtonVariant.tonal,
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
      children: <Widget>[
        Wrap(
          spacing: AppSpacing.xl,
          runSpacing: AppSpacing.md,
          children: <Widget>[
            fact('Billed so far', money(summary.billedTotal)),
            fact('Principal billed', money(summary.billedPrincipal)),
            fact('Interest & GST', money(summary.billedCharges)),
            fact('Months', emiProgressText(summary)),
            if (plan.purchaseAmount != null) fact('Purchase', money(plan.purchaseAmount!)),
            if (summary.principalLeft != null) fact('Principal left', money(summary.principalLeft!)),
            if (plan.monthlyAmount != null) fact('Monthly EMI', money(plan.monthlyAmount!)),
            if (summary.endsOn != null) fact('Last instalment', Formatters.monthYear(summary.endsOn!)),
          ],
        ),
        if (repayment != null) ...<Widget>[
          const SizedBox(height: AppSpacing.md),
          SurfaceCard(
            tone: repayment.status.isOpen ? ToneColors.transfer(context) : ToneColors.income(context),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(emiRepaymentText(summary, money) ?? '', style: theme.textTheme.titleSmall),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '${money(repayment.expected)} billed '
                  '${plan.includeCharges ? '(principal, interest and GST)' : '(principal only)'} · '
                  '${money(repayment.received)} received. Record what they send as a repayment of '
                  "this EMI — from the account it arrived in, or when importing that account's "
                  'statement. It is never counted as income.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        if (summary.installments.isEmpty)
          Text(
            "No instalment billed yet. Import the card's statement and its EMI rows are matched to this plan.",
            style: theme.textTheme.bodySmall,
          )
        else
          CardList(
            dividerIndent: AppSpacing.md,
            children: summary.installments.reversed
                .map((EmiInstallment i) => AppListRow(
                      dense: true,
                      title: 'Statement of ${Formatters.dayMonthYear(i.cycle.end)}',
                      subtitle: installmentBreakdown(
                          i, (double v) => Formatters.currency(v, currencyCode: currency, compact: true)),
                      trailing: MoneyText(i.total, currency: currency, style: theme.textTheme.titleSmall),
                    ))
                .toList(),
          ),
        if (plan.notes != null && plan.notes!.trim().isNotEmpty) ...<Widget>[
          const SizedBox(height: AppSpacing.md),
          Text(plan.notes!, style: theme.textTheme.bodySmall),
        ],
      ],
    );
  }
}
