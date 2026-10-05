import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/utils/date_utils.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/validators.dart';
import '../../models/bank_account.dart';
import '../../models/income.dart';
import '../../models/tag.dart';
import '../../providers/auth_provider.dart';
import '../../providers/bank_account_provider.dart';
import '../../providers/income_provider.dart';
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

/// Create or edit an income entry.
///
/// Mirrors the expense form field for field — same amount treatment, same
/// chips, same pinned save bar — so the two never feel like different apps.
/// Fewer fields, because the `income` table stores only amount, source, date
/// and description.
class IncomeFormScreen extends StatefulWidget {
  const IncomeFormScreen({super.key, this.income});

  final Income? income;

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

  @override
  void initState() {
    super.initState();
    final Income? existing = widget.income;
    _bankAccountId = existing?.bankAccountId;
    _amount = TextEditingController(
      text: existing == null ? '' : _trim(existing.amount),
    );
    _source = TextEditingController(text: existing?.source ?? '');
    _description = TextEditingController(text: existing?.description ?? '');
    _date = existing?.incomeDate ?? AppDateUtils.today();
    _tagsOffered = context.read<IncomeProvider>().tagsAvailable;
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadTags());
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

  static String _trim(double value) {
    final String text = value.toStringAsFixed(2);
    return text.endsWith('.00') ? text.substring(0, text.length - 3) : text;
  }

  @override
  void dispose() {
    _amount.dispose();
    _source.dispose();
    _description.dispose();
    _tagDraft.dispose();
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
        label: widget.isEditing ? 'Save changes' : 'Add income',
        busy: _saving,
        onPressed: _save,
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

            if (_error != null) ...<Widget>[
              const SizedBox(height: AppSpacing.lg),
              InlineError(message: _error!),
            ],
          ],
        ),
      ),
    );
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
