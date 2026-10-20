import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/utils/date_utils.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/validators.dart';
import '../../models/credit_card.dart';
import '../../models/emi_plan.dart';
import '../../models/expense_category.dart';
import '../../models/ledger_entry.dart';
import '../../providers/bank_account_provider.dart';
import '../../providers/card_import_provider.dart';
import '../../providers/category_provider.dart';
import '../../providers/settings_provider.dart';
import '../../widgets/category_avatar.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/app_fields.dart';
import '../../widgets/common/app_sheet.dart';
import '../../widgets/common/money_text.dart';
import '../../widgets/common/surface_card.dart';
import 'emi_plan_sheet.dart';

/// Edit one screenshot row before import. Nothing is saved from here — only
/// the review changes, through the engine's reducer.
class CardImportRowSheet extends StatefulWidget {
  const CardImportRowSheet({
    super.key,
    required this.provider,
    required this.itemId,
    required this.card,
  });

  final CardImportProvider provider;
  final String itemId;
  final CreditCard card;

  @override
  State<CardImportRowSheet> createState() => _CardImportRowSheetState();
}

class _CardImportRowSheetState extends State<CardImportRowSheet> {
  Map<String, Object?> get _item =>
      widget.provider.item(widget.itemId) ?? const <String, Object?>{};

  late final TextEditingController _title =
      TextEditingController(text: _item['title'] as String? ?? '');
  late final TextEditingController _amount =
      TextEditingController(text: Formatters.amountInput((_item['amount'] as num?)?.toDouble() ?? 0));
  late DateTime _date = AppDateUtils.parseDate(_item['date']! as String);
  late String _direction = _item['direction'] as String? ?? 'debit';
  late String _kind = _item['kind'] as String? ?? 'purchase';
  late String? _categoryId = _item['categoryId'] as String?;
  List<LedgerEntry>? _candidates;
  bool _submitted = false;

  static const List<String> _debitKinds = <String>[
    'purchase', 'fee', 'interest', 'emiPrincipal', 'emiInterest', 'emiTax',
  ];
  static const List<String> _creditKinds = <String>['payment', 'refund', 'cashback'];
  static const Map<String, String> _labels = <String, String>{
    'purchase': 'Purchase',
    'payment': 'Bill payment',
    'refund': 'Refund',
    'cashback': 'Cashback',
    'fee': 'Fee',
    'interest': 'Interest',
    'emiPrincipal': 'EMI principal',
    'emiInterest': 'EMI interest',
    'emiTax': 'GST on EMI',
  };

  @override
  void initState() {
    super.initState();
    if (_kind == 'payment') _loadCandidates();
  }

  Future<void> _loadCandidates() async {
    final List<LedgerEntry> found = await widget.provider.paymentCandidates(_item);
    if (mounted) setState(() => _candidates = found);
  }

  @override
  void dispose() {
    _title.dispose();
    _amount.dispose();
    super.dispose();
  }

  List<String> get _kinds => _direction == 'debit' ? _debitKinds : _creditKinds;
  String get _effectiveKind => _kinds.contains(_kind) ? _kind : _kinds.first;
  bool get _needsCategory => _effectiveKind == 'purchase' || _effectiveKind == 'emiPrincipal';
  double? get _value => Validators.parseAmount(_amount.text);

  /// A usable amount: a number above 0 and within what the app records.
  bool get _amountValid {
    final double? value = _value;
    return value != null && value > 0 && value <= Validators.maxAmount;
  }

  Future<void> _submit() async {
    setState(() => _submitted = true);
    final double? value = _value;
    if (value == null || !_amountValid || (_needsCategory && _categoryId == null)) return;
    final Map<String, Object?> edit = <String, Object?>{
      'title': _title.text,
      'amount': value,
      'date': AppDateUtils.toDateString(_date),
      'kind': _effectiveKind,
      'categoryId': _needsCategory ? _categoryId : null,
    };
    final NavigatorState navigator = Navigator.of(context);
    if (_direction != _item['direction']) {
      await widget.provider.changeDirection(widget.itemId, _direction, edit);
    } else {
      await widget.provider.edit(widget.itemId, edit);
    }
    if (mounted) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final CardImportProvider provider = context.watch<CardImportProvider>();
    final SettingsProvider settings = context.watch<SettingsProvider>();
    final Map<String, Object?> item = provider.item(widget.itemId) ?? _item;
    final Map<String, Object?> flags = provider.itemView(widget.itemId) ?? const <String, Object?>{};
    final List<ExpenseCategory> categories = context.watch<CategoryProvider>().categories;
    final Map<String, Object?>? duplicate = item['duplicate'] as Map<String, Object?>?;
    final bool possible = duplicate != null && (duplicate['type'] == 'nearby' || duplicate['type'] == 'possible');
    final String? decision = item['duplicateDecision'] as String?;
    final List<String> issues = ((item['issues'] as List<Object?>?) ?? const <Object?>[]).cast<String>();
    final bool credit = item['direction'] == 'credit';
    final String? amountError =
        _submitted && !_amountValid ? 'Enter an amount greater than 0.' : null;
    final String? categoryError = _submitted && _needsCategory && _categoryId == null ? 'Choose a category.' : null;
    final String? groupId = item['groupId'] as String?;
    final Map<String, Object?>? link = item['paymentLink'] as Map<String, Object?>?;
    final BankAccountProvider accounts = context.read<BankAccountProvider>();

    return AppSheet(
      title: 'Statement row',
      subtitle: 'Read as "${item['rawTitle']}" · ${item['dateText']} · ${credit ? '+' : ''}'
          '${Formatters.currency((item['amount'] as num?)?.toDouble() ?? 0, currencyCode: settings.currency)}',
      footer: AppButton.submit(label: 'Done', onPressed: _submit),
      children: <Widget>[
        if (duplicate != null) ...<Widget>[
          AppNotice(
            icon: Icons.content_copy_rounded,
            tone: ToneColors.warning(context),
            message: flags['duplicateText'] as String? ?? 'Possibly already on the card.',
          ),
          const SizedBox(height: AppSpacing.sm),
          if (possible)
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: <Widget>[
                AppButton(
                  label: 'Same — leave it out',
                  size: AppButtonSize.small,
                  variant: decision == 'duplicate' ? AppButtonVariant.primary : AppButtonVariant.secondary,
                  onPressed: () => provider.decideDuplicate(widget.itemId, 'duplicate'),
                ),
                AppButton(
                  label: 'Different — import it',
                  size: AppButtonSize.small,
                  variant: decision == 'notDuplicate' ? AppButtonVariant.primary : AppButtonVariant.secondary,
                  onPressed: () => provider.decideDuplicate(widget.itemId, 'notDuplicate'),
                ),
              ],
            )
          else
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: item['duplicateOverridden'] == true,
              onChanged: (bool v) => provider.overrideDuplicate(widget.itemId, v),
              title: Text('Import it anyway — it is a separate transaction', style: theme.textTheme.bodySmall),
            ),
          const SizedBox(height: AppSpacing.lg),
        ],
        if (issues.isNotEmpty) ...<Widget>[
          AppNotice(icon: Icons.warning_amber_rounded, tone: ToneColors.warning(context), message: issues.join(' · ')),
          const SizedBox(height: AppSpacing.lg),
        ],
        AmountField(
          controller: _amount,
          symbol: settings.currencySymbol,
          tone: _direction == 'credit' ? ToneColors.income(context) : ToneColors.expense(context),
        ),
        if (amountError != null) ...<Widget>[
          const SizedBox(height: AppSpacing.xs),
          Text(amountError, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.error)),
        ],
        const SizedBox(height: AppSpacing.lg),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<String>(
            segments: const <ButtonSegment<String>>[
              ButtonSegment<String>(value: 'debit', label: Text('Charge')),
              ButtonSegment<String>(value: 'credit', label: Text('Credit')),
            ],
            selected: <String>{_direction},
            showSelectedIcon: false,
            onSelectionChanged: (Set<String> v) => setState(() => _direction = v.first),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        const FieldLabel('What it is'),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: _kinds
              .map((String k) => AppChoiceChip(
                    label: _labels[k] ?? k,
                    selected: k == _effectiveKind,
                    onSelected: () => setState(() => _kind = k),
                  ))
              .toList(),
        ),
        const SizedBox(height: AppSpacing.lg),
        const FieldLabel('Description'),
        TextField(
          controller: _title,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'As on the statement'),
        ),
        const SizedBox(height: AppSpacing.lg),
        const FieldLabel('Date', isRequired: true),
        DateField(date: _date, onChanged: (DateTime v) => setState(() => _date = v)),
        if (_needsCategory) ...<Widget>[
          const SizedBox(height: AppSpacing.lg),
          FieldLabel('Category', isRequired: true, hint: categoryError),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: categories
                .map((ExpenseCategory c) => AppChoiceChip(
                      label: c.name,
                      selected: c.id == _categoryId,
                      avatar: CategoryAvatar(icon: c.icon, color: c.color, size: 22),
                      onSelected: () => setState(() => _categoryId = c.id == _categoryId ? null : c.id),
                    ))
                .toList(),
          ),
          if (_effectiveKind == 'emiPrincipal') ...<Widget>[
            const SizedBox(height: AppSpacing.xs),
            Text('Used only if the instalment is not part of a plan with its own category.',
                style: theme.textTheme.labelSmall),
          ],
        ],
        if (_effectiveKind == 'payment' && _direction == 'credit') ...<Widget>[
          const SizedBox(height: AppSpacing.lg),
          const FieldLabel('How the bill was paid', hint: 'A recorded bank debit is linked, never debited twice'),
          if (_candidates == null)
            const LinearProgressIndicator()
          else if (_candidates!.isEmpty)
            const AppNotice(
              message: 'No bank debit of this amount is recorded around this date. It is recorded on the card '
                  "alone; link it to the bank later from the account's statement.",
            )
          else
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: <Widget>[
                AppChoiceChip(
                  label: 'Record on the card',
                  selected: link == null || link['type'] == 'record',
                  onSelected: () => provider.setPaymentLink(widget.itemId, const <String, Object?>{'type': 'record'}),
                ),
                for (final LedgerEntry d in _candidates!)
                  AppChoiceChip(
                    label: '${d.title} · ${Formatters.dayMonth(d.txnDate)} · '
                        '${accounts.byId(d.accountId)?.nickname ?? 'account'}',
                    icon: Icons.account_balance_outlined,
                    selected: link?['type'] == 'entry' && link!['entryId'] == d.id,
                    onSelected: () => provider.setPaymentLink(
                      widget.itemId,
                      <String, Object?>{'type': 'entry', 'entryId': d.id, 'label': d.title},
                    ),
                  ),
              ],
            ),
        ],
        if (_effectiveKind.startsWith('emi')) ...<Widget>[
          const SizedBox(height: AppSpacing.lg),
          const FieldLabel('Instalment', hint: "One month's EMI, shown as one transaction"),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: <Widget>[
              AppChoiceChip(
                label: 'Not grouped',
                selected: groupId == null,
                onSelected: () => provider.regroupItem(widget.itemId, remove: true),
              ),
              for (final Map<String, Object?> g in provider.groups)
                AppChoiceChip(
                  label: _groupLabel(provider, g['id']! as String, settings.currency),
                  selected: g['id'] == groupId,
                  onSelected: () => provider.regroupItem(widget.itemId, groupId: g['id'] as String?),
                ),
              AppChoiceChip(
                label: 'New instalment',
                icon: Icons.add_rounded,
                selected: false,
                onSelected: () => provider.regroupItem(widget.itemId),
              ),
            ],
          ),
        ],
        if (item['detail'] != null) ...<Widget>[
          const SizedBox(height: AppSpacing.md),
          Text('The statement filed it under “${item['detail']}”.', style: theme.textTheme.labelSmall),
        ],
      ],
    );
  }
}

/// "20 Sep · ₹2,009 · Laptop" — a group, by its date, total and plan.
String _groupLabel(CardImportProvider provider, String groupId, String currency) {
  final Map<String, Object?> view = provider.groupView(groupId) ?? const <String, Object?>{};
  final String? date = view['date'] as String?;
  final double total = (view['total'] as num?)?.toDouble() ?? 0;
  final String? plan = view['needsPlan'] == true ? null : view['planLabel'] as String?;
  return <String>[
    if (date != null) Formatters.dayMonth(AppDateUtils.parseDate(date)),
    Formatters.currency(total, currencyCode: currency, compact: true),
    if (plan != null) plan,
  ].join(' · ');
}

/// One month's instalment: its components and the plan it belongs to. Pops
/// a row id when the user wants to open that row.
class EmiGroupSheet extends StatelessWidget {
  const EmiGroupSheet({
    super.key,
    required this.provider,
    required this.groupId,
    required this.card,
  });

  final CardImportProvider provider;
  final String groupId;
  final CreditCard card;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final CardImportProvider live = context.watch<CardImportProvider>();
    final String currency = context.watch<SettingsProvider>().currency;
    final Map<String, Object?>? group = live.group(groupId);
    if (group == null) {
      return const AppSheet(title: 'Monthly instalment', children: <Widget>[SizedBox(height: AppSpacing.lg)]);
    }
    final Map<String, Object?> view = live.groupView(groupId) ?? const <String, Object?>{};
    final List<Map<String, Object?>> members = live.membersOf(groupId);
    final double total = (view['total'] as num?)?.toDouble() ?? 0;
    final String? date = view['date'] as String?;
    final Map<String, Object?>? newPlan = group['newPlan'] as Map<String, Object?>?;
    final bool needsPlan = group['planId'] == null && newPlan == null;
    String money(double v) => Formatters.currency(v, currencyCode: currency, compact: true);

    return AppSheet(
      title: 'Monthly instalment',
      subtitle: '${date == null ? '' : '${Formatters.dayMonthYear(AppDateUtils.parseDate(date))} · '}'
          '${Formatters.currency(total, currencyCode: currency)} in all',
      footer: Row(
        children: <Widget>[
          AppButton(
            label: 'Ungroup',
            variant: AppButtonVariant.ghost,
            onPressed: () async {
              for (final Map<String, Object?> m in members) {
                await live.regroupItem(m['id']! as String, remove: true);
              }
              if (context.mounted) Navigator.of(context).pop();
            },
          ),
          const Spacer(),
          AppButton(label: 'Done', onPressed: () => Navigator.of(context).pop()),
        ],
      ),
      children: <Widget>[
        if (group['uncertain'] == true) ...<Widget>[
          AppNotice(
            icon: Icons.warning_amber_rounded,
            tone: ToneColors.warning(context),
            message: 'Several EMI rows were billed on the same day: check that these belong together. '
                'Move a row out from its own editor if not.',
          ),
          const SizedBox(height: AppSpacing.lg),
        ],
        FieldLabel('Which EMI', isRequired: true, hint: needsPlan ? 'Needed before importing' : null),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: <Widget>[
            for (final EmiPlan p in live.plans.where((EmiPlan p) => !p.isClosed))
              AppChoiceChip(
                label: p.label,
                icon: p.person != null ? Icons.handshake_outlined : Icons.credit_card_rounded,
                selected: group['planId'] == p.id,
                onSelected: () => live.setGroupPlan(groupId, planId: p.id),
              ),
            AppChoiceChip(
              label: newPlan == null
                  ? 'New EMI plan…'
                  : 'New: ${newPlan['title']}${newPlan['person'] != null ? ' · ${newPlan['person']}' : ''}',
              icon: Icons.add_rounded,
              selected: group['planId'] == null && newPlan != null,
              onSelected: () => _draftPlan(context, live, members, newPlan, total, date),
            ),
          ],
        ),
        if (newPlan != null) ...<Widget>[
          const SizedBox(height: AppSpacing.xs),
          Text('The plan is created when you import. Tap it to change it.', style: theme.textTheme.labelSmall),
        ],
        const SizedBox(height: AppSpacing.lg),
        const FieldLabel('Components', hint: "Each stays its own row; together they are this month's EMI"),
        CardList(
          dividerIndent: AppSpacing.md,
          children: members
              .map((Map<String, Object?> m) {
                final Map<String, Object?> flags = live.itemView(m['id']! as String) ?? const <String, Object?>{};
                return AppListRow(
                  dense: true,
                  title: m['title']! as String,
                  subtitle: '${flags['kindLabel'] ?? ''} · ${Formatters.dayMonth(AppDateUtils.parseDate(m['date']! as String))}'
                      '${flags['leftOut'] == true ? ' · left out as a duplicate' : ''}',
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      MoneyText((m['amount']! as num).toDouble(), currency: currency, style: theme.textTheme.titleSmall),
                      const SizedBox(width: AppSpacing.xs),
                      IconButton(
                        tooltip: 'Remove from the instalment',
                        icon: const Icon(Icons.remove_circle_outline_rounded, size: AppSpacing.iconMd),
                        onPressed: () => live.regroupItem(m['id']! as String, remove: true),
                      ),
                    ],
                  ),
                  onTap: () => Navigator.of(context).pop(m['id'] as String?),
                );
              })
              .toList(),
        ),
        const SizedBox(height: AppSpacing.md),
        Wrap(
          spacing: AppSpacing.xs,
          runSpacing: AppSpacing.xxs,
          children: <Widget>[
            if ((view['principal'] as num? ?? 0) != 0) AppBadge(label: 'Principal ${money((view['principal']! as num).toDouble())}'),
            if ((view['interest'] as num? ?? 0) != 0) AppBadge(label: 'Interest ${money((view['interest']! as num).toDouble())}'),
            if ((view['tax'] as num? ?? 0) != 0) AppBadge(label: 'GST ${money((view['tax']! as num).toDouble())}'),
          ],
        ),
      ],
    );
  }

  Future<void> _draftPlan(
    BuildContext context,
    CardImportProvider live,
    List<Map<String, Object?>> members,
    Map<String, Object?>? current,
    double total,
    String? date,
  ) async {
    String? categoryId;
    for (final Map<String, Object?> m in members) {
      if (m['kind'] == 'emiPrincipal') categoryId = m['categoryId'] as String?;
    }
    final EmiPlan initial = EmiPlan(
      id: '',
      userId: '',
      cardId: card.id,
      title: current?['title'] as String? ?? '',
      reference: current?['reference'] as String?,
      person: current?['person'] as String?,
      includeCharges: current?['includeCharges'] != false,
      purchaseAmount: (current?['purchaseAmount'] as num?)?.toDouble(),
      monthlyAmount: total > 0 ? total : null,
      tenureMonths: (current?['tenureMonths'] as num?)?.toInt(),
      startDate: date == null ? null : AppDateUtils.parseDate(date),
      categoryId: categoryId,
    );
    final EmiPlan? draft = await showAppSheet<EmiPlan>(
      context: context,
      builder: (_) => EmiPlanSheet(card: card, initial: initial, draft: true),
    );
    if (draft == null) return;
    await live.setGroupPlan(groupId, newPlan: <String, Object?>{
      'title': draft.title,
      'reference': draft.reference,
      'person': draft.person,
      'includeCharges': draft.includeCharges,
      'purchaseAmount': draft.purchaseAmount,
      'monthlyAmount': draft.monthlyAmount,
      'tenureMonths': draft.tenureMonths,
      'startDate': draft.startDate == null ? null : AppDateUtils.toDateString(draft.startDate!),
      'categoryId': draft.categoryId,
    });
  }
}
