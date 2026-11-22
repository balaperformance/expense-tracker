import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/utils/date_utils.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/validators.dart';
import '../../models/bank_account.dart';
import '../../models/card_statement.dart';
import '../../models/credit_card.dart';
import '../../models/ledger_entry.dart';
import '../../providers/bank_account_provider.dart';
import '../../providers/credit_card_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/schema_capabilities.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/app_feedback.dart';
import '../../widgets/common/app_fields.dart';
import '../../widgets/common/app_sheet.dart';
import '../../widgets/common/money_text.dart';
import '../../widgets/common/state_views.dart';
import '../../widgets/common/surface_card.dart';

/// Pays a card bill from a bank account or in cash. Never an expense.
///
/// If the payment is already on the account — typed in, or imported from a
/// bank statement — the sheet offers that debit to link instead, so the
/// account is never debited twice. Pops true when something was written.
class CardPaymentSheet extends StatefulWidget {
  const CardPaymentSheet({
    super.key,
    required this.overview,
    this.initialAmount,
    this.initialAccountId,
    this.initialDate,
    this.initialNote,
  });

  final CardOverview overview;

  /// What the sheet opens with when started from somewhere else — an
  /// expense form or a bank alert that turned out to be this bill.
  final double? initialAmount;
  final String? initialAccountId;
  final DateTime? initialDate;
  final String? initialNote;

  @override
  State<CardPaymentSheet> createState() => _CardPaymentSheetState();
}

/// Opens Pay bill for one of the user's active cards — asked which when
/// there are several — prefilled with what is known. Resolves to true when a
/// payment was recorded or linked, false when not, null with no card.
Future<bool?> openCardBillPayment(
  BuildContext context, {
  double? amount,
  String? accountId,
  DateTime? date,
  String? note,
  String? cardId,
}) async {
  final CreditCardProvider cards = context.read<CreditCardProvider>();
  final List<CardOverview> active = cards.selectable(keepId: cardId);
  if (active.isEmpty) {
    AppFeedback.error(context, 'Add the credit card first, from Credit cards.');
    return null;
  }
  CardOverview? chosen;
  for (final CardOverview o in active) {
    if (o.card.id == cardId) chosen = o;
  }
  if (chosen == null && active.length == 1) chosen = active.first;
  chosen ??= await showAppDialog<CardOverview>(
    context: context,
    builder: (BuildContext dialogContext) => SimpleDialog(
      title: const Text('Which card did this pay?'),
      children: <Widget>[
        for (final CardOverview o in active)
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop(o),
            child: Text(o.card.displayLabel),
          ),
      ],
    ),
  );
  if (chosen == null || !context.mounted) return null;
  final CardOverview overview = chosen;
  return showAppSheet<bool>(
    context: context,
    builder: (_) => CardPaymentSheet(
      overview: overview,
      initialAmount: amount,
      initialAccountId: accountId,
      initialDate: date,
      initialNote: note,
    ),
  );
}

class _CardPaymentSheetState extends State<CardPaymentSheet> {
  static const String _cash = 'cash';

  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _amount;
  final TextEditingController _note = TextEditingController();

  late String? _chosenSource = widget.initialAccountId;
  late DateTime _date = widget.initialDate ?? AppDateUtils.today();
  String? _linkId;
  bool _saving = false;
  String? _error;

  /// The answer about a payment of the same bill already recorded on the
  /// card alone (migration 022): its id when the user says it is this
  /// payment (it is replaced, so the outstanding drops once), or
  /// [_separate] when it is another payment. Unanswered: neither.
  String? _sameAs;
  bool _separate = false;

  // The duplicate check: debits on the paying account around the date.
  List<LedgerEntry>? _nearby;
  bool _checking = false;
  int _lookup = 0;
  Timer? _debounce;

  CreditCard get _card => widget.overview.card;
  CardSummary get _summary => widget.overview.summary;

  @override
  void initState() {
    super.initState();
    final double due = _summary.lastStatement.remaining;
    final double? start = widget.initialAmount ?? (due > 0 ? due : null);
    _amount = TextEditingController(text: start != null ? Formatters.amountInput(start) : '');
    final String? note = widget.initialNote?.trim();
    if (note != null && note.isNotEmpty) _note.text = note;
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshNearby());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  /// Until the user picks, follow the accounts as they load — never fall
  /// back to cash just because they had not arrived yet.
  String _sourceId(List<BankAccountBalance> balances) {
    if (_chosenSource != null) return _chosenSource!;
    for (final BankAccountBalance b in balances) {
      if (b.account.id == _card.paymentAccountId) return b.account.id;
    }
    return balances.isEmpty ? _cash : balances.first.account.id;
  }

  BankAccountBalance? _source(List<BankAccountBalance> balances) {
    final String id = _sourceId(balances);
    for (final BankAccountBalance b in balances) {
      if (b.account.id == id) return b;
    }
    return null;
  }

  double? get _typed {
    final double? value = Validators.parseAmount(_amount.text);
    return value != null && value > 0 ? value : null;
  }

  void _scheduleNearby() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _refreshNearby);
  }

  Future<void> _refreshNearby() async {
    if (!mounted) return;
    final BankAccountBalance? source =
        _source(context.read<BankAccountProvider>().balances);
    final int ticket = ++_lookup;
    if (source == null || _typed == null) {
      setState(() {
        _nearby = null;
        _checking = false;
      });
      return;
    }
    setState(() => _checking = true);
    final List<LedgerEntry>? found = await context
        .read<CreditCardProvider>()
        .nearbyDebits(accountId: source.account.id, date: _date);
    // A later edit superseded this lookup; its answer must not land.
    if (!mounted || ticket != _lookup) return;
    setState(() {
      _nearby = found;
      _checking = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final SettingsProvider settings = context.watch<SettingsProvider>();
    final String currency = settings.currency;
    final List<BankAccountBalance> balances =
        context.watch<BankAccountProvider>().balances;
    final BankAccountBalance? source = _source(balances);
    final double? typed = _typed;

    final List<LedgerEntry> matches = source != null && typed != null
        ? findLinkableDebits(_nearby ?? const <LedgerEntry>[], typed, _date)
        : const <LedgerEntry>[];
    final List<LedgerEntry> asExpense = source != null && typed != null
        ? findExpenseDebits(_nearby ?? const <LedgerEntry>[], typed, _date)
        : const <LedgerEntry>[];
    LedgerEntry? linked;
    for (final LedgerEntry m in matches) {
      if (m.id == _linkId) linked = m;
    }
    // The same bill already recorded — on an account or on the card alone.
    final List<CardEntry> recorded = typed == null
        ? const <CardEntry>[]
        : context.read<CreditCardProvider>().recordedPayments(
              cardId: _card.id,
              amount: linked?.amount ?? typed,
              date: linked?.txnDate ?? _date,
            );
    CardEntry? cardSide;
    for (final CardEntry e in recorded) {
      if (e.source == CardEntrySource.card) {
        cardSide = e;
        break;
      }
    }
    // From an account, a card-side record can become this payment.
    final CardEntry? replaceable =
        source != null && SchemaCapabilities.cardAccounting ? cardSide : null;

    final double due = _summary.lastStatement.remaining;
    final double outstanding = _summary.outstanding;
    final double? paid = linked?.amount ?? typed;
    final double? outstandingAfter =
        paid == null ? null : outstanding - paid;
    final double? sourceAfter = source != null && paid != null && linked == null
        ? source.currentBalance - paid
        : null;

    String money(double v) => Formatters.currency(v, currencyCode: currency);

    return Form(
      key: _formKey,
      child: AppSheet(
        title: 'Pay card bill',
        subtitle: '${_card.displayLabel} · not counted as spending',
        footer: AppButton.submit(
          label: linked != null ? 'Link payment' : 'Record payment',
          busy: _saving,
          busyLabel: 'Saving…',
          onPressed: _saving
              ? null
              : () => _submit(
                    source: source,
                    linked: linked,
                    hasLookalikes: matches.isNotEmpty || asExpense.isNotEmpty,
                    currency: currency,
                    recorded: recorded,
                    replaceable: replaceable,
                  ),
        ),
        children: <Widget>[
          AmountField(
            controller: _amount,
            symbol: settings.currencySymbol,
            enabled: !_saving && linked == null,
            autofocus: false,
            tone: ToneColors.transfer(context),
            onChanged: (_) {
              setState(() => _linkId = null);
              _scheduleNearby();
            },
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: <Widget>[
              if (due > 0)
                AppChoiceChip(
                  label: 'Bill due ${money(due)}',
                  selected: typed != null && (typed * 100).round() == (due * 100).round(),
                  enabled: !_saving,
                  onSelected: () => _setAmount(due),
                ),
              if (outstanding > 0 &&
                  (outstanding * 100).round() != (due * 100).round())
                AppChoiceChip(
                  label: 'Full outstanding ${money(outstanding)}',
                  selected: typed != null &&
                      (typed * 100).round() == (outstanding * 100).round(),
                  enabled: !_saving,
                  onSelected: () => _setAmount(outstanding),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          const FieldLabel('Pay from', isRequired: true),
          DropdownButtonFormField<String>(
            value: _sourceId(balances),
            isExpanded: true,
            decoration: InputDecoration(
              prefixIcon: Icon(
                source == null || source.account.isCash
                    ? Icons.payments_outlined
                    : Icons.account_balance_outlined,
                size: AppSpacing.iconMd,
              ),
            ),
            items: <DropdownMenuItem<String>>[
              ...balances.map((BankAccountBalance b) => DropdownMenuItem<String>(
                    value: b.account.id,
                    child: Text(
                      '${b.account.displayLabel} · ${money(b.currentBalance)}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  )),
              DropdownMenuItem<String>(
                value: _cash,
                // With a cash balance kept, paying in cash is that account.
                child: Text(BankAccount.cashOf(balances.map((BankAccountBalance b) => b.account)) != null
                    ? 'Not tracked — no account balance changes'
                    : 'Cash — no account balance changes'),
              ),
            ],
            onChanged: _saving
                ? null
                : (String? v) {
                    setState(() {
                      _chosenSource = v ?? _cash;
                      _linkId = null;
                    });
                    _refreshNearby();
                  },
          ),
          if (_checking) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Checking the account for this payment…',
              style: theme.textTheme.labelSmall,
            ),
          ],
          if (matches.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppSpacing.md),
            AppNotice(
              icon: Icons.content_copy_rounded,
              tone: ToneColors.warning(context),
              message: '${source?.account.nickname ?? 'This account'} already '
                  'has ${matches.length == 1 ? 'a debit' : 'debits'} of this '
                  'amount nearby. If ${matches.length == 1 ? 'it is' : 'one is'} '
                  'this payment, link it instead of recording it again.',
            ),
            const SizedBox(height: AppSpacing.sm),
            CardList(
              dividerIndent: AppSpacing.md,
              children: matches
                  .map((LedgerEntry m) => AppListRow(
                        dense: true,
                        title: m.title,
                        subtitle:
                            '${Formatters.dayMonthYear(m.txnDate)} · ${money(m.amount)}',
                        trailing: Icon(
                          m.id == _linkId
                              ? Icons.check_circle_rounded
                              : Icons.add_circle_outline_rounded,
                          color: m.id == _linkId
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                        onTap: _saving
                            ? null
                            : () => setState(
                                () => _linkId = _linkId == m.id ? null : m.id),
                      ))
                  .toList(),
            ),
          ],
          if (asExpense.isNotEmpty && linked == null) ...<Widget>[
            const SizedBox(height: AppSpacing.md),
            AppNotice(
              icon: Icons.warning_amber_rounded,
              tone: ToneColors.expense(context),
              message: '${source?.account.nickname ?? 'This account'} has an '
                  'expense of this amount on '
                  '${Formatters.dayMonthYear(asExpense.first.txnDate)} '
                  '("${asExpense.first.title}"). If that was this bill, delete '
                  'that expense first — otherwise the bill counts as spending '
                  'on top of the card purchases.',
            ),
          ],
          if (replaceable != null) ...<Widget>[
            const SizedBox(height: AppSpacing.md),
            AppNotice(
              icon: Icons.content_copy_rounded,
              tone: ToneColors.warning(context),
              message: 'A payment of ${money(replaceable.amount)} on '
                  '${Formatters.dayMonthYear(replaceable.date)} is already recorded on the card. '
                  'If it is this payment, it is recorded from ${source!.account.nickname} '
                  'instead, so the card counts it once.',
            ),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: <Widget>[
                AppChoiceChip(
                  label: 'Same payment — record it from ${source.account.nickname}',
                  selected: _sameAs == replaceable.id,
                  enabled: !_saving,
                  onSelected: () => setState(() {
                    _sameAs = replaceable.id;
                    _separate = false;
                  }),
                ),
                AppChoiceChip(
                  label: 'Separate payment',
                  selected: _separate,
                  enabled: !_saving,
                  onSelected: () => setState(() {
                    _separate = true;
                    _sameAs = null;
                  }),
                ),
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          if (linked == null) ...<Widget>[
            const FieldLabel('Date', isRequired: true),
            DateField(
              date: _date,
              enabled: !_saving,
              onChanged: (DateTime value) {
                setState(() {
                  _date = value;
                  _linkId = null;
                });
                _refreshNearby();
              },
            ),
            const SizedBox(height: AppSpacing.lg),
            const FieldLabel('Note', hint: 'Optional'),
            TextFormField(
              controller: _note,
              enabled: !_saving,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: '${_card.displayLabel} bill payment',
              ),
            ),
          ] else
            AppNotice(
              message: 'No new debit is added: the '
                  '${Formatters.dayMonth(linked.txnDate)} debit becomes this '
                  "card's payment.",
            ),
          if (outstandingAfter != null) ...<Widget>[
            const SizedBox(height: AppSpacing.lg),
            SurfaceCard(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                children: <Widget>[
                  Text('After this payment', style: theme.textTheme.labelSmall),
                  const SizedBox(height: AppSpacing.sm),
                  _previewLine(
                    context,
                    '${_card.cardName} outstanding',
                    outstandingAfter,
                    currency,
                  ),
                  if (source != null && sourceAfter != null) ...<Widget>[
                    const SizedBox(height: AppSpacing.xs),
                    _previewLine(
                      context,
                      source.account.nickname,
                      sourceAfter,
                      currency,
                      negative: sourceAfter < 0,
                    ),
                  ],
                  if (outstandingAfter < 0) ...<Widget>[
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      'That is more than you owe; the card will hold a '
                      '${money(-outstandingAfter)} credit balance.',
                      style: theme.textTheme.bodySmall,
                      textAlign: TextAlign.center,
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
          const SizedBox(height: AppSpacing.md),
          Text(
            source != null
                ? 'Shows as Card bill payment on ${source.account.nickname} '
                    'and as a payment on the card.'
                : "Lowers the card's outstanding; no account balance changes.",
            style: theme.textTheme.labelSmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _previewLine(
    BuildContext context,
    String label,
    double value,
    String currency, {
    bool negative = false,
  }) {
    final ThemeData theme = Theme.of(context);
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            label,
            style: theme.textTheme.bodySmall,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        MoneyText(
          value,
          currency: currency,
          tone: negative ? AmountTone.negative : AmountTone.neutral,
          style: theme.textTheme.titleSmall,
        ),
      ],
    );
  }

  void _setAmount(double value) {
    setState(() {
      _amount.text = Formatters.amountInput(value);
      _linkId = null;
      _sameAs = null;
      _separate = false;
    });
    _refreshNearby();
  }

  /// "from HDFC Salary" or "on the card": where a recorded payment came from.
  String _recordedWhere(CardEntry entry) {
    if (entry.source != CardEntrySource.account) return 'on the card';
    final BankAccount? account = context.read<BankAccountProvider>().byId(entry.accountId);
    return 'from ${account?.nickname ?? 'an account'}';
  }

  Future<void> _submit({
    required BankAccountBalance? source,
    required LedgerEntry? linked,
    required bool hasLookalikes,
    required String currency,
    required List<CardEntry> recorded,
    required CardEntry? replaceable,
  }) async {
    FocusScope.of(context).unfocus();
    setState(() => _error = null);
    final CreditCardProvider cards = context.read<CreditCardProvider>();
    final BankAccountProvider accounts = context.read<BankAccountProvider>();

    // A card-side record of the same bill must be answered: never merged,
    // and never added beside, on a guess.
    if (replaceable != null && _sameAs != replaceable.id && !_separate) {
      setState(() => _error =
          'Say whether the payment already on the card is this one.');
      return;
    }
    final String? replaces = replaceable != null && _sameAs == replaceable.id ? replaceable.id : null;
    // Anything else already recorded for this bill: asked once before another goes in.
    final List<CardEntry> others =
        recorded.where((CardEntry e) => e.id != replaceable?.id).toList();
    if (others.isNotEmpty && replaces == null) {
      final CardEntry first = others.first;
      final bool again = await AppFeedback.confirm(
        context,
        title: 'Already recorded?',
        message: 'This bill payment may already be recorded — '
            '${Formatters.currency(first.amount, currencyCode: currency)} on '
            '${Formatters.dayMonthYear(first.date)} ${_recordedWhere(first)}. '
            'Record another payment?',
        confirmLabel: 'Record anyway',
        destructive: false,
      );
      if (!again || !mounted) return;
    }

    if (linked != null) {
      setState(() => _saving = true);
      final bool ok = await cards.link(entryId: linked.id, cardId: _card.id, replaces: replaces);
      if (!mounted) return;
      if (ok) {
        accounts.invalidate();
        AppFeedback.success(context, 'Payment linked to the card');
        Navigator.of(context).pop(true);
      } else {
        setState(() {
          _saving = false;
          _error = cards.errorMessage ?? 'Could not link the payment.';
        });
      }
      return;
    }

    if (!_formKey.currentState!.validate()) return;
    if (source != null && _checking) {
      setState(() => _error =
          'Still checking the account for this payment. Try again in a moment.');
      return;
    }
    if (hasLookalikes) {
      final bool ok = await AppFeedback.confirm(
        context,
        title: 'Record a separate payment?',
        message: '${source?.account.nickname ?? 'The account'} already has a '
            'debit of ${Formatters.currency(_typed ?? 0, currencyCode: currency)} '
            'near ${Formatters.dayMonthYear(_date)}. Recording another takes '
            'the money out of the account twice. Only continue if you really '
            'paid twice.',
        confirmLabel: 'Record anyway',
        destructive: false,
      );
      if (!ok || !mounted) return;
    }

    setState(() => _saving = true);
    final bool ok = await cards.payBill(
      card: _card,
      account: source?.account,
      amount: _typed,
      date: _date,
      note: _note.text,
      currencyCode: currency,
      replaces: replaces,
    );
    if (!mounted) return;
    if (ok) {
      accounts.invalidate();
      AppFeedback.success(context, 'Payment recorded');
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _saving = false;
        _error = cards.errorMessage ?? 'Could not record the payment.';
      });
    }
  }
}
