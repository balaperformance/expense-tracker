import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/utils/date_utils.dart';
import '../../core/utils/formatters.dart';
import '../../models/credit_card.dart';
import '../../models/expense_category.dart';
import '../../providers/auth_provider.dart';
import '../../providers/bank_account_provider.dart';
import '../../providers/budget_provider.dart';
import '../../providers/card_import_provider.dart';
import '../../providers/category_provider.dart';
import '../../providers/credit_card_provider.dart';
import '../../providers/dashboard_provider.dart';
import '../../providers/expense_provider.dart';
import '../../providers/receivable_provider.dart';
import '../../providers/reports_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/schema_capabilities.dart';
import '../../widgets/card_widgets.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/app_feedback.dart';
import '../../widgets/common/app_fields.dart';
import '../../widgets/common/app_sheet.dart';
import '../../widgets/common/money_text.dart';
import '../../widgets/common/state_views.dart';
import '../../widgets/common/surface_card.dart';
import '../../widgets/transaction_tile.dart';
import 'card_import_sheets.dart';

enum _Filter { all, selected, duplicates, attention }

const List<String> _months = <String>[
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// A card's statement from screenshots of the card app or net banking. The
/// images are read on this phone and deleted the moment their text is out;
/// only the rows the user confirms are written, each exactly as adding it by
/// hand. The parsing, duplicate checks, EMI grouping and plan come from the
/// web app's own engine (CardImportProvider).
class CardImportScreen extends StatefulWidget {
  const CardImportScreen({super.key, required this.card});

  final CreditCard card;

  @override
  State<CardImportScreen> createState() => _CardImportScreenState();
}

class _CardImportScreenState extends State<CardImportScreen> {
  _Filter _filter = _Filter.all;
  CardImportProvider? _provider;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _provider = context.read<CardImportProvider>();
  }

  @override
  void dispose() {
    // The session is forgotten as the screen closes: nothing of it is kept.
    _provider?.reset();
    super.dispose();
  }

  Future<void> _init() async {
    final String? userId = context.read<AuthProvider>().userId;
    if (userId == null) return;
    await Future.wait(<Future<void>>[
      context.read<BankAccountProvider>().load(userId: userId),
      context.read<CreditCardProvider>().load(userId: userId),
      if (SchemaCapabilities.treatments)
        context.read<ReceivableProvider?>()?.load(userId: userId) ?? Future<void>.value(),
    ]);
    if (!mounted) return;
    await context.read<CardImportProvider>().start(
          userId: userId,
          card: widget.card,
          accounts: context.read<BankAccountProvider>().accounts,
          categories: context.read<CategoryProvider>().categories,
          currency: context.read<SettingsProvider>().currency,
        );
  }

  @override
  Widget build(BuildContext context) {
    final CardImportProvider provider = context.watch<CardImportProvider>();
    final String currency = context.watch<SettingsProvider>().currency;
    final CreditCard card = widget.card;
    final ThemeData theme = Theme.of(context);

    if (!SchemaCapabilities.creditCards || !SchemaCapabilities.emi) {
      return Scaffold(
        appBar: AppBar(title: const Text('Import statement')),
        body: const ScrollableCentered(
          child: EmptyState(
            icon: Icons.storage_rounded,
            title: 'One migration away',
            message: 'Importing a card statement from screenshots needs '
                'ui/supabase/016_card_statement_emi.sql (after 004 and 005). '
                'Run it in the Supabase SQL editor, then open this screen again.',
          ),
        ),
      );
    }

    final Widget title = Row(
      children: <Widget>[
        const CardAvatar(size: 34),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(card.cardName, style: theme.textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(card.issuerLine, style: theme.textTheme.labelSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ],
    );

    final CardImportOutcome? result = provider.result;
    if (result != null) {
      return Scaffold(
        appBar: AppBar(titleSpacing: 0, title: title),
        body: _ResultView(result: result, provider: provider, currency: currency),
      );
    }

    if (provider.isLoading || provider.cycle == null) {
      return Scaffold(
        appBar: AppBar(titleSpacing: 0, title: title),
        body: provider.hasError
            ? ScrollableCentered(
                child: ErrorView(message: provider.errorMessage!, onRetry: _init),
              )
            : const ListSkeleton(rows: 4),
      );
    }

    if (provider.shots.isEmpty) return _setup(context, provider, title);

    final Map<String, Object?> summary = provider.summary;
    final int selected = (summary['selected'] as num?)?.toInt() ?? 0;
    final bool busy = provider.reading != null || provider.importing != null;
    final bool blocked = selected == 0 || busy || provider.checkFailed || !provider.hasContext;
    final ({int done, int total})? importing = provider.importing;

    return Scaffold(
      appBar: AppBar(titleSpacing: 0, title: title),
      body: Column(
        children: <Widget>[
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(AppSpacing.page, AppSpacing.md, AppSpacing.page, AppSpacing.xxxl),
              children: <Widget>[
                _statementCard(context, provider, busy),
                if (provider.reading != null) ...<Widget>[
                  const SizedBox(height: AppSpacing.md),
                  _progress(context, provider),
                ],
                if (provider.checkFailed) ...<Widget>[
                  const SizedBox(height: AppSpacing.md),
                  SurfaceCard(
                    tone: ToneColors.warning(context),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text('Could not read what the card already holds', style: theme.textTheme.titleSmall),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          'Rows repeated between screenshots are marked, but duplicates of what is already on the card '
                          'cannot be found yet. Importing waits until this succeeds.',
                          style: theme.textTheme.bodySmall,
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        AppButton(
                          label: 'Check again',
                          icon: Icons.refresh_rounded,
                          size: AppButtonSize.small,
                          onPressed: busy ? null : provider.recheck,
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: AppSpacing.md),
                _summaryTiles(context, summary),
                if (provider.groups.isNotEmpty) ...<Widget>[
                  const SizedBox(height: AppSpacing.md),
                  AppNotice(
                    icon: Icons.all_inclusive_rounded,
                    message: '${provider.groups.length} EMI ${provider.groups.length == 1 ? 'instalment' : 'instalments'} '
                        'found: principal, interest and GST billed together are shown as one transaction with its '
                        'breakdown. Tap an instalment to say which EMI it belongs to.',
                  ),
                ],
                const SizedBox(height: AppSpacing.md),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<_Filter>(
                    segments: const <ButtonSegment<_Filter>>[
                      ButtonSegment<_Filter>(value: _Filter.all, label: Text('All')),
                      ButtonSegment<_Filter>(value: _Filter.selected, label: Text('To import')),
                      ButtonSegment<_Filter>(value: _Filter.duplicates, label: Text('Dupes')),
                      ButtonSegment<_Filter>(value: _Filter.attention, label: Text('Check')),
                    ],
                    selected: <_Filter>{_filter},
                    showSelectedIcon: false,
                    onSelectionChanged: (Set<_Filter> v) => setState(() => _filter = v.first),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Row(
                  children: <Widget>[
                    AppButton(
                      label: 'Select all',
                      icon: Icons.check_rounded,
                      size: AppButtonSize.small,
                      variant: AppButtonVariant.ghost,
                      onPressed: busy ? null : () => provider.selectAll(true),
                    ),
                    AppButton(
                      label: 'Regroup EMIs',
                      icon: Icons.refresh_rounded,
                      size: AppButtonSize.small,
                      variant: AppButtonVariant.ghost,
                      onPressed: busy ? null : provider.regroup,
                    ),
                    const Spacer(),
                    Text('$selected of ${summary['total'] ?? 0} selected', style: theme.textTheme.labelSmall),
                  ],
                ),
                if (provider.problem != null) ...<Widget>[
                  const SizedBox(height: AppSpacing.sm),
                  InlineError(message: provider.problem!),
                ],
                const SizedBox(height: AppSpacing.sm),
                ..._rows(context, provider, currency, busy),
              ],
            ),
          ),
          _ImportBar(
            count: selected,
            busy: busy,
            blocked: blocked,
            importing: importing,
            onReset: busy ? null : provider.reset,
            onImport: blocked ? null : () => _confirmImport(provider),
          ),
        ],
      ),
    );
  }

  // ---- Setup ---------------------------------------------------------------

  Widget _setup(BuildContext context, CardImportProvider provider, Widget title) {
    final ThemeData theme = Theme.of(context);
    final bool busy = provider.reading != null;
    return Scaffold(
      appBar: AppBar(titleSpacing: 0, title: title),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpacing.page, AppSpacing.md, AppSpacing.page, AppSpacing.xxxl),
        children: <Widget>[
          Text(
            'Add the transactions on a card statement from screenshots of your card app or net banking. '
            'Purchases, bill payments, fees and interest are recognised, EMI rows are grouped into monthly '
            'instalments, and anything already on the card is left out.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: AppSpacing.lg),
          const FieldLabel('Statement', isRequired: true, hint: 'Every row is filed under it'),
          SelectField(
            value: provider.cycle?.label,
            icon: Icons.calendar_today_rounded,
            enabled: !busy,
            onTap: () => _pickCycle(provider),
          ),
          const SizedBox(height: AppSpacing.lg),
          SurfaceCard(
            onTap: busy ? null : provider.pickAndRead,
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: Column(
              children: <Widget>[
                IconWell(icon: Icons.image_outlined, tone: theme.colorScheme.primary, size: 46),
                const SizedBox(height: AppSpacing.sm),
                Text('Choose screenshots', style: theme.textTheme.titleMedium),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'Several at once, in any order. Overlapping screenshots are fine — a row is counted once.',
                  style: theme.textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
          if (provider.reading != null) ...<Widget>[
            const SizedBox(height: AppSpacing.md),
            _progress(context, provider),
          ],
          if (provider.problem != null) ...<Widget>[
            const SizedBox(height: AppSpacing.md),
            AppNotice(icon: Icons.error_outline_rounded, tone: theme.colorScheme.error, message: provider.problem!),
          ],
        ],
      ),
    );
  }

  Future<void> _pickCycle(CardImportProvider provider) async {
    final CardCycleOption? chosen = await showAppSheet<CardCycleOption>(
      context: context,
      builder: (BuildContext sheet) => AppSheet(
        title: 'Which statement?',
        subtitle: 'Every row is filed under it, whatever its date',
        children: <Widget>[
          CardList(
            dividerIndent: AppSpacing.md,
            children: provider.cycles
                .map((CardCycleOption c) => AppListRow(
                      dense: true,
                      title: c.label,
                      trailing: c.end == provider.cycle?.end ? const Icon(Icons.check_rounded) : null,
                      onTap: () => Navigator.of(sheet).pop(c),
                    ))
                .toList(),
          ),
        ],
      ),
    );
    if (chosen != null) provider.chooseCycle(chosen);
  }

  Widget _progress(BuildContext context, CardImportProvider provider) {
    final ({String name, int index, int total, bool checking}) reading = provider.reading!;
    final ThemeData theme = Theme.of(context);
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            reading.checking
                ? 'Checking the card for rows already recorded…'
                : 'Reading ${reading.name} (${reading.index} of ${reading.total})…',
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: AppSpacing.sm),
          const LinearProgressIndicator(),
        ],
      ),
    );
  }

  // ---- Review --------------------------------------------------------------

  Widget _statementCard(BuildContext context, CardImportProvider provider, bool busy) {
    final ThemeData theme = Theme.of(context);
    final CardCycleOption cycle = provider.cycle!;
    final CreditCard card = widget.card;
    final DateTime start = AppDateUtils.parseDate(cycle.cycle['start']! as String);
    final DateTime end = AppDateUtils.parseDate(cycle.cycle['end']! as String);
    ImportedShot? mismatch;
    ImportedShot? monthMismatch;
    for (final ImportedShot s in provider.shots) {
      if (s.last4 != null && card.last4 != null && s.last4 != card.last4) mismatch ??= s;
      if (s.month != null && s.month != end.month) monthMismatch ??= s;
    }
    final List<String> warnings = provider.shots.expand((ImportedShot s) => s.warnings).toList();
    return SurfaceCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.md, 10, AppSpacing.md, 10),
            child: Row(
              children: <Widget>[
                IconWell(icon: Icons.calendar_today_rounded, tone: theme.colorScheme.primary, size: 36),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('Statement of ${Formatters.dayMonthYear(end)}', style: theme.textTheme.titleSmall),
                      Text(
                        '${Formatters.dayMonth(start)} – ${Formatters.dayMonth(end)} · ${provider.shots.length} '
                        '${provider.shots.length == 1 ? 'screenshot' : 'screenshots'} · ${provider.items.length} rows',
                        style: theme.textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                AppButton(
                  label: 'Add more',
                  icon: Icons.add_rounded,
                  size: AppButtonSize.small,
                  variant: AppButtonVariant.tonal,
                  onPressed: busy ? null : provider.pickAndRead,
                ),
              ],
            ),
          ),
          if (mismatch != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.md),
              child: AppNotice(
                icon: Icons.warning_amber_rounded,
                tone: ToneColors.warning(context),
                message: 'A screenshot shows a card ending ${mismatch.last4}, not ${card.displayLabel}. '
                    'Start over if that is the wrong card.',
              ),
            ),
          if (monthMismatch != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.md),
              child: AppNotice(
                message: 'A screenshot names ${_months[monthMismatch.month! - 1]}; the rows are filed under the '
                    'statement of ${Formatters.dayMonthYear(end)}. Start over and pick another statement if that is wrong.',
              ),
            ),
          if (warnings.isNotEmpty)
            Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                dense: true,
                title: Text('What could not be read', style: theme.textTheme.labelMedium),
                children: warnings
                    .take(12)
                    .map((String w) => ListTile(dense: true, title: Text(w, style: theme.textTheme.bodySmall)))
                    .toList(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _summaryTiles(BuildContext context, Map<String, Object?> summary) {
    int n(String key) => (summary[key] as num?)?.toInt() ?? 0;
    return Row(
      children: <Widget>[
        Expanded(child: _Tile(label: 'Found', value: '${n('total')}')),
        const SizedBox(width: AppSpacing.sm),
        Expanded(child: _Tile(label: 'To import', value: '${n('selected')}', tone: Theme.of(context).colorScheme.primary)),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: _Tile(
            label: 'Duplicates',
            value: '${n('duplicates')}',
            detail: n('unchecked') > 0 ? '${n('unchecked')} to decide' : 'left out',
            tone: ToneColors.warning(context),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: _Tile(
            label: 'Check',
            value: '${n('attention')}',
            detail: n('blocked') > 0 ? '${n('blocked')} need details' : null,
            tone: n('attention') > 0 ? ToneColors.warning(context) : null,
          ),
        ),
      ],
    );
  }

  bool _visible(CardImportProvider provider, Map<String, Object?> row) {
    final Map<String, Object?> flags = provider.itemView(row['id']! as String) ?? const <String, Object?>{};
    switch (_filter) {
      case _Filter.all:
        return true;
      case _Filter.selected:
        return row['selected'] == true && flags['leftOut'] != true;
      case _Filter.duplicates:
        return row['duplicate'] != null;
      case _Filter.attention:
        return flags['attention'] == true;
    }
  }

  List<Widget> _rows(BuildContext context, CardImportProvider provider, String currency, bool busy) {
    final List<Map<String, Object?>> visible =
        provider.items.where((Map<String, Object?> r) => _visible(provider, r)).toList()
          ..sort((Map<String, Object?> a, Map<String, Object?> b) => (b['date']! as String).compareTo(a['date']! as String));
    if (visible.isEmpty) {
      return const <Widget>[
        Padding(
          padding: EdgeInsets.only(top: AppSpacing.xl),
          child: EmptyState(compact: true, icon: Icons.filter_list_off_rounded, title: 'Nothing here', message: 'No rows match this view.'),
        ),
      ];
    }
    final Map<String, ExpenseCategory> categories = <String, ExpenseCategory>{
      for (final ExpenseCategory c in context.read<CategoryProvider>().categories) c.id: c,
    };
    final Set<String> visibleIds = visible.map((Map<String, Object?> r) => r['id']! as String).toSet();
    final List<Widget> out = <Widget>[];
    int i = 0;
    while (i < visible.length) {
      final String day = visible[i]['date']! as String;
      final List<Map<String, Object?>> group = <Map<String, Object?>>[];
      double net = 0;
      while (i < visible.length && visible[i]['date'] == day) {
        final Map<String, Object?> row = visible[i];
        group.add(row);
        final double amount = (row['amount']! as num).toDouble();
        net += row['direction'] == 'credit' ? amount : -amount;
        i++;
      }
      out.add(DayHeader(
        label: Formatters.relativeDay(AppDateUtils.parseDate(day)),
        total: net,
        currency: currency,
        tone: AmountTone.auto,
        isFirst: out.isEmpty,
      ));
      final Set<String> shownGroups = <String>{};
      final List<Widget> tiles = <Widget>[];
      for (final Map<String, Object?> row in group) {
        final String? groupId = row['groupId'] as String?;
        if (groupId != null) {
          if (!shownGroups.add(groupId)) continue;
          tiles.add(_GroupBlock(
            provider: provider,
            groupId: groupId,
            members: provider.membersOf(groupId).where((Map<String, Object?> m) => visibleIds.contains(m['id'])).toList(),
            currency: currency,
            enabled: !busy,
            onOpen: () => _openGroup(provider, groupId),
            onToggle: provider.toggle,
            onOpenMember: (String id) => _openRow(provider, id),
          ));
          continue;
        }
        tiles.add(_RowTile(
          row: row,
          flags: provider.itemView(row['id']! as String) ?? const <String, Object?>{},
          category: categories[row['categoryId']],
          currency: currency,
          enabled: !busy,
          onToggle: () => provider.toggle(row['id']! as String),
          onDecide: (String d) => provider.decideDuplicate(row['id']! as String, d),
          onEdit: () => _openRow(provider, row['id']! as String),
          onKind: (String kind) async {
            await provider.edit(row['id']! as String, <String, Object?>{'kind': kind});
            if (kind.startsWith('emi')) await provider.regroup();
          },
        ));
      }
      out.add(CardList(dividerIndent: AppSpacing.md, children: tiles));
    }
    out.add(const SizedBox(height: AppSpacing.lg));
    out.add(Text(
      'Tap a row to correct what was read. Rows already on the card are left out unless you say otherwise.',
      style: Theme.of(context).textTheme.labelSmall,
      textAlign: TextAlign.center,
    ));
    return out;
  }

  Future<void> _openRow(CardImportProvider provider, String itemId) async {
    await showAppSheet<void>(
      context: context,
      builder: (_) => CardImportRowSheet(provider: provider, itemId: itemId, card: widget.card),
    );
  }

  Future<void> _openGroup(CardImportProvider provider, String groupId) async {
    final String? openRow = await showAppSheet<String>(
      context: context,
      builder: (_) => EmiGroupSheet(provider: provider, groupId: groupId, card: widget.card),
    );
    if (openRow != null && mounted) await _openRow(provider, openRow);
  }

  Future<void> _confirmImport(CardImportProvider provider) async {
    final Map<String, Object?> counts = await provider.preview();
    if (!mounted) return;
    final List<String> lines = importCountLines(counts);
    final bool ok = await AppFeedback.confirm(
      context,
      title: 'Add to ${widget.card.cardName}?',
      message: lines.isEmpty
          ? 'Nothing is selected.'
          : '${lines.join('. ')}. Every row is filed under the ${provider.cycle!.label.toLowerCase()}.',
      confirmLabel: 'Import',
      destructive: false,
    );
    if (!ok || !mounted) return;
    final bool done = await provider.runImport();
    if (!mounted) return;
    if (done) {
      context.read<BankAccountProvider>().invalidate();
      context.read<CreditCardProvider>().invalidate();
      context.read<DashboardProvider>().invalidate();
      context.read<BudgetProvider>().invalidate();
      context.read<ReportsProvider>().invalidate();
      context.read<ReceivableProvider?>()?.invalidate();
      await context.read<ExpenseProvider>().refresh();
    } else if (provider.problem != null) {
      AppFeedback.error(context, provider.problem!);
    }
  }
}

/// "3 purchases", "2 EMI instalments (6 rows: principal, interest, GST)" — the
/// confirmation's and the result's lines.
List<String> importCountLines(Map<String, Object?> counts) {
  int n(String key) => (counts[key] as num?)?.toInt() ?? 0;
  String plural(int value, String one, String many) => '$value ${value == 1 ? one : many}';
  return <String>[
    if (n('purchases') > 0) plural(n('purchases'), 'purchase', 'purchases'),
    if (n('installments') > 0)
      '${plural(n('installments'), 'EMI instalment', 'EMI instalments')} '
          '(${plural(n('emiComponents'), 'row', 'rows')}: principal, interest, GST)',
    if (n('plans') > 0) plural(n('plans'), 'new EMI plan', 'new EMI plans'),
    if (n('payments') > 0)
      '${plural(n('payments'), 'bill payment', 'bill payments')}'
          '${n('linked') > 0 ? ' (${n('linked')} linked to bank debits already recorded)' : ''}',
    if (n('charges') > 0) plural(n('charges'), 'fee or interest charge', 'fee and interest charges'),
    if (n('credits') > 0) plural(n('credits'), 'refund or cashback', 'refunds and cashback'),
  ];
}

class _Tile extends StatelessWidget {
  const _Tile({required this.label, required this.value, this.detail, this.tone});

  final String label;
  final String value;
  final String? detail;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color colour = tone ?? theme.colorScheme.onSurface;
    return SurfaceCard(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: theme.textTheme.labelSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
          Text(value, style: theme.textTheme.titleLarge?.copyWith(color: colour)),
          if (detail != null)
            Text(detail!, style: theme.textTheme.labelSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}

/// One statement row: checkbox, title, what it is, flags, amount.
class _RowTile extends StatelessWidget {
  const _RowTile({
    required this.row,
    required this.flags,
    required this.category,
    required this.currency,
    required this.enabled,
    required this.onToggle,
    required this.onDecide,
    required this.onEdit,
    required this.onKind,
  });

  static const Map<String, String> _problems = <String, String>{
    'category': 'Choose category',
    'kind': 'What is it?',
    'amount': 'Check amount',
    'emiPlan': 'Which EMI?',
  };

  final Map<String, Object?> row;
  final Map<String, Object?> flags;
  final ExpenseCategory? category;
  final String currency;
  final bool enabled;
  final VoidCallback onToggle;
  final ValueChanged<String> onDecide;
  final VoidCallback onEdit;
  final ValueChanged<String> onKind;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool leftOut = flags['leftOut'] == true;
    final bool unchecked = flags['unchecked'] == true;
    final bool selected = row['selected'] == true && !leftOut;
    final String kind = row['kind']! as String;
    final bool purchase = kind == 'purchase' || kind == 'emiPrincipal';
    final bool credit = row['direction'] == 'credit';
    final double amount = (row['amount']! as num).toDouble();
    final Map<String, Object?>? link = row['paymentLink'] as Map<String, Object?>?;
    final String detail = purchase
        ? (category?.name ?? 'No category')
        : kind == 'payment'
            ? (link?['type'] == 'entry'
                ? 'Bank debit: ${link!['label']}'
                : link?['type'] == 'record'
                    ? 'Recorded on the card'
                    : 'Payment')
            : (flags['kindLabel'] as String? ?? kind);
    final String? problem = flags['problem'] as String?;
    final String? badge = flags['duplicateBadge'] as String?;
    final List<Map<String, Object?>> kinds =
        ((flags['kinds'] as List<Object?>?) ?? const <Object?>[]).cast<Map<String, Object?>>();
    final bool warn = leftOut || unchecked || (flags['attention'] == true);
    return Opacity(
      opacity: selected ? 1 : 0.55,
      child: InkWell(
        onTap: enabled ? onEdit : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.rowPadY),
          child: Row(
            children: <Widget>[
              Checkbox(
                value: selected,
                onChanged: enabled && !leftOut ? (_) => onToggle() : null,
                visualDensity: VisualDensity.compact,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(row['title']! as String, style: theme.textTheme.titleSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: AppSpacing.xxs),
                    Text(
                      <String>[
                        detail,
                        if (badge != null) badge,
                        if (flags['attention'] == true && problem == null && !unchecked && !leftOut) 'Check this row',
                      ].join(' · '),
                      style: theme.textTheme.labelSmall?.copyWith(color: warn ? ToneColors.warning(context) : null),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Wrap(
                      spacing: AppSpacing.xs,
                      runSpacing: AppSpacing.xxs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: <Widget>[
                        if (kinds.isNotEmpty)
                          _KindPill(
                            value: kind,
                            label: flags['kindLabel'] as String? ?? kind,
                            kinds: kinds,
                            enabled: enabled,
                            tone: kind == 'payment'
                                ? ToneColors.transfer(context)
                                : credit
                                    ? ToneColors.income(context)
                                    : theme.colorScheme.primary,
                            onChanged: onKind,
                          ),
                        if (problem != null && !leftOut)
                          AppBadge(label: _problems[problem] ?? 'Add details', icon: Icons.edit_outlined, tone: ToneColors.warning(context)),
                      ],
                    ),
                    if (unchecked) ...<Widget>[
                      const SizedBox(height: AppSpacing.xs),
                      Wrap(
                        spacing: AppSpacing.xs,
                        runSpacing: AppSpacing.xxs,
                        children: <Widget>[
                          AppButton(
                            label: 'Duplicate',
                            icon: Icons.content_copy_rounded,
                            size: AppButtonSize.small,
                            variant: AppButtonVariant.secondary,
                            onPressed: enabled ? () => onDecide('duplicate') : null,
                          ),
                          AppButton(
                            label: 'Not a duplicate',
                            icon: Icons.check_rounded,
                            size: AppButtonSize.small,
                            variant: AppButtonVariant.ghost,
                            onPressed: enabled ? () => onDecide('notDuplicate') : null,
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              MoneyText(
                credit ? amount : -amount,
                currency: currency,
                signed: true,
                tone: kind == 'payment'
                    ? AmountTone.transfer
                    : (credit ? AmountTone.positive : AmountTone.negative),
                style: theme.textTheme.titleSmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The inline "what it is" choice under a row.
class _KindPill extends StatelessWidget {
  const _KindPill({
    required this.value,
    required this.label,
    required this.kinds,
    required this.enabled,
    required this.tone,
    required this.onChanged,
  });

  final String value;
  final String label;
  final List<Map<String, Object?>> kinds;
  final bool enabled;
  final Color tone;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return PopupMenuButton<String>(
      enabled: enabled,
      initialValue: value,
      onSelected: onChanged,
      itemBuilder: (_) => kinds
          .map((Map<String, Object?> k) => PopupMenuItem<String>(
                value: k['kind']! as String,
                child: Text(k['label']! as String),
              ))
          .toList(),
      child: Container(
        height: 26,
        padding: const EdgeInsets.fromLTRB(10, 0, 6, 0),
        decoration: BoxDecoration(
          color: ToneColors.wash(context, tone),
          borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(label, style: theme.textTheme.labelSmall?.copyWith(color: tone, fontWeight: FontWeight.w600)),
            Icon(Icons.expand_more_rounded, size: 14, color: tone),
          ],
        ),
      ),
    );
  }
}

/// One month's instalment: a header with the total and plan, its components under it.
class _GroupBlock extends StatelessWidget {
  const _GroupBlock({
    required this.provider,
    required this.groupId,
    required this.members,
    required this.currency,
    required this.enabled,
    required this.onOpen,
    required this.onToggle,
    required this.onOpenMember,
  });

  final CardImportProvider provider;
  final String groupId;
  final List<Map<String, Object?>> members;
  final String currency;
  final bool enabled;
  final VoidCallback onOpen;
  final ValueChanged<String> onToggle;
  final ValueChanged<String> onOpenMember;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Map<String, Object?> view = provider.groupView(groupId) ?? const <String, Object?>{};
    final Map<String, Object?>? group = provider.group(groupId);
    final bool needsPlan = view['needsPlan'] == true;
    final bool uncertain = group?['uncertain'] == true;
    final double total = (view['total'] as num?)?.toDouble() ?? 0;
    final Color tone = needsPlan || uncertain ? ToneColors.warning(context) : theme.colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        InkWell(
          onTap: enabled ? onOpen : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.md, 10, AppSpacing.md, 10),
            child: Row(
              children: <Widget>[
                IconWell(icon: Icons.all_inclusive_rounded, tone: tone),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('EMI instalment · ${view['planLabel'] ?? 'Which EMI?'}',
                          style: theme.textTheme.titleSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                      Text(view['breakdown'] as String? ?? '', style: theme.textTheme.labelSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                      if (needsPlan || uncertain) ...<Widget>[
                        const SizedBox(height: AppSpacing.xs),
                        AppBadge(
                          label: needsPlan ? 'Which EMI?' : 'Check grouping',
                          icon: needsPlan ? Icons.edit_outlined : Icons.fact_check_outlined,
                          tone: ToneColors.warning(context),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                MoneyText(-total, currency: currency, signed: true, tone: AmountTone.negative, style: theme.textTheme.titleSmall),
              ],
            ),
          ),
        ),
        for (final Map<String, Object?> m in members)
          Builder(builder: (BuildContext context) {
            final Map<String, Object?> flags = provider.itemView(m['id']! as String) ?? const <String, Object?>{};
            final bool leftOut = flags['leftOut'] == true;
            final bool selected = m['selected'] == true && !leftOut;
            return Opacity(
              opacity: selected ? 1 : 0.55,
              child: InkWell(
                onTap: enabled ? () => onOpenMember(m['id']! as String) : null,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 4, AppSpacing.md, 4),
                  child: Row(
                    children: <Widget>[
                      Checkbox(
                        value: selected,
                        onChanged: enabled && !leftOut ? (_) => onToggle(m['id']! as String) : null,
                        visualDensity: VisualDensity.compact,
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(m['title']! as String, style: theme.textTheme.bodyMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                            Text(
                              <String>[
                                flags['kindLabel'] as String? ?? '',
                                if (flags['duplicateBadge'] != null) flags['duplicateBadge']! as String,
                              ].join(' · '),
                              style: theme.textTheme.labelSmall,
                            ),
                          ],
                        ),
                      ),
                      MoneyText(-(m['amount']! as num).toDouble(), currency: currency, signed: true, tone: AmountTone.negative, style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
              ),
            );
          }),
      ],
    );
  }
}

class _ImportBar extends StatelessWidget {
  const _ImportBar({
    required this.count,
    required this.busy,
    required this.blocked,
    required this.importing,
    required this.onReset,
    required this.onImport,
  });

  final int count;
  final bool busy;
  final bool blocked;
  final ({int done, int total})? importing;
  final VoidCallback? onReset;
  final VoidCallback? onImport;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.page, AppSpacing.sm, AppSpacing.page, AppSpacing.md),
        child: Row(
          children: <Widget>[
            Expanded(
              child: AppButton(
                label: 'Start over',
                variant: AppButtonVariant.secondary,
                size: AppButtonSize.large,
                expand: true,
                onPressed: onReset,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              flex: 2,
              child: AppButton(
                label: 'Import $count',
                icon: Icons.download_rounded,
                size: AppButtonSize.large,
                expand: true,
                busy: importing != null,
                busyLabel: importing != null && importing!.total > 0
                    ? 'Saving ${importing!.done} of ${importing!.total}…'
                    : 'Saving…',
                onPressed: blocked ? null : onImport,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultView extends StatelessWidget {
  const _ResultView({required this.result, required this.provider, required this.currency});

  final CardImportOutcome result;
  final CardImportProvider provider;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<String> lines = importCountLines(result.counts);
    final bool failed = result.failed.isNotEmpty;
    return ListView(
      padding: const EdgeInsets.fromLTRB(AppSpacing.page, AppSpacing.md, AppSpacing.page, AppSpacing.xxxl),
      children: <Widget>[
        SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  IconWell(
                    icon: failed ? Icons.warning_amber_rounded : Icons.check_circle_outline_rounded,
                    tone: failed ? ToneColors.warning(context) : ToneColors.income(context),
                    size: 40,
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(lines.isEmpty ? 'Nothing was added' : 'Added to the card', style: theme.textTheme.titleMedium),
                        Text(provider.cycle?.label ?? '', style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                ],
              ),
              if (lines.isNotEmpty) ...<Widget>[
                const SizedBox(height: AppSpacing.md),
                for (final String line in lines)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                    child: Text('• $line', style: theme.textTheme.bodySmall),
                  ),
              ],
              if (result.skipped > 0) ...<Widget>[
                const SizedBox(height: AppSpacing.sm),
                Text('${result.skipped} left out: duplicates, unselected rows, or rows added to the card meanwhile.',
                    style: theme.textTheme.bodySmall),
              ],
              if (failed) ...<Widget>[
                const SizedBox(height: AppSpacing.sm),
                AppNotice(
                  icon: Icons.error_outline_rounded,
                  tone: theme.colorScheme.error,
                  message: '${result.failed.length} could not be saved: ${result.failed.first}'
                      '${result.notAttempted > 0 ? ' ${result.notAttempted} more were not attempted.' : ''}',
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: <Widget>[
            AppButton(
              label: 'Open the card',
              icon: Icons.credit_card_rounded,
              onPressed: () => Navigator.of(context).pop(true),
            ),
            AppButton(
              label: 'Import another statement',
              variant: AppButtonVariant.tonal,
              onPressed: provider.reset,
            ),
          ],
        ),
      ],
    );
  }
}
