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
import '../../models/frequent_expense.dart';
import '../../models/payment_method.dart';
import '../../models/receivable.dart';
import '../../models/tag.dart';
import '../../providers/auth_provider.dart';
import '../../providers/bank_account_provider.dart';
import '../../providers/category_provider.dart';
import '../../providers/credit_card_provider.dart';
import '../../providers/expense_provider.dart';
import '../../providers/payment_method_provider.dart';
import '../../providers/receivable_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/schema_capabilities.dart';
import '../../widgets/card_widgets.dart';
import '../../widgets/account_choice_chips.dart';
import '../../widgets/category_avatar.dart';
import '../../widgets/common/app_feedback.dart';
import '../../widgets/common/app_fields.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/money_text.dart';
import '../../widgets/common/state_views.dart';
import '../../widgets/common/surface_card.dart';
import '../../widgets/paid_for_field.dart';
import '../../widgets/tag_field.dart';
import 'paste_sms_screen.dart';
import 'quick_add_chips.dart';
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
  const ExpenseFormScreen({
    super.key,
    this.expense,
    this.prefill,
    this.initialCardId,
  });

  final Expense? expense;

  /// Opens a new expense already paid with this card ("Add purchase" on a
  /// card's statement).
  final String? initialCardId;

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

  /// The user has picked where it was paid from, or is editing a saved
  /// expense. Until then a new expense comes out of the cash balance when the
  /// user keeps one — and the accounts may load after the form opens, so the
  /// default follows them rather than being fixed once.
  late bool _accountChosen;

  String? _sourceAccountId(List<BankAccount> accounts) =>
      _accountChosen ? _bankAccountId : BankAccount.cashOf(accounts)?.id;

  /// Paid with a credit card instead of cash or an account. A card purchase
  /// raises the card's outstanding and never touches a bank balance.
  late bool _byCard;
  String? _creditCardId;

  late DateTime _date;
  bool _saving = false;
  String? _error;

  /// Set once the user has tried to save, so the category requirement is
  /// shown then rather than scolding them before they have filled anything in.
  bool _submitted = false;

  /// Set once a scan has filled the form, so the screen can say where the
  /// values came from instead of the user wondering why fields are populated.
  bool _fromScan = false;

  /// What Quick add suggests from; null until read (or when it could not be).
  QuickAddHistory? _quickAddHistory;

  /// The Quick add chip last applied, for the selected chip and the notice.
  FrequentExpense? _quickAdded;

  /// Paid on someone else's behalf (migration 005): owed back, so not the
  /// user's own spending.
  bool _paidFor = false;
  final TextEditingController _paidForPerson = TextEditingController();

  /// The purchase's claim when it is already marked, for its progress.
  ClaimSummary? _claim;

  /// Whether the toggle shows the truth: always for a new expense; for an
  /// edit once its claim has been read. Until then — or if the read fails —
  /// the toggle is not offered and saving leaves the claim as it is.
  late _ClaimRead _claimRead;

  /// Everyone the user already has a claim with, offered as names.
  List<String> _people = const <String>[];

  /// The expense's tags (migration 006) and the one still being typed.
  List<String> _tags = <String>[];
  final TextEditingController _tagDraft = TextEditingController();

  /// The user's tags, offered as suggestions.
  List<Tag> _knownTags = const <Tag>[];

  /// An edit's tags have been read. Until then they are neither shown nor
  /// changed, so a failed read can never clear them.
  bool _tagsRead = false;

  /// Quick add is offered only on a blank new expense: a scan, a card's "Add
  /// purchase" or an edit already says what this is.
  bool get _offersQuickAdd =>
      !widget.isEditing &&
      widget.prefill == null &&
      widget.initialCardId == null;

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
    _accountChosen = existing != null;
    _creditCardId =
        existing != null ? existing.creditCardId : widget.initialCardId;
    _byCard = _creditCardId != null;
    _date = existing?.expenseDate ?? prefill?.date ?? AppDateUtils.today();
    _fromScan = prefill?.source == ExpensePrefillSource.receiptScan;
    final ExpenseProvider expenses = context.read<ExpenseProvider>();
    _paidForOffered = expenses.paidForAvailable;
    _tagsOffered = expenses.tagsAvailable;
    _claimRead = existing == null ? _ClaimRead.known : _ClaimRead.reading;
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadCards());
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadQuickAdd());
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadClaim());
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadTags());
  }

  /// "Paid for someone else" can be saved (migration 005).
  late final bool _paidForOffered;

  /// Tags can be read and saved (migration 006).
  late final bool _tagsOffered;

  /// Who this purchase was paid for, and the people already used. An edit
  /// always reads afresh: saving decides from it whether to unmark.
  Future<void> _loadClaim() async {
    if (!mounted) return;
    final String? userId = context.read<AuthProvider>().userId;
    final ReceivableProvider? receivables =
        context.read<ReceivableProvider?>();
    if (!_paidForOffered || userId == null || receivables == null) {
      if (_claimRead == _ClaimRead.reading) {
        setState(() => _claimRead = _ClaimRead.failed);
      }
      return;
    }
    final Expense? existing = widget.expense;
    await receivables.load(userId: userId, force: existing != null);
    if (!mounted) return;
    final bool failed = receivables.hasError;
    setState(() {
      _people = receivables.people;
      if (existing == null) return;
      if (failed) {
        _claimRead = _ClaimRead.failed;
        return;
      }
      final ClaimSummary? claim = receivables.claimForExpense(existing.id);
      _claim = claim;
      _paidFor = claim != null;
      _paidForPerson.text = claim?.receivable.person ?? '';
      _claimRead = _ClaimRead.known;
    });
  }

  /// A new expense shows tags at once (the suggestions follow); an edit once
  /// its own tags are known.
  bool get _showTags => _tagsOffered && (!widget.isEditing || _tagsRead);

  /// The user's tags and, for an edit, the expense's own.
  Future<void> _loadTags() async {
    if (!mounted || !_tagsOffered) return;
    final ExpenseProvider provider = context.read<ExpenseProvider>();
    final String? userId = context.read<AuthProvider>().userId;
    if (userId == null) return;
    final ({List<Tag> known, List<String> names})? read =
        await provider.tagsFor(userId: userId, expenseId: widget.expense?.id);
    if (!mounted || read == null) return;
    setState(() {
      _knownTags = read.known;
      // A new expense keeps whatever was added while the list loaded.
      if (widget.isEditing) _tags = List<String>.of(read.names);
      _tagsRead = true;
    });
  }

  /// The card choices, with their headroom. Cheap when already loaded.
  Future<void> _loadCards() async {
    if (!mounted || !SchemaCapabilities.creditCards) return;
    final String? userId = context.read<AuthProvider>().userId;
    if (userId == null) return;
    await context.read<CreditCardProvider>().load(userId: userId);
  }

  /// The purchases Quick add suggests from. Cheap when already read.
  Future<void> _loadQuickAdd() async {
    if (!mounted || !_offersQuickAdd) return;
    final String? userId = context.read<AuthProvider>().userId;
    if (userId == null) return;
    final QuickAddHistory? history =
        await context.read<ExpenseProvider>().quickAddHistory(userId: userId);
    if (!mounted || history == null) return;
    setState(() => _quickAddHistory = history);
  }

  /// The user's frequent expenses, rebuilt from the loaded lists so none
  /// ever points at a deleted category or a closed account or card.
  List<FrequentExpense> _quickAddSuggestions({
    required List<ExpenseCategory> categories,
    required List<PaymentMethod> methods,
    required List<BankAccount> accounts,
    required List<CardOverview> cards,
  }) {
    final QuickAddHistory? history = _quickAddHistory;
    if (history == null || !_offersQuickAdd) return const <FrequentExpense>[];
    return frequentExpenses(
      history.expenses,
      FrequentExpenseContext(
        today: AppDateUtils.today(),
        excludeIds: history.paidForIds,
        categoryIds: categories.map((ExpenseCategory c) => c.id).toSet(),
        paymentMethodIds: methods.map((PaymentMethod m) => m.id).toSet(),
        accountIds: accounts
            .where((BankAccount a) => a.isActive)
            .map((BankAccount a) => a.id)
            .toSet(),
        cardIds: cards.map((CardOverview o) => o.card.id).toSet(),
      ),
    );
  }

  /// Starts the form from the habit's latest purchase. Every field the chip
  /// covers is replaced, so switching chips never mixes two habits; nothing
  /// is saved until the user saves.
  void _applyQuickAdd(FrequentExpense suggestion) {
    final double? amount = suggestion.amount;
    final FrequentSource? source = suggestion.source;
    setState(() {
      // A varying amount is left blank for the user to type.
      _amount.text = amount == null ? '' : _trimTrailingZeros(amount);
      _categoryId = suggestion.categoryId;
      _merchant.text = suggestion.merchant ?? '';
      _description.text = suggestion.description ?? '';
      _paymentMethodId = suggestion.paymentMethodId;
      // An account or card closed since falls back to cash, as on a blank
      // form.
      _byCard = source?.kind == FrequentSourceKind.card;
      if (_byCard) {
        _creditCardId = source?.id;
      } else {
        // Cash comes out of the cash balance when there is one.
        _bankAccountId = source?.kind == FrequentSourceKind.account
            ? source?.id
            : BankAccount.cashOf(context.read<BankAccountProvider>().accounts)
                ?.id;
        _accountChosen = true;
      }
      _quickAdded = suggestion;
      _fromScan = false;
      _submitted = false;
      _error = null;
    });
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
      _quickAdded = null;
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
    _paidForPerson.dispose();
    _tagDraft.dispose();
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
    final CreditCardProvider cards = context.watch<CreditCardProvider>();

    final bool categoryMissing = _submitted && _categoryId == null;
    // Inactive cards are offered only to the purchase already on them.
    final List<CardOverview> cardOptions = SchemaCapabilities.creditCards
        ? cards.selectable(keepId: widget.expense?.creditCardId)
        : const <CardOverview>[];
    final bool payByCard = SchemaCapabilities.creditCards && _byCard;
    CardOverview? selectedCard;
    for (final CardOverview o in cardOptions) {
      if (o.card.id == _creditCardId) selectedCard = o;
    }
    final bool cardMissing = _submitted && payByCard && selectedCard == null;
    final List<FrequentExpense> quickAdd = _quickAddSuggestions(
      categories: categories.categories,
      methods: payments.methods,
      accounts: accounts.accounts,
      cards: cardOptions,
    );
    final FrequentExpense? quickAdded = _quickAdded;
    final ClaimSummary? claim = _claim;
    final bool showTags = _showTags;

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

            // ---------------------------------------------------------
            // Quick add — the user's frequent expenses, one tap each
            // ---------------------------------------------------------
            if (quickAdd.isNotEmpty) ...<Widget>[
              const FieldLabel('Quick add', hint: 'Your frequent expenses'),
              QuickAddChips(
                suggestions: quickAdd,
                categories: categories.categories,
                currency: settings.currency,
                selectedKey: quickAdded?.key,
                enabled: !_saving,
                onPicked: _applyQuickAdd,
              ),
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

            if (quickAdded != null) ...<Widget>[
              AppNotice(
                icon: Icons.auto_awesome_outlined,
                tone: theme.colorScheme.primary,
                message: 'Filled in from your usual '
                    '“${quickAddName(quickAdded, categories.categories)}”. '
                    '${quickAdded.amount == null ? 'Enter the amount (it varies) and change' : 'Change'}'
                    ' anything that is not right before saving.',
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
            if (SchemaCapabilities.phase2Ready ||
                cardOptions.isNotEmpty ||
                payByCard) ...<Widget>[
              FieldLabel(
                'Paid from',
                isRequired: true,
                hint: payByCard
                    ? (cardMissing ? 'Pick a card' : null)
                    : (_sourceAccountId(accounts.accounts) == null
                        ? 'No balance affected'
                        : null),
              ),
              if (cardOptions.isNotEmpty || payByCard) ...<Widget>[
                FundingToggle(
                  byCard: payByCard,
                  enabled: !_saving,
                  onChanged: (bool value) => setState(() {
                    _byCard = value;
                    _error = null;
                  }),
                ),
                const SizedBox(height: AppSpacing.sm),
              ],
              if (payByCard && cardOptions.isEmpty)
                cards.isLoading || cards.isIdle
                    ? const Skeleton(height: 40, radius: AppSpacing.radiusMd)
                    : cards.hasError
                        ? AppNotice(
                            icon: Icons.error_outline_rounded,
                            tone: theme.colorScheme.error,
                            message: 'Could not load your cards. '
                                '${cards.errorMessage ?? ''}',
                          )
                        : const AppNotice(
                            message: 'No active credit cards. Add one from '
                                'Credit cards, or switch to cash or account.',
                          )
              else if (payByCard) ...<Widget>[
                CardChoiceChips(
                  cards: cardOptions.map((CardOverview o) => o.card).toList(),
                  selectedId: _creditCardId,
                  enabled: !_saving,
                  onSelected: (String id) => setState(() {
                    _creditCardId = id;
                    _error = null;
                  }),
                ),
                if (selectedCard != null) ...<Widget>[
                  const SizedBox(height: AppSpacing.sm),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _amount,
                    builder: (BuildContext context, TextEditingValue value, _) =>
                        AvailableCreditLine(
                      card: selectedCard!.card,
                      summary: selectedCard.summary,
                      amount: Validators.parseAmount(value.text),
                      currency: settings.currency,
                      alreadyCounted:
                          widget.expense?.creditCardId == selectedCard.card.id
                              ? widget.expense!.amount
                              : 0,
                    ),
                  ),
                ],
              ] else if (SchemaCapabilities.phase2Ready)
                _SourcePicker(
                  accounts: accounts.accounts,
                  selectedAccountId: _sourceAccountId(accounts.accounts),
                  enabled: !_saving,
                  onSelected: (String? id) => setState(() {
                    _bankAccountId = id;
                    _accountChosen = true;
                  }),
                )
              else
                const AppNotice(message: 'Recorded as cash: no balance changes.'),
              const SizedBox(height: AppSpacing.lg),
            ],

            // ---------------------------------------------------------
            // Paid for someone else — owed back, so not your spending
            // ---------------------------------------------------------
            if (_paidForOffered && _claimRead != _ClaimRead.failed) ...<Widget>[
              if (_claimRead == _ClaimRead.reading)
                // Chip-shaped: a list skeleton cannot sit inside this list.
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Skeleton(
                    height: 34,
                    width: 190,
                    radius: AppSpacing.radiusPill,
                  ),
                )
              else
                PaidForField(
                  value: _paidFor,
                  onChanged: (bool value) => setState(() {
                    _paidFor = value;
                    _error = null;
                  }),
                  person: _paidForPerson,
                  people: _people,
                  submitted: _submitted,
                  enabled: !_saving,
                  progress: claim == null
                      ? null
                      : '${Formatters.currency(claim.received, currencyCode: settings.currency)} '
                          'of ${Formatters.currency(claim.principal, currencyCode: settings.currency)} '
                          'paid back · ${claim.status.label}',
                ),
              if (claim != null && !_paidFor && claim.received > 0) ...<Widget>[
                const SizedBox(height: AppSpacing.sm),
                AppNotice(
                  message: '${Formatters.currency(claim.received, currencyCode: settings.currency)} '
                      'already paid back stays as plain money in on its '
                      'account, and this becomes your own spending again.',
                ),
              ],
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
                  if (showTags) ...<Widget>[
                    TagField(
                      tags: _tags,
                      draft: _tagDraft,
                      known: _knownTags,
                      enabled: !_saving,
                      onChanged: (List<String> next) =>
                          setState(() => _tags = next),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
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
    // Never save while the card list is still loading or failed: that would
    // silently drop the card from a purchase.
    final CreditCardProvider cards = context.read<CreditCardProvider>();
    final bool payByCard = SchemaCapabilities.creditCards && _byCard;
    final bool cardKnown = cards
        .selectable(keepId: widget.expense?.creditCardId)
        .any((CardOverview o) => o.card.id == _creditCardId);
    if (payByCard && !cardKnown) {
      setState(() => _error = cards.isLoading || cards.hasError
          ? 'Your cards could not be loaded yet, so this cannot be saved '
              'against a card. Try again in a moment.'
          : 'Choose the credit card this was paid with.');
      return;
    }
    final bool paidForKnown =
        _paidForOffered && _claimRead == _ClaimRead.known;
    if (paidForKnown && _paidFor && _paidForPerson.text.trim().isEmpty) {
      setState(() => _error = 'Add who you paid for.');
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
      // One funding source: a card purchase never touches a bank balance.
      bankAccountId: payByCard
          ? null
          : _sourceAccountId(context.read<BankAccountProvider>().accounts),
      creditCardId: payByCard ? _creditCardId : null,
      merchant: _merchant.text,
      description: _description.text,
      notes: _notes.text,
    );

    final bool ok = await provider.save(
      draft,
      // Marked, unmarked, or — when it never was and still is not, or its
      // claim could not be read — left alone.
      paidFor: _paidForOffered
          ? paidForChange(
              known: paidForKnown,
              paidFor: _paidFor,
              person: _paidForPerson.text,
              claim: _claim?.receivable,
            )
          : const PaidForChange.keep(),
      // A tag typed but not confirmed counts too. Left alone when the tags
      // are unavailable.
      tags: _showTags
          ? TagField.withDraft(_tags, _tagDraft.text, _knownTags)
          : null,
    );

    if (!mounted) return;

    if (ok) {
      // The purchase's amount, date or claim may have changed what is owed.
      context.read<ReceivableProvider?>()?.invalidate();
      final String? warning = provider.saveWarning;
      if (warning != null) {
        AppFeedback.error(context, warning);
      } else {
        AppFeedback.success(
          context,
          widget.isEditing ? 'Expense updated' : 'Expense added',
        );
      }
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
      // A purchase paid for someone else takes its claim with it.
      context.read<ReceivableProvider?>()?.invalidate();
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

/// Where the form is with the purchase's claim (migration 005).
enum _ClaimRead {
  /// An edit's claim is being read; the toggle waits for it.
  reading,

  /// The toggle shows the truth: a new expense, or an edit's claim was read.
  known,

  /// The claim could not be read; nothing about it is shown or changed.
  failed,
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
/// Cash leads and is the default: untracked cash leaves every bank balance
/// untouched, and a kept cash balance (migration 011) is where cash spending
/// belongs — the safe choice either way if the user taps past this field.
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

    return AccountChoiceChips(
      accounts: accounts,
      selectedId: selectedAccountId,
      enabled: enabled,
      onSelected: onSelected,
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
