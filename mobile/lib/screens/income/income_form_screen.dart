import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/utils/date_utils.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/validators.dart';
import '../../models/bank_account.dart';
import '../../models/emi_reimbursement.dart';
import '../../models/income.dart';
import '../../models/tag.dart';
import '../../providers/auth_provider.dart';
import '../../providers/bank_account_provider.dart';
import '../../providers/credit_card_provider.dart';
import '../../providers/dashboard_provider.dart';
import '../../providers/income_provider.dart';
import '../../providers/receivable_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/schema_capabilities.dart';
import '../../widgets/account_choice_chips.dart';
import '../../widgets/common/app_feedback.dart';
import '../../widgets/common/app_fields.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/money_text.dart';
import '../../widgets/common/state_views.dart';
import '../../widgets/common/surface_card.dart';
import '../../widgets/tag_field.dart';
import 'emi_reimbursement_fields.dart';

/// Create or edit an income entry.
///
/// Mirrors the expense form field for field — same amount treatment, same
/// chips, same pinned save bar — so the two never feel like different apps.
/// Fewer fields, because the `income` table stores only amount, source, date
/// and description.
class IncomeFormScreen extends StatefulWidget {
  const IncomeFormScreen({super.key, this.income, this.emiReimbursement = false});

  final Income? income;

  /// Opens on "Card EMI reimbursement" rather than income.
  final bool emiReimbursement;

  bool get isEditing => income != null;

  @override
  State<IncomeFormScreen> createState() => _IncomeFormScreenState();
}

class _IncomeFormScreenState extends State<IncomeFormScreen> {
  static const List<String> _commonSources = <String>[
    'Salary',
    'Freelance',
    'Business',
    'Interest',
    'Dividends',
    'Refund',
    'Gift',
  ];

  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _amount;
  late final TextEditingController _source;
  late final TextEditingController _description;

  /// Account this income lands in. Null means it is recorded as income but
  /// not credited to any tracked account.
  String? _bankAccountId;

  late DateTime _date;
  bool _saving = false;
  String? _error;

  /// The entry's tags (migration 006) and the one still being typed.
  List<String> _tags = <String>[];
  final TextEditingController _tagDraft = TextEditingController();

  /// The user's tags, offered as suggestions.
  List<Tag> _knownTags = const <Tag>[];

  /// Tags can be read and saved.
  late final bool _tagsOffered;

  /// An edit's tags have been read. Until then they are neither shown nor
  /// changed, so a failed read can never clear them.
  bool _tagsRead = false;

  /// A new entry shows tags at once (the suggestions follow); an edit once
  /// its own tags are known.
  bool get _showTags => _tagsOffered && (!widget.isEditing || _tagsRead);

  // "Credit card EMI reimbursement (paid by someone else)": money in that pays
  // back an EMI someone else owes — a repayment of the EMI's claim, never income.
  late final bool _offerEmi =
      SchemaCapabilities.emi && SchemaCapabilities.bankAccounts;
  late bool _emiMode = _offerEmi && widget.emiReimbursement;
  String? _emiCardId;
  String? _planId;
  String? _emiAccountId;
  EmiReimbursementProblem? _emiProblem;
  final TextEditingController _person = TextEditingController();

  @override
  void initState() {
    super.initState();
    final Income? existing = widget.income;
    _bankAccountId = existing?.bankAccountId;
    _amount = TextEditingController(
      text: existing == null ? '' : Formatters.amountInput(existing.amount),
    );
    _source = TextEditingController(text: existing?.source ?? '');
    _description = TextEditingController(text: existing?.description ?? '');
    _date = existing?.incomeDate ?? AppDateUtils.today();
    _emiAccountId = existing?.bankAccountId;
    _tagsOffered = context.read<IncomeProvider>().tagsAvailable;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadTags();
      _loadEmi();
    });
  }

  /// The plans, card movements and claims the EMI choices are read from.
  Future<void> _loadEmi() async {
    if (!mounted || !_offerEmi) return;
    final String? userId = context.read<AuthProvider>().userId;
    if (userId == null) return;
    await Future.wait(<Future<void>>[
      context.read<CreditCardProvider>().load(userId: userId),
      context.read<ReceivableProvider>().load(userId: userId),
      context.read<BankAccountProvider>().load(userId: userId),
    ]);
    if (mounted) setState(() {});
  }

  /// The user's tags and, for an edit, the entry's own.
  Future<void> _loadTags() async {
    if (!mounted || !_tagsOffered) return;
    final IncomeProvider provider = context.read<IncomeProvider>();
    final String? userId = context.read<AuthProvider>().userId;
    if (userId == null) return;
    final ({List<Tag> known, List<String> names})? read =
        await provider.tagsFor(userId: userId, incomeId: widget.income?.id);
    if (!mounted || read == null) return;
    setState(() {
      _knownTags = read.known;
      // A new entry keeps whatever was added while the list loaded.
      if (widget.isEditing) _tags = List<String>.of(read.names);
      _tagsRead = true;
    });
  }

  @override
  void dispose() {
    _amount.dispose();
    _source.dispose();
    _description.dispose();
    _tagDraft.dispose();
    _person.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final SettingsProvider settings = context.watch<SettingsProvider>();
    final bool canLinkAccount = SchemaCapabilities.bankAccounts &&
        SchemaCapabilities.incomeBankLink;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isEditing ? 'Edit income' : 'Add income'),
        actions: <Widget>[
          if (widget.isEditing)
            IconButton(
              tooltip: 'Delete',
              onPressed: _saving ? null : _confirmDelete,
              icon: const Icon(Icons.delete_outline_rounded),
            ),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      bottomNavigationBar: _SaveBar(
        label: _emiMode
            ? (widget.isEditing ? 'Save as reimbursement' : 'Record reimbursement')
            : (widget.isEditing ? 'Save changes' : 'Add income'),
        busy: _saving,
        onPressed: _emiMode ? _saveEmi : _save,
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.page,
            AppSpacing.md,
            AppSpacing.page,
            AppSpacing.xl,
          ),
          children: <Widget>[
            AmountField(
              controller: _amount,
              symbol: settings.currencySymbol,
              enabled: !_saving,
              autofocus: !widget.isEditing,
              tone: ToneColors.income(context),
            ),
            const SizedBox(height: AppSpacing.xl),

            if (_offerEmi) ...<Widget>[
              const FieldLabel('Record as'),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<bool>(
                  segments: const <ButtonSegment<bool>>[
                    ButtonSegment<bool>(value: false, label: Text('Income')),
                    ButtonSegment<bool>(
                      value: true,
                      label: Text('Card EMI reimbursement'),
                    ),
                  ],
                  selected: <bool>{_emiMode},
                  showSelectedIcon: false,
                  onSelectionChanged: _saving
                      ? null
                      : (Set<bool> v) => setState(() {
                            _emiMode = v.first;
                            _error = null;
                            _emiProblem = null;
                          }),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
            ],

            if (_emiMode) ..._emiFields(context, settings) else ...<Widget>[
            const FieldLabel('Source'),
            TextFormField(
              controller: _source,
              enabled: !_saving,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                hintText: 'Salary, freelance, interest…',
                prefixIcon: Icon(
                  Icons.work_outline_rounded,
                  size: AppSpacing.iconMd,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _source,
              builder: (BuildContext context, TextEditingValue value, _) {
                return Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: _commonSources.map((String source) {
                    return AppChoiceChip(
                      label: source,
                      selected:
                          value.text.trim().toLowerCase() ==
                              source.toLowerCase(),
                      enabled: !_saving,
                      onSelected: () => _source.text = source,
                    );
                  }).toList(),
                );
              },
            ),
            const SizedBox(height: AppSpacing.lg),

            const FieldLabel('Date', isRequired: true),
            DateField(
              date: _date,
              enabled: !_saving,
              onChanged: (DateTime value) => setState(() => _date = value),
            ),
            const SizedBox(height: AppSpacing.lg),

            if (canLinkAccount) ...<Widget>[
              FieldLabel(
                'Deposit into',
                hint: _bankAccountId == null ? 'No balance affected' : null,
              ),
              _AccountPicker(
                accounts: context.watch<BankAccountProvider>().accounts,
                selectedId: _bankAccountId,
                enabled: !_saving,
                onSelected: (String? id) =>
                    setState(() => _bankAccountId = id),
              ),
              const SizedBox(height: AppSpacing.lg),
            ],

            const FieldLabel('Details', hint: 'Optional'),
            SurfaceCard(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                children: <Widget>[
                  TextFormField(
                    controller: _description,
                    enabled: !_saving,
                    maxLines: 2,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      hintText: 'Description',
                      alignLabelWithHint: true,
                      prefixIcon: Icon(
                        Icons.short_text_rounded,
                        size: AppSpacing.iconMd,
                      ),
                    ),
                  ),
                  if (_showTags) ...<Widget>[
                    const SizedBox(height: AppSpacing.sm),
                    TagField(
                      tags: _tags,
                      draft: _tagDraft,
                      known: _knownTags,
                      enabled: !_saving,
                      onChanged: (List<String> next) =>
                          setState(() => _tags = next),
                    ),
                  ],
                ],
              ),
            ),

            ],

            if (_error != null) ...<Widget>[
              const SizedBox(height: AppSpacing.lg),
              InlineError(message: _error!),
            ],
          ],
        ),
      ),
    );
  }

  List<EmiReimbursementOption> _emiOptions() {
    final CreditCardProvider cards = context.watch<CreditCardProvider>();
    return emiReimbursementOptions(
      plans: cards.allPlans,
      claims: context.watch<ReceivableProvider>().claims,
      cards: cards.cards,
      entries: cards.isReady ? cards.allEntries : null,
      keepPlanId: _planId,
    );
  }

  EmiReimbursementOption? _optionFor(List<EmiReimbursementOption> options) {
    for (final EmiReimbursementOption o in options) {
      if (o.plan.id == _planId) return o;
    }
    return null;
  }

  List<Widget> _emiFields(BuildContext context, SettingsProvider settings) {
    final List<EmiReimbursementOption> options = _emiOptions();
    return <Widget>[
      const FieldLabel('Date', isRequired: true),
      DateField(
        date: _date,
        enabled: !_saving,
        onChanged: (DateTime value) => setState(() => _date = value),
      ),
      const SizedBox(height: AppSpacing.lg),
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: _amount,
        builder: (BuildContext context, TextEditingValue value, _) =>
            EmiReimbursementFields(
          options: options,
          cards: context.watch<CreditCardProvider>().cards,
          cardId: _emiCardId,
          onCard: (String? id) => setState(() => _emiCardId = id),
          planId: _planId,
          onPlan: (String id) => setState(() {
            _planId = id;
            _emiProblem = null;
            _error = null;
          }),
          person: _person,
          people: context.watch<ReceivableProvider>().people,
          accounts: context.watch<BankAccountProvider>().accounts,
          accountId: _emiAccountId,
          onAccount: (String id) => setState(() => _emiAccountId = id),
          amount: Validators.parseAmount(value.text),
          onUseAmount: (double amount) => _amount.text = Formatters.amountInput(amount),
          note: _description,
          problem: _emiProblem,
          currency: settings.currency,
          enabled: !_saving,
        ),
      ),
    ];
  }

  Future<void> _saveEmi() async {
    FocusScope.of(context).unfocus();
    setState(() => _error = null);
    // The amount field's own check first (required, a number, within the
    // limit), with its message under the field — as in income mode.
    if (!_formKey.currentState!.validate()) return;
    final String currency = context.read<SettingsProvider>().currency;
    final CreditCardProvider cards = context.read<CreditCardProvider>();
    final EmiReimbursementOption? option = _optionFor(emiReimbursementOptions(
      plans: cards.allPlans,
      claims: context.read<ReceivableProvider>().claims,
      cards: cards.cards,
      entries: cards.isReady ? cards.allEntries : null,
      keepPlanId: _planId,
    ));
    final double? amount = Validators.parseAmount(_amount.text);
    final EmiReimbursementProblem? problem = emiReimbursementProblem(
      option: option,
      person: _person.text,
      accountId: _emiAccountId,
      amount: amount,
    );
    if (problem != null) {
      setState(() {
        _emiProblem = problem;
        _error = emiReimbursementProblemMessage(problem, option, emiMoney(currency));
      });
      return;
    }
    setState(() => _saving = true);
    final Income? existing = widget.income;
    final ({bool ok, String? warning}) result = await cards.recordEmiReimbursement(
      plan: option!.plan,
      person: _person.text,
      accountId: _emiAccountId!,
      amount: amount!,
      date: _date,
      left: option.left,
      allowance: option.allowance,
      note: _description.text,
      fromIncome: existing == null
          ? null
          : (id: existing.id, bankAccountId: existing.bankAccountId),
    );
    if (!mounted) return;
    if (!result.ok) {
      setState(() {
        _saving = false;
        _error = cards.errorMessage ?? 'Could not record the reimbursement.';
      });
      return;
    }
    // What a repayment moves: the balance it landed in, what is owed, the
    // dashboard — and the income list when an income was replaced.
    final String? userId = context.read<AuthProvider>().userId;
    final BankAccountProvider accounts = context.read<BankAccountProvider>();
    context.read<ReceivableProvider>().invalidate();
    context.read<DashboardProvider?>()?.invalidate();
    if (existing != null) unawaited(context.read<IncomeProvider>().refresh());
    if (userId != null) {
      accounts.invalidate();
      unawaited(accounts.load(userId: userId, force: true));
    }
    AppFeedback.success(
      context,
      existing != null
          ? 'Recorded as an EMI reimbursement — no longer income'
          : 'EMI reimbursement recorded',
    );
    if (result.warning != null) AppFeedback.error(context, result.warning!);
    Navigator.of(context).pop(true);
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    setState(() => _error = null);
    if (!_formKey.currentState!.validate()) return;

    final String? userId = context.read<AuthProvider>().userId;
    if (userId == null) {
      setState(() => _error = 'You are signed out. Please sign in again.');
      return;
    }

    setState(() => _saving = true);

    final IncomeProvider provider = context.read<IncomeProvider>();
    final Income draft = Income(
      id: widget.income?.id ?? '',
      userId: userId,
      amount: Validators.parseAmount(_amount.text)!,
      incomeDate: _date,
      source: _source.text,
      description: _description.text,
      bankAccountId: _bankAccountId,
    );

    final bool ok = await provider.save(
      draft,
      // A tag typed but not confirmed counts too. Left alone when the tags
      // are unavailable.
      tags: _showTags
          ? TagField.withDraft(_tags, _tagDraft.text, _knownTags)
          : null,
    );

    if (!mounted) return;

    if (ok) {
      final String? warning = provider.saveWarning;
      if (warning != null) {
        AppFeedback.error(context, warning);
      } else {
        AppFeedback.success(
          context,
          widget.isEditing ? 'Income updated' : 'Income added',
        );
      }
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _saving = false;
        _error = provider.errorMessage ?? 'Could not save the income.';
      });
    }
  }

  Future<void> _confirmDelete() async {
    final Income? existing = widget.income;
    if (existing == null) return;

    final bool confirmed = await AppFeedback.confirm(
      context,
      title: 'Delete income?',
      message: 'This removes '
          '${Formatters.currency(existing.amount, currencyCode: context.read<SettingsProvider>().currency)} '
          'from ${Formatters.dayMonthYear(existing.incomeDate)}. '
          'This cannot be undone.',
    );

    if (!confirmed || !mounted) return;

    setState(() => _saving = true);
    final IncomeProvider provider = context.read<IncomeProvider>();
    final bool ok = await provider.delete(existing);

    if (!mounted) return;

    if (ok) {
      AppFeedback.success(context, 'Income deleted');
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _saving = false;
        _error = provider.errorMessage ?? 'Could not delete the income.';
      });
    }
  }
}

class _SaveBar extends StatelessWidget {
  const _SaveBar({
    required this.label,
    required this.busy,
    required this.onPressed,
  });

  final String label;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

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
      child: AppButton.submit(
        label: label,
        busy: busy,
        busyLabel: 'Saving…',
        onPressed: busy ? null : onPressed,
      ),
    );
  }
}

/// Optional target account for an income entry.
///
/// "Not tracked" is offered explicitly so income can be recorded for
/// reporting without implying a bank movement.
class _AccountPicker extends StatelessWidget {
  const _AccountPicker({
    required this.accounts,
    required this.selectedId,
    required this.onSelected,
    required this.enabled,
  });

  final List<BankAccount> accounts;
  final String? selectedId;
  final ValueChanged<String?> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (accounts.isEmpty) {
      return const AppNotice(
        message: 'Add a bank account to credit income to a balance.',
      );
    }

    return AccountChoiceChips(
      accounts: accounts,
      selectedId: selectedId,
      enabled: enabled,
      noneLabel: 'Not tracked',
      onSelected: onSelected,
    );
  }
}
