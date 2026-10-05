import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/errors/app_exception.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/validators.dart';
import '../../models/bank_account.dart';
import '../../models/credit_card.dart';
import '../../models/expense_category.dart';
import '../../models/ledger_entry.dart';
import '../../models/movement_treatment.dart';
import '../../models/receivable.dart';
import '../../providers/category_provider.dart';
import '../../providers/settings_provider.dart';
import '../../providers/statement_provider.dart';
import '../../repositories/tag_repository.dart';
import '../../services/schema_capabilities.dart';
import '../../widgets/category_avatar.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/app_feedback.dart';
import '../../widgets/common/app_fields.dart';
import '../../widgets/common/app_sheet.dart';
import '../../widgets/common/money_text.dart';
import '../../widgets/common/state_views.dart';
import '../../widgets/common/surface_card.dart';

/// What the edit sheet was closed with.
enum EditMovementResult { saved, delete }

/// Changes how a recorded bank movement is recorded: expense, income,
/// refund, transfer (to another account, the cash account, a card's bill, or
/// an account not tracked here), money lent, a loan repaid, or a purchase
/// paid back — plus who it was paid for, and its tags. The web app's
/// EditMovementSheet, with its wording and its checks.
///
/// Everything a change involves — an expense removed, the other transfer leg
/// added or linked, a claim created — is saved by `apply_bank_treatment` in
/// one database transaction, so balances, income, spending and what is owed
/// always agree. Pops [EditMovementResult.saved] after a save, or
/// [EditMovementResult.delete] when the user asks to delete the movement.
class EditMovementSheet extends StatefulWidget {
  const EditMovementSheet({
    super.key,
    required this.entry,
    required this.account,
    required this.accounts,
    required this.cards,
  });

  final LedgerEntry entry;

  /// The account the statement is for — the one [entry] is on.
  final BankAccount account;

  /// Every account, for the other side of a transfer (the cash account is
  /// one of them).
  final List<BankAccount> accounts;

  /// The user's cards, for a bill payment.
  final List<CreditCard> cards;

  @override
  State<EditMovementSheet> createState() => _EditMovementSheetState();
}

class _EditMovementSheetState extends State<EditMovementSheet> {
  /// A tag is at most 40 characters and a row has at most 20 — the limits
  /// `set_transaction_tags` enforces.
  static const int _maxTagLength = 40;
  static const int _maxTags = 20;
  static const double _maxAmount = 999999999;

  static const Map<String, IconData> _kindIcons = <String, IconData>{
    TreatmentKind.transfer: Icons.swap_horiz_rounded,
    TreatmentKind.loan: Icons.handshake_outlined,
    TreatmentKind.reimbursement: Icons.handshake_outlined,
  };

  late final bool _debit = widget.entry.isDebit;
  late final TextEditingController _amount =
      TextEditingController(text: _trim(widget.entry.amount));
  late final TextEditingController _description =
      TextEditingController(text: widget.entry.description ?? '');
  final TextEditingController _source = TextEditingController();
  final TextEditingController _person = TextEditingController();
  final TextEditingController _note = TextEditingController();
  final TextEditingController _tagDraft = TextEditingController();

  MovementEditContext? _data;
  String? _loadError;
  EntryClaim? _claim;
  late List<String> _kinds =
      fallbackKinds(debit: _debit, treatments: SchemaCapabilities.treatments);

  String _kind = TreatmentKind.expense;
  String? _categoryId;
  TransferTarget? _target;

  /// The other account's row chosen as the other leg; null for the closest.
  String? _matchId;

  /// "No — add it": a new other leg even though a row matches.
  bool _addNewLeg = false;
  DateTime? _dueDate;
  bool _reimbursable = false;
  SettlementTarget? _settles;
  late DateTime _date = widget.entry.txnDate;
  bool _keepCounterpart = false;
  List<String> _tags = <String>[];
  bool _submitted = false;
  bool _busy = false;
  String? _error;

  List<LedgerEntry> _matches = const <LedgerEntry>[];
  bool _matchesLoading = false;
  String? _matchesKey;
  List<ClaimPurchase> _purchases = const <ClaimPurchase>[];
  bool _purchasesLoading = false;
  String? _purchasesKey;
  Timer? _amountTimer;

  static String _trim(double value) {
    final String text = value.toStringAsFixed(2);
    return text.endsWith('.00') ? text.substring(0, text.length - 3) : text;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _load();
      _loadKinds();
    });
  }

  @override
  void dispose() {
    _amountTimer?.cancel();
    _amount.dispose();
    _description.dispose();
    _source.dispose();
    _person.dispose();
    _note.dispose();
    _tagDraft.dispose();
    super.dispose();
  }

  StatementProvider get _provider => context.read<StatementProvider>();

  Future<void> _load() async {
    setState(() {
      _loadError = null;
      _data = null;
    });
    try {
      final MovementEditContext data = await _provider.loadEdit(widget.entry);
      if (!mounted) return;
      final EntryClaim? claim = claimOfEntry(widget.entry, data.claims);
      final TreatmentState initial = initialTreatment(widget.entry, claim);
      final Receivable? own = claim != null && claim.isSource ? claim.receivable : null;
      setState(() {
        _data = data;
        _claim = claim;
        _kind = initial.kind;
        _categoryId = initial.categoryId;
        _target = initial.target;
        _person.text = initial.person;
        _reimbursable = initial.reimbursable;
        _settles = initial.settles;
        _dueDate = own?.dueDate;
        _note.text = own?.note ?? '';
        _source.text = data.incomeSource ?? '';
        _tags = List<String>.of(data.tags ?? const <String>[]);
      });
      _refreshLookups();
    } catch (error) {
      if (!mounted) return;
      setState(() => _loadError = ErrorMapper.map(error).message);
    }
  }

  /// The valid kinds are the engine's rule, not a copy; until it answers,
  /// the same list stands in.
  Future<void> _loadKinds() async {
    try {
      final List<String> kinds = await _provider.treatmentKinds(debit: _debit);
      if (!mounted || kinds.isEmpty) return;
      setState(() => _kinds = kinds);
    } catch (_) {
      // Keep the stand-in list; saving reports an engine that cannot run.
    }
  }

  TreatmentState get _state => TreatmentState(
        kind: _kind,
        categoryId: _categoryId,
        target: _target,
        person: _person.text,
        dueDate: _dueDate,
        note: _note.text,
        reimbursable: _reimbursable,
        settles: _settles,
      );

  double? get _value => Validators.parseAmount(_amount.text);

  bool get _showTags =>
      SchemaCapabilities.tags &&
      _data?.tags != null &&
      (_kind == TreatmentKind.expense || _kind == TreatmentKind.income);

  BankAccount? _accountById(String? id) {
    if (id == null) return null;
    for (final BankAccount a in widget.accounts) {
      if (a.id == id) return a;
    }
    return null;
  }

  CreditCard? _cardById(String? id) {
    if (id == null) return null;
    for (final CreditCard c in widget.cards) {
      if (c.id == id) return c;
    }
    return null;
  }

  // ---- Lookups: the other account's rows, purchases to pay back -------------

  void _refreshLookups() {
    _refreshMatches();
    _refreshPurchases();
  }

  /// A new other account may already hold the other side (its statement was
  /// imported).
  void _refreshMatches() {
    final MovementEditContext? data = _data;
    final String? accountId =
        data == null ? null : newTransferAccountId(widget.entry, _state);
    final double? amount = _value;
    if (data == null || accountId == null || amount == null || amount <= 0) {
      if (_matchesKey != null || _matchesLoading) {
        setState(() {
          _matchesKey = null;
          _matches = const <LedgerEntry>[];
          _matchesLoading = false;
        });
      }
      return;
    }
    final String key =
        '$accountId|${(amount * 100).round()}|${_date.toIso8601String()}';
    if (key == _matchesKey) return;
    setState(() {
      _matchesKey = key;
      _matchesLoading = true;
    });
    _provider
        .transferMatches(
          accountId: accountId,
          direction: widget.entry.direction,
          amount: amount,
          date: _date,
          claims: data.claims,
        )
        .then(
          (List<LedgerEntry> found) {
            if (!mounted || _matchesKey != key) return;
            setState(() {
              _matches = found;
              _matchesLoading = false;
            });
          },
          onError: (Object _) {
            if (!mounted || _matchesKey != key) return;
            setState(() {
              _matches = const <LedgerEntry>[];
              _matchesLoading = false;
            });
          },
        );
  }

  void _refreshPurchases() {
    if (_data == null || _kind != TreatmentKind.reimbursement) return;
    final String key = _date.toIso8601String();
    if (key == _purchasesKey) return;
    setState(() {
      _purchasesKey = key;
      _purchasesLoading = true;
    });
    _provider.purchasesBefore(_date).then(
      (List<ClaimPurchase> found) {
        if (!mounted || _purchasesKey != key) return;
        setState(() {
          _purchases = found;
          _purchasesLoading = false;
        });
      },
      onError: (Object _) {
        if (!mounted || _purchasesKey != key) return;
        setState(() {
          _purchases = const <ClaimPurchase>[];
          _purchasesLoading = false;
        });
      },
    );
  }

  LedgerEntry? get _selectedMatch {
    if (_addNewLeg) return null;
    for (final LedgerEntry m in _matches) {
      if (m.id == _matchId) return m;
    }
    return _matches.isEmpty ? null : _matches.first;
  }

  void _changeKind(String kind) {
    setState(() {
      _kind = kind;
      _error = null;
    });
    _refreshLookups();
  }

  void _changeTarget(TransferTarget target) {
    setState(() {
      _target = target;
      _matchId = null;
      _addNewLeg = false;
      _error = null;
    });
    _refreshMatches();
  }

  void _amountChanged(String _) {
    setState(() {});
    _amountTimer?.cancel();
    _amountTimer = Timer(const Duration(milliseconds: 400), () {
      if (mounted) _refreshMatches();
    });
  }

  // ---- Build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final SettingsProvider settings = context.watch<SettingsProvider>();
    final String currency = settings.currency;
    final LedgerEntry entry = widget.entry;
    final MovementEditContext? data = _data;

    return AppSheet(
      title: 'Edit transaction',
      subtitle: '${widget.account.displayLabel} · '
          '${Formatters.currency(entry.amount, currencyCode: currency)} '
          '${_debit ? 'out' : 'in'}',
      action: IconButton(
        tooltip: 'Delete',
        onPressed: _busy ? null : () => Navigator.of(context).pop(EditMovementResult.delete),
        icon: const Icon(Icons.delete_outline_rounded),
        color: theme.colorScheme.error,
      ),
      footer: AppButton.submit(
        label: 'Save',
        busy: _busy,
        busyLabel: 'Saving…',
        onPressed: data == null ? null : _save,
      ),
      children: data == null
          ? (_loadError != null
              ? <Widget>[
                  InlineError(message: _loadError!),
                  const SizedBox(height: AppSpacing.md),
                  Align(
                    child: AppButton(
                      label: 'Try again',
                      variant: AppButtonVariant.secondary,
                      onPressed: _load,
                    ),
                  ),
                ]
              : <Widget>[
                  for (int i = 0; i < 4; i++) ...<Widget>[
                    const Skeleton(height: AppSpacing.fieldHeight, radius: AppSpacing.radiusMd),
                    const SizedBox(height: AppSpacing.md),
                  ],
                ])
          : _form(theme, data, currency, settings.currencySymbol),
    );
  }

  List<Widget> _form(
    ThemeData theme,
    MovementEditContext data,
    String currency,
    String symbol,
  ) {
    final LedgerEntry entry = widget.entry;
    final TreatmentState state = _state;
    final TreatmentProblem? problem =
        _submitted ? treatmentProblem(state, debit: _debit) : null;
    final double? value = _value;
    final String amountText = value != null && value > 0
        ? Formatters.currency(value, currencyCode: currency)
        : 'this amount';
    final String? hint = treatmentHint(_kind, debit: _debit);

    // The transfer as it is now, and whether this edit keeps it.
    final bool wasAccountTransfer = isAccountTransfer(entry);
    final bool keeps = keepsTransfer(entry, state);
    final BankAccount? oldOther =
        wasAccountTransfer ? _accountById(entry.counterpartyAccountId) : null;
    final BankAccount? newTarget = _accountById(newTransferAccountId(entry, state));
    final EntryClaim? own = _claim != null && _claim!.isSource ? _claim : null;
    final bool stopsClaim = stopsOwnClaim(own, state);
    final bool linkedTone = _kind == TreatmentKind.transfer ||
        _kind == TreatmentKind.loan ||
        _kind == TreatmentKind.reimbursement;

    return <Widget>[
      const FieldLabel('Record as'),
      Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.sm,
        children: _kinds
            .map((String k) => AppChoiceChip(
                  label: treatmentLabels[k] ?? k,
                  icon: _kindIcons[k],
                  selected: k == _kind,
                  enabled: !_busy,
                  onSelected: () => _changeKind(k),
                ))
            .toList(),
      ),
      // On its own line: beside the label it does not fit a phone's width.
      if (hint != null) ...<Widget>[
        const SizedBox(height: AppSpacing.xs),
        Text(hint, style: theme.textTheme.labelSmall),
      ],
      if (_kind == TreatmentKind.transfer) ...<Widget>[
        const SizedBox(height: AppSpacing.lg),
        ..._transferTarget(theme, problem == TreatmentProblem.transferTarget),
        if (newTarget != null) ...<Widget>[
          const SizedBox(height: AppSpacing.md),
          _matchChoice(theme, newTarget, amountText),
        ],
      ],
      if (_kind == TreatmentKind.loan) ...<Widget>[
        const SizedBox(height: AppSpacing.lg),
        if (_debit)
          ..._loanDetails(theme, data, problem == TreatmentProblem.loanPerson)
        else
          _settlementPicker(
            theme,
            label: 'Repays',
            options: claimOptions(
              claims: data.claims,
              kind: ReceivableKind.loan,
              current: _settles,
              excludeEntryId: entry.id,
              currency: currency,
            ),
            currency: currency,
            missing: problem == TreatmentProblem.loan,
            emptyText: 'No money lent is waiting to be repaid. Record the loan '
                'first — on its money-out row, Record as Loan.',
          ),
      ],
      if (_kind == TreatmentKind.reimbursement) ...<Widget>[
        const SizedBox(height: AppSpacing.lg),
        _personField(
          theme,
          data,
          label: 'From',
          missing: problem == TreatmentProblem.settlePerson,
        ),
        const SizedBox(height: AppSpacing.md),
        _settlementPicker(
          theme,
          label: 'Pays back',
          options: byPersonFirst(
            <SettleOption>[
              ...claimOptions(
                claims: data.claims,
                kind: ReceivableKind.reimbursable,
                current: _settles,
                excludeEntryId: entry.id,
                currency: currency,
              ),
              ...purchaseOptions(
                purchases: _purchases,
                claims: data.claims,
                cards: widget.cards,
                currency: currency,
              ),
            ],
            _person.text,
          ),
          currency: currency,
          missing: problem == TreatmentProblem.settles,
          emptyText: _purchasesLoading
              ? 'Loading recent purchases…'
              : 'No purchases in the last few months to match.',
        ),
      ],
      if (wasAccountTransfer && !keeps && oldOther != null) ...<Widget>[
        const SizedBox(height: AppSpacing.md),
        _keepCounterpartBox(theme, oldOther),
      ],
      if (stopsClaim && own!.summary.received > 0) ...<Widget>[
        const SizedBox(height: AppSpacing.md),
        AppNotice(
          message: '${Formatters.currency(own.summary.received, currencyCode: currency)} '
              'already paid back stays as plain money in on its account. It will '
              'no longer reduce anything owed.',
        ),
      ],
      const SizedBox(height: AppSpacing.lg),
      const FieldLabel('Amount', isRequired: true),
      AmountField(
        controller: _amount,
        symbol: symbol,
        autofocus: false,
        enabled: !_busy,
        onChanged: _amountChanged,
        tone: linkedTone
            ? ToneColors.transfer(context)
            : (_debit ? ToneColors.expense(context) : ToneColors.income(context)),
      ),
      if (keeps &&
          oldOther != null &&
          value != null &&
          (value * 100).round() != (entry.amount * 100).round()) ...<Widget>[
        const SizedBox(height: AppSpacing.xs),
        Text(
          'The other side on ${oldOther.nickname} changes to the same amount.',
          style: theme.textTheme.labelSmall,
        ),
      ],
      if (_kind == TreatmentKind.income) ...<Widget>[
        const SizedBox(height: AppSpacing.lg),
        const FieldLabel('Source', hint: 'Optional'),
        TextField(
          controller: _source,
          enabled: !_busy,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            hintText: 'Salary, interest, client…',
            prefixIcon: Icon(Icons.work_outline_rounded, size: AppSpacing.iconMd),
          ),
        ),
      ],
      const SizedBox(height: AppSpacing.lg),
      const FieldLabel('Description', hint: 'Optional'),
      TextField(
        controller: _description,
        enabled: !_busy,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(
          prefixIcon: Icon(Icons.short_text_rounded, size: AppSpacing.iconMd),
        ),
      ),
      if (_showTags) ...<Widget>[
        const SizedBox(height: AppSpacing.lg),
        const FieldLabel('Tags', hint: 'Optional'),
        _tagField(),
      ],
      const SizedBox(height: AppSpacing.lg),
      const FieldLabel('Date', isRequired: true),
      DateField(
        date: _date,
        enabled: !_busy,
        onChanged: (DateTime value) {
          setState(() => _date = value);
          _refreshLookups();
        },
      ),
      if (_kind == TreatmentKind.expense) ...<Widget>[
        const SizedBox(height: AppSpacing.lg),
        FieldLabel(
          'Category',
          isRequired: true,
          hint: problem == TreatmentProblem.category ? 'Pick one' : null,
        ),
        _categoryChips(theme),
        if (SchemaCapabilities.treatments) ...<Widget>[
          const SizedBox(height: AppSpacing.lg),
          ..._paidFor(theme, data, own, currency, problem == TreatmentProblem.paidForPerson),
        ],
      ],
      if (_error != null) ...<Widget>[
        const SizedBox(height: AppSpacing.lg),
        InlineError(message: _error!),
      ],
    ];
  }

  /// "Transfer to" (money out) or "Transfer from" (money in): your other
  /// accounts — the cash account among them — an account not tracked here,
  /// and (money out) your cards' bills.
  List<Widget> _transferTarget(ThemeData theme, bool missing) {
    final TransferTarget? target = _target;
    final bool hasCash = BankAccount.cashOf(widget.accounts) != null;
    // Inactive accounts and cards stay listed only when already chosen.
    final List<BankAccount> others = SchemaCapabilities.transfers
        ? widget.accounts
            .where((BankAccount a) =>
                a.id != widget.account.id &&
                (a.isActive || target == TransferTarget.account(a.id)))
            .toList()
        : const <BankAccount>[];
    final List<CreditCard> payable = _debit && SchemaCapabilities.creditCards
        ? widget.cards
            .where((CreditCard c) => c.isActive || target == TransferTarget.card(c.id))
            .toList()
        : const <CreditCard>[];

    final BankAccount? account = target != null && target.isAccount ? _accountById(target.accountId) : null;
    final CreditCard? card = target != null && target.isCard ? _cardById(target.cardId) : null;
    final String here = widget.account.nickname;
    final String? there = account != null
        ? account.nickname
        : card != null
            ? card.displayLabel
            : target != null && target.isCash
                ? (hasCash ? 'Not tracked' : 'Cash')
                : null;
    final String? note = target == null
        ? null
        : target.isAccount
            ? 'Your own money moving: both balances change. Not income or spending.'
            : target.isCard
                ? "Pays the card's bill: its outstanding goes down. Not spending — "
                    'the purchases already are.'
                : 'Only this balance changes. Not income or spending.';
    final IconData thereIcon = card != null
        ? Icons.credit_card_rounded
        : (target != null && target.isCash) || (account != null && account.isCash)
            ? Icons.payments_outlined
            : Icons.account_balance_outlined;
    final IconData hereIcon =
        widget.account.isCash ? Icons.payments_outlined : Icons.account_balance_outlined;

    return <Widget>[
      FieldLabel(
        _debit ? 'Transfer to' : 'Transfer from',
        isRequired: true,
        hint: missing ? 'Choose one' : null,
      ),
      Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.sm,
        children: <Widget>[
          for (final BankAccount a in others)
            AppChoiceChip(
              label: a.displayLabel,
              icon: a.isCash ? Icons.payments_outlined : Icons.account_balance_outlined,
              selected: target == TransferTarget.account(a.id),
              enabled: !_busy,
              onSelected: () => _changeTarget(TransferTarget.account(a.id)),
            ),
          AppChoiceChip(
            // With a cash balance kept, cash is one of the accounts above.
            label: hasCash ? 'An account not tracked here' : 'Cash, or an account not tracked here',
            icon: hasCash ? Icons.account_balance_wallet_outlined : Icons.payments_outlined,
            selected: target == const TransferTarget.cash(),
            enabled: !_busy,
            onSelected: () => _changeTarget(const TransferTarget.cash()),
          ),
          for (final CreditCard c in payable)
            AppChoiceChip(
              label: '${c.displayLabel} — card bill',
              icon: Icons.credit_card_rounded,
              selected: target == TransferTarget.card(c.id),
              enabled: !_busy,
              onSelected: () => _changeTarget(TransferTarget.card(c.id)),
            ),
        ],
      ),
      if (there != null) ...<Widget>[
        const SizedBox(height: AppSpacing.sm),
        _route(
          theme,
          from: _debit ? here : there,
          fromIcon: _debit ? hereIcon : thereIcon,
          to: _debit ? there : here,
          toIcon: _debit ? thereIcon : hereIcon,
        ),
      ],
      if (note != null) ...<Widget>[
        const SizedBox(height: AppSpacing.xs),
        Text(note, style: theme.textTheme.labelSmall),
      ],
    ];
  }

  Widget _route(
    ThemeData theme, {
    required String from,
    required IconData fromIcon,
    required String to,
    required IconData toIcon,
  }) {
    final Color muted = theme.colorScheme.onSurfaceVariant;
    Widget end(IconData icon, String label) => Flexible(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 15, color: muted),
              const SizedBox(width: AppSpacing.xs),
              Flexible(
                child: Text(
                  label,
                  style: theme.textTheme.labelMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        );
    return Row(
      children: <Widget>[
        end(fromIcon, from),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          child: Icon(Icons.arrow_forward_rounded, size: 15, color: muted),
        ),
        end(toIcon, to),
      ],
    );
  }

  /// Whether the other account already has this movement (both statements
  /// imported): pick it to link the two, or add a new entry there.
  Widget _matchChoice(ThemeData theme, BankAccount other, String amountText) {
    final String name = other.nickname;
    if (_matchesLoading) {
      return Text('Checking $name for the same transaction…',
          style: theme.textTheme.labelSmall);
    }
    if (_matches.isEmpty) {
      return Text('Adds $amountText on $name as the other side.',
          style: theme.textTheme.labelSmall);
    }
    final String selected = _selectedMatch?.id ?? 'new';
    Widget choice(String value, String title, String? subtitle) => RadioListTile<String>(
          value: value,
          groupValue: selected,
          dense: true,
          contentPadding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          title: Text(title, style: theme.textTheme.bodyMedium),
          subtitle: subtitle == null ? null : Text(subtitle, style: theme.textTheme.labelSmall),
          onChanged: _busy
              ? null
              : (String? v) => setState(() {
                    _addNewLeg = v == 'new';
                    _matchId = v == 'new' ? null : v;
                  }),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        FieldLabel('Already on $name?'),
        for (final LedgerEntry m in _matches)
          choice(
            m.id,
            'Link ${Formatters.dayMonth(m.txnDate)} · ${m.title}',
            m.incomeId != null
                ? 'Was recorded as income — it will no longer count as income'
                : m.expenseId != null
                    ? 'Was recorded as an expense — it will no longer count as spending'
                    : 'The same money, recorded once — no second entry',
          ),
        choice('new', 'No — add $amountText on $name', null),
      ],
    );
  }

  /// Lent to [person], with an optional due date and note.
  List<Widget> _loanDetails(ThemeData theme, MovementEditContext data, bool missing) {
    return <Widget>[
      _personField(theme, data, label: 'Lent to', missing: missing),
      const SizedBox(height: AppSpacing.sm),
      SelectField(
        value: _dueDate == null ? null : 'Due back ${Formatters.dayMonthYear(_dueDate!)}',
        placeholder: 'Due back (optional)',
        icon: Icons.event_rounded,
        enabled: !_busy,
        onTap: _pickDueDate,
        trailing: _dueDate == null
            ? null
            : IconButton(
                tooltip: 'Clear due date',
                icon: const Icon(Icons.close_rounded, size: AppSpacing.iconSm),
                onPressed: _busy ? null : () => setState(() => _dueDate = null),
              ),
      ),
      const SizedBox(height: AppSpacing.sm),
      TextField(
        controller: _note,
        enabled: !_busy,
        inputFormatters: <TextInputFormatter>[LengthLimitingTextInputFormatter(200)],
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(
          hintText: 'Note (optional)',
          prefixIcon: Icon(Icons.notes_rounded, size: AppSpacing.iconMd),
        ),
      ),
    ];
  }

  Future<void> _pickDueDate() async {
    final DateTime now = DateTime.now();
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _dueDate ?? _date,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 10, 12, 31),
    );
    if (picked == null || !mounted) return;
    setState(() => _dueDate = DateTime(picked.year, picked.month, picked.day));
  }

  /// Free text with the people already used offered as suggestions, so
  /// "Arun" stays one person.
  Widget _personField(
    ThemeData theme,
    MovementEditContext data, {
    required String label,
    required bool missing,
  }) {
    final String typed = personKey(_person.text);
    final List<String> suggestions = knownPeople(data.claims)
        .where((String p) =>
            personKey(p) != typed && (typed.isEmpty || personKey(p).startsWith(typed)))
        .take(4)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        FieldLabel(label, isRequired: true, hint: missing ? 'Add a name' : null),
        TextField(
          controller: _person,
          enabled: !_busy,
          textCapitalization: TextCapitalization.words,
          inputFormatters: <TextInputFormatter>[LengthLimitingTextInputFormatter(80)],
          decoration: const InputDecoration(
            hintText: 'Name',
            prefixIcon: Icon(Icons.person_outline_rounded, size: AppSpacing.iconMd),
          ),
          onChanged: (_) => setState(() {}),
        ),
        if (suggestions.isNotEmpty) ...<Widget>[
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: suggestions
                .map((String p) => AppChoiceChip(
                      label: p,
                      icon: Icons.person_outline_rounded,
                      selected: false,
                      enabled: !_busy,
                      onSelected: () => setState(() => _person.text = p),
                    ))
                .toList(),
          ),
        ],
      ],
    );
  }

  /// What this pays back, and what is left after it.
  Widget _settlementPicker(
    ThemeData theme, {
    required String label,
    required List<SettleOption> options,
    required String currency,
    required bool missing,
    required String emptyText,
  }) {
    SettleOption? chosen;
    for (final SettleOption o in options) {
      if (o.key == _settles?.key) chosen = o;
    }
    final double? value = _value;
    String? status;
    Color? statusTone;
    if (chosen != null && value != null && value > 0) {
      final double left = leftAfter(chosen, value);
      if (left == 0) {
        status = 'This settles it.';
        statusTone = ToneColors.income(context);
      } else if (left > 0) {
        status = '${Formatters.currency(left, currencyCode: currency)} still owed after this.';
      } else {
        status = '${Formatters.currency(-left, currencyCode: currency)} more than is owed — '
            'it will show as overpaid.';
        statusTone = ToneColors.warning(context);
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        FieldLabel(label, isRequired: true, hint: missing ? 'Choose one' : null),
        if (options.isNotEmpty)
          SelectField(
            value: chosen?.label,
            placeholder: 'Select',
            icon: Icons.handshake_outlined,
            enabled: !_busy,
            onTap: () => _chooseSettlement(label, options),
          )
        else
          Text(emptyText, style: theme.textTheme.bodySmall),
        if (status != null) ...<Widget>[
          const SizedBox(height: AppSpacing.xs),
          Text(
            status,
            style: theme.textTheme.labelSmall?.copyWith(color: statusTone),
          ),
        ],
      ],
    );
  }

  Future<void> _chooseSettlement(String label, List<SettleOption> options) async {
    final SettleOption? picked = await showAppSheet<SettleOption>(
      context: context,
      builder: (BuildContext sheet) => AppSheet(
        title: label,
        children: <Widget>[
          CardList(
            dividerIndent: AppSpacing.md,
            children: options
                .map((SettleOption o) => AppListRow(
                      title: o.label,
                      trailing: o.key == _settles?.key
                          ? Icon(Icons.check_rounded, color: Theme.of(sheet).colorScheme.primary)
                          : null,
                      onTap: () => Navigator.of(sheet).pop(o),
                    ))
                .toList(),
          ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _settles = picked.target;
      if (picked.person != null) _person.text = picked.person!;
      _error = null;
    });
  }

  /// "Paid for someone else": the expense is owed back, so it leaves your
  /// spending.
  List<Widget> _paidFor(
    ThemeData theme,
    MovementEditContext data,
    EntryClaim? own,
    String currency,
    bool missing,
  ) {
    final ClaimSummary? paidFor = own != null && own.receivable.kind == ReceivableKind.reimbursable
        ? own.summary
        : null;
    return <Widget>[
      Align(
        alignment: Alignment.centerLeft,
        child: AppChoiceChip(
          label: 'Paid for someone else',
          icon: Icons.handshake_outlined,
          selected: _reimbursable,
          enabled: !_busy,
          onSelected: () => setState(() => _reimbursable = !_reimbursable),
        ),
      ),
      if (_reimbursable) ...<Widget>[
        const SizedBox(height: AppSpacing.md),
        _personField(theme, data, label: 'Paid for', missing: missing),
        const SizedBox(height: AppSpacing.xs),
        Text(
          paidFor != null
              ? '${Formatters.currency(paidFor.received, currencyCode: currency)} of '
                  '${Formatters.currency(paidFor.principal, currencyCode: currency)} paid back'
              : 'Owed back to you — not counted as your spending.',
          style: theme.textTheme.labelSmall,
        ),
      ],
    ];
  }

  Widget _keepCounterpartBox(ThemeData theme, BankAccount other) {
    final String name = other.nickname;
    return InkWell(
      borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      onTap: _busy ? null : () => setState(() => _keepCounterpart = !_keepCounterpart),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Checkbox(
            value: _keepCounterpart,
            visualDensity: VisualDensity.compact,
            onChanged: _busy ? null : (bool? v) => setState(() => _keepCounterpart = v ?? false),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: Text(
                'Keep the other side on $name as plain money ${_debit ? 'in' : 'out'}. '
                "Leave this off unless that entry came from $name's own statement — "
                'otherwise it is removed, so its balance stays right.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _categoryChips(ThemeData theme) {
    final List<ExpenseCategory> categories = context.watch<CategoryProvider>().categories;
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: categories
          .map((ExpenseCategory c) => AppChoiceChip(
                label: c.name,
                selected: c.id == _categoryId,
                enabled: !_busy,
                tone: AppColors.readableOn(AppColors.fromHex(c.color), theme.brightness),
                avatar: CategoryAvatar(icon: c.icon, color: c.color, size: 20),
                onSelected: () => setState(() {
                  _categoryId = c.id;
                  _error = null;
                }),
              ))
          .toList(),
    );
  }

  Widget _tagField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (_tags.isNotEmpty) ...<Widget>[
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: _tags
                .map((String tag) => InputChip(
                      label: Text('#$tag'),
                      visualDensity: VisualDensity.compact,
                      onDeleted: _busy ? null : () => setState(() => _tags.remove(tag)),
                    ))
                .toList(),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        TextField(
          controller: _tagDraft,
          enabled: !_busy,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            hintText: 'Add a tag',
            prefixIcon: Icon(Icons.tag_rounded, size: AppSpacing.iconSm),
          ),
          onChanged: (String value) {
            if (value.contains(',')) _commitTag();
          },
          onSubmitted: (_) => _commitTag(),
        ),
      ],
    );
  }

  /// The tags with the one being typed, cleaned as the database cleans them:
  /// no "#", single spaces, no repeats (ignoring case).
  List<String> _withDraft() {
    final List<String> next = List<String>.of(_tags);
    for (final String part in _tagDraft.text.split(',')) {
      final String name =
          part.replaceFirst(RegExp(r'^\s*#+'), '').replaceAll(RegExp(r'\s+'), ' ').trim();
      if (name.isEmpty) continue;
      final String clipped =
          name.length > _maxTagLength ? name.substring(0, _maxTagLength) : name;
      if (next.any((String t) => t.toLowerCase() == clipped.toLowerCase())) continue;
      if (next.length >= _maxTags) break;
      next.add(clipped);
    }
    return next;
  }

  void _commitTag() {
    setState(() {
      _tags = _withDraft();
      _tagDraft.clear();
    });
  }

  // ---- Save --------------------------------------------------------------------

  Future<void> _save() async {
    if (_busy) return;
    setState(() => _submitted = true);
    final double? value = _value;
    if (value == null || value <= 0 || value > _maxAmount) {
      setState(() => _error = 'Enter an amount greater than 0.');
      return;
    }
    final TreatmentState state = _state;
    final TreatmentProblem? missing = treatmentProblem(state, debit: _debit);
    if (missing != null) {
      setState(() => _error = treatmentProblemMessage(missing, debit: _debit));
      return;
    }
    final Map<String, Object?> request = buildTreatmentRequest(
      entry: widget.entry,
      account: widget.account,
      state: state,
      amount: value,
      date: _date,
      description: _description.text,
      source: _source.text,
      keepCounterpart: _keepCounterpart,
      matchEntryId: _selectedMatch?.id,
      claim: _claim,
    );
    setState(() {
      _error = null;
      _busy = true;
    });
    try {
      final String? tagError = await _provider.applyTreatment(
        entry: widget.entry,
        request: request,
        // Typed but not confirmed counts too. Only an expense or income has tags.
        tags: _showTags
            ? (
                kind: _kind == TreatmentKind.expense ? TagKind.expense : TagKind.income,
                names: _withDraft(),
              )
            : null,
      );
      if (!mounted) return;
      if (tagError != null) {
        AppFeedback.error(context, 'The transaction was saved, but its tags were not: $tagError');
      } else {
        AppFeedback.success(context, 'Transaction updated');
      }
      Navigator.of(context).pop(EditMovementResult.saved);
    } catch (error) {
      if (!mounted) return;
      final AppException mapped = ErrorMapper.map(error);
      setState(() {
        _busy = false;
        _error = mapped.message.isEmpty ? 'Could not update the transaction.' : mapped.message;
      });
    }
  }
}
