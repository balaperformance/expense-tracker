import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/utils/date_utils.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/validators.dart';
import '../../models/bank_account.dart';
import '../../models/expense.dart';
import '../../models/expense_category.dart';
import '../../models/expense_prefill.dart';
import '../../models/payment_method.dart';
import '../../providers/auth_provider.dart';
import '../../providers/bank_account_provider.dart';
import '../../providers/category_provider.dart';
import '../../providers/expense_provider.dart';
import '../../providers/payment_method_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/schema_capabilities.dart';
import '../../widgets/category_avatar.dart';
import '../../widgets/common/app_feedback.dart';
import '../../widgets/common/app_fields.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/money_text.dart';
import '../../widgets/common/state_views.dart';
import '../../widgets/common/surface_card.dart';
import 'paste_sms_screen.dart';
import 'receipt_scan_flow.dart';

/// Create or edit an expense.
///
/// Optimised for speed of entry. The amount is autofocused and display-sized;
/// category, date and payment source are all one tap from chips rather than
/// dropdowns; and the save button is pinned to the bottom so it never has to
/// be scrolled to. Everything optional sits below, in one group, out of the
/// way of the three fields that matter.
///
/// Pops `true` when something was written, so the caller knows to invalidate
/// its cached aggregates.
class ExpenseFormScreen extends StatefulWidget {
  const ExpenseFormScreen({super.key, this.expense, this.prefill});

  final Expense? expense;

  /// Values to open with, from a receipt scan. Applied only when creating —
  /// an edit always starts from the stored expense.
  final ExpensePrefill? prefill;

  bool get isEditing => expense != null;

  @override
  State<ExpenseFormScreen> createState() => _ExpenseFormScreenState();
}

class _ExpenseFormScreenState extends State<ExpenseFormScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _amount;
  late final TextEditingController _merchant;
  late final TextEditingController _description;
  late final TextEditingController _notes;

  String? _categoryId;
  String? _paymentMethodId;

  /// Null means Cash. Any other value is a bank account id, and saving will
  /// record a debit against it.
  String? _bankAccountId;

  late DateTime _date;
  bool _saving = false;
  String? _error;

  /// Set once the user has tried to save, so the category requirement is
  /// shown then rather than scolding them before they have filled anything in.
  bool _submitted = false;

  /// Set once a scan has filled the form, so the screen can say where the
  /// values came from instead of the user wondering why fields are populated.
  bool _fromScan = false;

  @override
  void initState() {
    super.initState();
    final Expense? existing = widget.expense;
    // An edit is always seeded from the stored row; a prefill only ever
    // applies to a new entry.
    final ExpensePrefill? prefill =
        existing == null ? widget.prefill : null;

    _amount = TextEditingController(
      text: existing != null
          ? _trimTrailingZeros(existing.amount)
          : (prefill?.amount == null
              ? ''
              : _trimTrailingZeros(prefill!.amount!)),
    );
    _merchant = TextEditingController(
      text: existing?.merchant ?? prefill?.merchant ?? '',
    );
    _description = TextEditingController(
      text: existing?.description ?? prefill?.description ?? '',
    );
    _notes = TextEditingController(text: existing?.notes ?? prefill?.notes ?? '');
    _categoryId = existing?.categoryId ?? prefill?.categoryId;
    _paymentMethodId = existing?.paymentMethodId ?? prefill?.paymentMethodId;
    _bankAccountId = existing?.bankAccountId;
    _date = existing?.expenseDate ?? prefill?.date ?? AppDateUtils.today();
    _fromScan = prefill?.source == ExpensePrefillSource.receiptScan;
  }

  /// Runs the scan flow and folds the result into the form.
  ///
  /// The values land in the live controllers rather than rebuilding the
  /// screen, so anything the user had already typed and the scan did not read
  /// — the payment source, for instance — survives.
  Future<void> _scanReceipt() async {
    final ExpensePrefill? scanned = await startReceiptScan(context);
    if (scanned == null || !mounted) return;

    setState(() {
      if (scanned.amount != null) {
        _amount.text = _trimTrailingZeros(scanned.amount!);
      }
      if (scanned.merchant != null) _merchant.text = scanned.merchant!;
      if (scanned.description != null) {
        _description.text = scanned.description!;
      }
      if (scanned.date != null) _date = scanned.date!;
      if (scanned.categoryId != null) _categoryId = scanned.categoryId;
      if (scanned.paymentMethodId != null) {
        _paymentMethodId = scanned.paymentMethodId;
      }
      _fromScan = true;
      _submitted = false;
      _error = null;
    });
  }

  /// Runs the bank-SMS flow, which reviews and saves on its own.
  ///
  /// Unlike a receipt scan, this does not fold values back into the form: the
  /// SMS flow has its own review step and creates the expense there, so by
  /// the time it returns true the work this form was opened to do is done.
  /// Closing is what the user expects after seeing "Expense added".
  Future<void> _importSms() async {
    final bool saved = await startSmsImport(context);
    if (saved && mounted) Navigator.of(context).pop(true);
  }

  static String _trimTrailingZeros(double value) {
    final String text = value.toStringAsFixed(2);
    return text.endsWith('.00') ? text.substring(0, text.length - 3) : text;
  }

  @override
  void dispose() {
    _amount.dispose();
    _merchant.dispose();
    _description.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final SettingsProvider settings = context.watch<SettingsProvider>();
    final CategoryProvider categories = context.watch<CategoryProvider>();
    final PaymentMethodProvider payments =
        context.watch<PaymentMethodProvider>();
    final BankAccountProvider accounts = context.watch<BankAccountProvider>();

    final bool categoryMissing = _submitted && _categoryId == null;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isEditing ? 'Edit expense' : 'Add expense'),
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
      // Pinned so the primary action is always visible and thumb-reachable,
      // however long the form gets.
      bottomNavigationBar: _SaveBar(
        label: widget.isEditing ? 'Save changes' : 'Add expense',
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
            // ---------------------------------------------------------
            // Scan a receipt — above the amount, because it fills it in
            // ---------------------------------------------------------
            if (!widget.isEditing) ...<Widget>[
              ScanReceiptCard(onTap: _scanReceipt, busy: _saving),
              const SizedBox(height: AppSpacing.sm),
              PasteSmsCard(onTap: _importSms, busy: _saving),
              const SizedBox(height: AppSpacing.lg),
            ],

            if (_fromScan) ...<Widget>[
              AppNotice(
                icon: Icons.auto_awesome_outlined,
                tone: theme.colorScheme.primary,
                message: 'Filled in from your receipt. Change anything that '
                    'is not right before saving.',
              ),
              const SizedBox(height: AppSpacing.lg),
            ],

            // ---------------------------------------------------------
            // Amount — the reason the screen exists
            // ---------------------------------------------------------
            AmountField(
              controller: _amount,
              symbol: settings.currencySymbol,
              enabled: !_saving,
              autofocus: !widget.isEditing,
              tone: ToneColors.expense(context),
            ),
            const SizedBox(height: AppSpacing.xl),

            // ---------------------------------------------------------
            // Category
            // ---------------------------------------------------------
            FieldLabel(
              'Category',
              isRequired: true,
              hint: categoryMissing ? 'Pick one' : null,
            ),
            _CategoryPicker(
              categories: categories.categories,
              selectedId: _categoryId,
              enabled: !_saving,
              hasError: categoryMissing,
              onSelected: (String id) => setState(() {
                _categoryId = id;
                _submitted = false;
              }),
            ),
            const SizedBox(height: AppSpacing.lg),

            // ---------------------------------------------------------
            // Date
            // ---------------------------------------------------------
            const FieldLabel('Date', isRequired: true),
            DateField(
              date: _date,
              enabled: !_saving,
              onChanged: (DateTime value) => setState(() => _date = value),
            ),
            const SizedBox(height: AppSpacing.lg),

            // ---------------------------------------------------------
            // Payment source — decides whether a bank balance moves
            // ---------------------------------------------------------
            if (SchemaCapabilities.phase2Ready) ...<Widget>[
              FieldLabel(
                'Paid from',
                isRequired: true,
                hint: _bankAccountId == null ? 'No balance affected' : null,
              ),
              _SourcePicker(
                accounts: accounts.accounts,
                selectedAccountId: _bankAccountId,
                enabled: !_saving,
                onSelected: (String? id) =>
                    setState(() => _bankAccountId = id),
              ),
              const SizedBox(height: AppSpacing.lg),
            ],

            // ---------------------------------------------------------
            // Optional detail, grouped and visually quieter
            // ---------------------------------------------------------
            const FieldLabel('Details', hint: 'Optional'),
            SurfaceCard(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                children: <Widget>[
                  if (SchemaCapabilities.merchant) ...<Widget>[
                    TextFormField(
                      controller: _merchant,
                      enabled: !_saving,
                      textCapitalization: TextCapitalization.words,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        hintText: 'Merchant',
                        prefixIcon: Icon(
                          Icons.storefront_outlined,
                          size: AppSpacing.iconMd,
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                  TextFormField(
                    controller: _description,
                    enabled: !_saving,
                    textCapitalization: TextCapitalization.sentences,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      hintText: 'Description',
                      prefixIcon: Icon(
                        Icons.short_text_rounded,
                        size: AppSpacing.iconMd,
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  TextFormField(
                    controller: _notes,
                    enabled: !_saving,
                    maxLines: 2,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      hintText: 'Notes',
                      alignLabelWithHint: true,
                      prefixIcon: Icon(
                        Icons.notes_rounded,
                        size: AppSpacing.iconMd,
                      ),
                    ),
                  ),
                  if (payments.methods.isNotEmpty) ...<Widget>[
                    const SizedBox(height: AppSpacing.md),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Payment method',
                        style: theme.textTheme.labelMedium,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    _PaymentPicker(
                      methods: payments.methods,
                      selectedId: _paymentMethodId,
                      enabled: !_saving,
                      onSelected: (String? id) =>
                          setState(() => _paymentMethodId = id),
                    ),
                  ],
                ],
              ),
            ),

            if (!SchemaCapabilities.merchant &&
                SchemaCapabilities.resolved) ...<Widget>[
              const SizedBox(height: AppSpacing.md),
              const AppNotice(
                message: 'Merchant is hidden because the expenses table has '
                    'no "merchant" column yet. Run the migration from the '
                    'setup notes to enable it.',
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

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _error = null;
      _submitted = true;
    });

    final bool formValid = _formKey.currentState!.validate();

    if (_categoryId == null) {
      setState(() => _error = 'Choose a category for this expense.');
      return;
    }
    if (!formValid) return;

    final String? userId = context.read<AuthProvider>().userId;
    if (userId == null) {
      setState(() => _error = 'You are signed out. Please sign in again.');
      return;
    }

    setState(() => _saving = true);

    final ExpenseProvider provider = context.read<ExpenseProvider>();
    final Expense draft = Expense(
      id: widget.expense?.id ?? '',
      userId: userId,
      amount: Validators.parseAmount(_amount.text)!,
      expenseDate: _date,
      categoryId: _categoryId,
      paymentMethodId: _paymentMethodId,
      bankAccountId: _bankAccountId,
      merchant: _merchant.text,
      description: _description.text,
      notes: _notes.text,
    );

    final bool ok = widget.isEditing
        ? await provider.update(draft)
        : await provider.create(draft);

    if (!mounted) return;

    if (ok) {
      AppFeedback.success(
        context,
        widget.isEditing ? 'Expense updated' : 'Expense added',
      );
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _saving = false;
        _error = provider.errorMessage ?? 'Could not save the expense.';
      });
    }
  }

  Future<void> _confirmDelete() async {
    final Expense? existing = widget.expense;
    if (existing == null) return;

    final bool confirmed = await AppFeedback.confirm(
      context,
      title: 'Delete expense?',
      message: 'This removes '
          '${Formatters.currency(existing.amount, currencyCode: context.read<SettingsProvider>().currency)} '
          'from ${Formatters.dayMonthYear(existing.expenseDate)}. '
          'This cannot be undone.',
    );

    if (!confirmed || !mounted) return;

    setState(() => _saving = true);
    final ExpenseProvider provider = context.read<ExpenseProvider>();
    final bool ok = await provider.delete(existing);

    if (!mounted) return;

    if (ok) {
      AppFeedback.success(context, 'Expense deleted');
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _saving = false;
        _error = provider.errorMessage ?? 'Could not delete the expense.';
      });
    }
  }
}

/// Pinned primary action.
///
/// Sits on the scaffold's surface with a top hairline so it reads as a bar
/// rather than as a button floating over the content, and clears the gesture
/// inset itself.
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

class _CategoryPicker extends StatelessWidget {
  const _CategoryPicker({
    required this.categories,
    required this.selectedId,
    required this.onSelected,
    required this.enabled,
    required this.hasError,
  });

  final List<ExpenseCategory> categories;
  final String? selectedId;
  final ValueChanged<String> onSelected;
  final bool enabled;
  final bool hasError;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    if (categories.isEmpty) {
      return const AppNotice(
        message: 'No categories yet. Add one from Settings › Categories.',
      );
    }

    return Container(
      padding: hasError ? const EdgeInsets.all(AppSpacing.sm) : EdgeInsets.zero,
      decoration: hasError
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
              border: Border.all(color: theme.colorScheme.error),
            )
          : null,
      child: Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.sm,
        children: categories.map((ExpenseCategory category) {
          return AppChoiceChip(
            label: category.name,
            selected: category.id == selectedId,
            enabled: enabled,
            tone: AppColors.readableOn(
              AppColors.fromHex(category.color),
              theme.brightness,
            ),
            avatar: CategoryAvatar(
              icon: category.icon,
              color: category.color,
              size: 20,
            ),
            onSelected: () => onSelected(category.id),
          );
        }).toList(),
      ),
    );
  }
}

/// Payment source: Cash, or one of the user's bank accounts.
///
/// Cash is always first and is the default, because it is the only option
/// that leaves every bank balance untouched — the safe choice if the user
/// taps past this field.
class _SourcePicker extends StatelessWidget {
  const _SourcePicker({
    required this.accounts,
    required this.selectedAccountId,
    required this.onSelected,
    required this.enabled,
  });

  final List<BankAccount> accounts;

  /// Null means Cash.
  final String? selectedAccountId;

  final ValueChanged<String?> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (accounts.isEmpty) {
      return const AppNotice(
        message: 'Add a bank account to track expenses against a balance. '
            'Until then everything is recorded as cash.',
      );
    }

    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: <Widget>[
        AppChoiceChip(
          label: 'Cash',
          icon: Icons.payments_outlined,
          selected: selectedAccountId == null,
          enabled: enabled,
          onSelected: () => onSelected(null),
        ),
        ...accounts.map((BankAccount account) {
          return AppChoiceChip(
            label: account.nickname,
            icon: Icons.account_balance_outlined,
            selected: selectedAccountId == account.id,
            enabled: enabled,
            onSelected: () => onSelected(account.id),
          );
        }),
      ],
    );
  }
}

class _PaymentPicker extends StatelessWidget {
  const _PaymentPicker({
    required this.methods,
    required this.selectedId,
    required this.onSelected,
    required this.enabled,
  });

  final List<PaymentMethod> methods;
  final String? selectedId;
  final ValueChanged<String?> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: methods.map((PaymentMethod method) {
        final bool selected = method.id == selectedId;
        return AppChoiceChip(
          label: method.name,
          selected: selected,
          enabled: enabled,
          // Tapping the selected chip clears it, since payment method is
          // optional.
          onSelected: () => onSelected(selected ? null : method.id),
        );
      }).toList(),
    );
  }
}
