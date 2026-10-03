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
  const CardPaymentSheet({super.key, required this.overview});

  final CardOverview overview;

  @override
  State<CardPaymentSheet> createState() => _CardPaymentSheetState();
}

class _CardPaymentSheetState extends State<CardPaymentSheet> {
  static const String _cash = 'cash';

  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _amount;
  final TextEditingController _note = TextEditingController();

  String? _chosenSource;
  DateTime _date = AppDateUtils.today();
  String? _linkId;
  bool _saving = false;
  String? _error;

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
    _amount = TextEditingController(text: due > 0 ? _trim(due) : '');
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshNearby());
  }

  static String _trim(double value) {
    final String text = value.toStringAsFixed(2);
    return text.endsWith('.00') ? text.substring(0, text.length - 3) : text;
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
                source == null
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
              const DropdownMenuItem<String>(
                value: _cash,
                child: Text('Cash — no account balance changes'),
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
      _amount.text = _trim(value);
      _linkId = null;
    });
    _refreshNearby();
  }

  Future<void> _submit({
    required BankAccountBalance? source,
    required LedgerEntry? linked,
    required bool hasLookalikes,
    required String currency,
  }) async {
    FocusScope.of(context).unfocus();
    setState(() => _error = null);
    final CreditCardProvider cards = context.read<CreditCardProvider>();
    final BankAccountProvider accounts = context.read<BankAccountProvider>();

    if (linked != null) {
      setState(() => _saving = true);
      final bool ok = await cards.link(entryId: linked.id, cardId: _card.id);
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
