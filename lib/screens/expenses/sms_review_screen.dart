import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/validators.dart';
import '../../models/bank_account.dart';
import '../../models/expense.dart';
import '../../models/expense_category.dart';
import '../../providers/auth_provider.dart';
import '../../providers/bank_account_provider.dart';
import '../../providers/category_provider.dart';
import '../../providers/expense_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/sms/bank_sms.dart';
import '../../services/sms/sms_account_matcher.dart';
import '../../services/sms/sms_expense_draft.dart';
import '../../widgets/category_avatar.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/app_feedback.dart';
import '../../widgets/common/app_fields.dart';
import '../../widgets/common/money_text.dart';
import '../../widgets/common/state_views.dart';
import '../../widgets/common/surface_card.dart';

/// Check what the message said, before anything is saved.
///
/// Nothing has been written when this screen opens and nothing is written
/// until the user presses the button at the bottom. Every extracted value is
/// an ordinary editable control rather than a read-only preview: a parse is a
/// draft, and the fastest way to fix a misread payee is to type over it.
///
/// Pops `true` when the expense was created.
class SmsReviewScreen extends StatefulWidget {
  const SmsReviewScreen({super.key, required this.sms, required this.draft});

  /// What the parser read. Used for the fields the user cannot change — the
  /// reference, the bank's own balance — and for saying what was not found.
  final ParsedBankSms sms;

  final SmsExpenseDraft draft;

  @override
  State<SmsReviewScreen> createState() => _SmsReviewScreenState();
}

class _SmsReviewScreenState extends State<SmsReviewScreen> {
  late final TextEditingController _amount;
  late final TextEditingController _merchant;
  late final TextEditingController _description;

  late DateTime _date;
  String? _categoryId;
  String? _bankAccountId;
  late SmsCategorySource _categorySource;
  String? _categoryReason;

  bool _saving = false;
  bool _submitted = false;
  String? _error;

  /// An expense already on file that looks like this one, if any.
  Expense? _duplicate;
  bool _checkingDuplicate = true;

  /// Set once the user has seen a duplicate warning and pressed on anyway.
  bool _duplicateAccepted = false;

  Timer? _recheck;

  @override
  void initState() {
    super.initState();
    final SmsExpenseDraft draft = widget.draft;

    _amount = TextEditingController(text: _plain(draft.amount));
    _merchant = TextEditingController(text: draft.merchant ?? '');
    _description = TextEditingController(text: _defaultDescription());
    _date = draft.date;
    _categoryId = draft.categoryId;
    _bankAccountId = draft.bankAccountId;
    _categorySource = draft.categorySource;
    _categoryReason = draft.categoryReason;

    _amount.addListener(_scheduleDuplicateCheck);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkDuplicate());
  }

  /// A message that named no payee still deserves a readable row in the
  /// list, so the bank's name stands in. It is a normal editable default,
  /// not a value the parser claims to have read as a description.
  String _defaultDescription() {
    if (widget.draft.merchant != null) return '';
    return widget.sms.bankName ?? '';
  }

  @override
  void dispose() {
    _recheck?.cancel();
    _amount.removeListener(_scheduleDuplicateCheck);
    _amount.dispose();
    _merchant.dispose();
    _description.dispose();
    super.dispose();
  }

  static String _plain(double value) {
    final String text = value.toStringAsFixed(2);
    return text.endsWith('.00') ? text.substring(0, text.length - 3) : text;
  }

  // ---------------------------------------------------------------------
  // Duplicate protection
  // ---------------------------------------------------------------------

  void _scheduleDuplicateCheck() {
    _recheck?.cancel();
    _recheck = Timer(const Duration(milliseconds: 450), _checkDuplicate);
  }

  /// Looks for an expense that already records this transaction.
  ///
  /// Re-run whenever the amount, date or account changes, because the
  /// fallback check is defined by exactly those three and a warning about
  /// values the user has since edited would be worse than none.
  Future<void> _checkDuplicate() async {
    final double? amount = Validators.parseAmount(_amount.text);
    if (amount == null) {
      if (mounted) {
        setState(() {
          _duplicate = null;
          _checkingDuplicate = false;
        });
      }
      return;
    }

    if (mounted) setState(() => _checkingDuplicate = true);

    final Expense? found =
        await context.read<ExpenseProvider>().findPossibleDuplicate(
              amount: amount,
              date: _date,
              reference: widget.draft.reference,
              bankAccountId: _bankAccountId,
            );

    if (!mounted) return;
    setState(() {
      _duplicate = found;
      _checkingDuplicate = false;
      if (found == null) _duplicateAccepted = false;
    });
  }

  // ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final SettingsProvider settings = context.watch<SettingsProvider>();
    final List<ExpenseCategory> categories =
        context.watch<CategoryProvider>().categories;
    final BankAccountProvider accounts = context.watch<BankAccountProvider>();

    final bool categoryMissing = _submitted && _categoryId == null;
    final bool warnDuplicate = _duplicate != null && !_duplicateAccepted;

    return Scaffold(
      appBar: AppBar(title: const Text('Review transaction')),
      bottomNavigationBar: _ConfirmBar(
        confirmLabel: warnDuplicate ? 'Add anyway' : 'Add expense',
        busy: _saving,
        onConfirm: _save,
        onCancel: _saving ? null : () => Navigator.of(context).pop(false),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.page,
          AppSpacing.md,
          AppSpacing.page,
          AppSpacing.xl,
        ),
        children: <Widget>[
          _ParseSummary(sms: widget.sms),

          if (_duplicate != null) ...<Widget>[
            const SizedBox(height: AppSpacing.md),
            _DuplicateWarning(
              existing: _duplicate!,
              byReference: widget.draft.reference != null,
              currency: settings.currency,
            ),
          ],

          const SizedBox(height: AppSpacing.lg),

          // ---------------------------------------------------------------
          // Amount
          // ---------------------------------------------------------------
          const FieldLabel('Amount', isRequired: true),
          AmountField(
            controller: _amount,
            symbol: settings.currencySymbol,
            enabled: !_saving,
            tone: ToneColors.expense(context),
          ),
          const SizedBox(height: AppSpacing.xl),

          // ---------------------------------------------------------------
          // Bank account — the last-4 is shown on every chip, so choosing the
          // account is how the account number is corrected
          // ---------------------------------------------------------------
          FieldLabel(
            'Paid from',
            isRequired: true,
            hint: _bankAccountId == null ? 'No balance affected' : null,
          ),
          if (!accounts.available)
            const AppNotice(
              message: 'Bank accounts are not set up, so this is recorded as '
                  'cash and no balance changes.',
            )
          else ...<Widget>[
            _AccountMatchNotice(
              match: widget.draft.accountMatch,
              sms: widget.sms,
              overridden: _bankAccountId != widget.draft.bankAccountId,
            ),
            const SizedBox(height: AppSpacing.sm),
            _AccountPicker(
              accounts: accounts.accounts,
              selectedAccountId: _bankAccountId,
              enabled: !_saving,
              onSelected: (String? id) {
                setState(() => _bankAccountId = id);
                _checkDuplicate();
              },
            ),
          ],
          const SizedBox(height: AppSpacing.lg),

          // ---------------------------------------------------------------
          // Merchant
          // ---------------------------------------------------------------
          const FieldLabel('Merchant'),
          TextField(
            controller: _merchant,
            enabled: !_saving,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              hintText: 'Who you paid',
              prefixIcon:
                  Icon(Icons.storefront_outlined, size: AppSpacing.iconMd),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),

          // ---------------------------------------------------------------
          // Category
          // ---------------------------------------------------------------
          FieldLabel(
            'Category',
            isRequired: true,
            hint: categoryMissing ? 'Pick one' : _categoryHint(),
          ),
          if (categories.isEmpty)
            const AppNotice(
              message: 'No categories yet. Add one from Settings › Categories '
                  'before importing a message.',
            )
          else
            Container(
              padding: categoryMissing
                  ? const EdgeInsets.all(AppSpacing.sm)
                  : EdgeInsets.zero,
              decoration: categoryMissing
                  ? BoxDecoration(
                      borderRadius:
                          BorderRadius.circular(AppSpacing.radiusMd),
                      border: Border.all(color: theme.colorScheme.error),
                    )
                  : null,
              child: Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: categories.map((ExpenseCategory category) {
                  return AppChoiceChip(
                    label: category.name,
                    selected: category.id == _categoryId,
                    enabled: !_saving,
                    tone: AppColors.readableOn(
                      AppColors.fromHex(category.color),
                      theme.brightness,
                    ),
                    avatar: CategoryAvatar(
                      icon: category.icon,
                      color: category.color,
                      size: 20,
                    ),
                    onSelected: () => setState(() {
                      _categoryId = category.id;
                      _categorySource = SmsCategorySource.user;
                      _categoryReason = null;
                      _submitted = false;
                    }),
                  );
                }).toList(),
              ),
            ),
          const SizedBox(height: AppSpacing.lg),

          // ---------------------------------------------------------------
          // Date
          // ---------------------------------------------------------------
          FieldLabel(
            'Date',
            isRequired: true,
            hint: widget.sms.date == null ? 'Not in the message' : null,
          ),
          DateField(
            date: _date,
            enabled: !_saving,
            onChanged: (DateTime value) {
              setState(() => _date = value);
              _checkDuplicate();
            },
          ),
          const SizedBox(height: AppSpacing.lg),

          // ---------------------------------------------------------------
          // Description and reference
          // ---------------------------------------------------------------
          const FieldLabel('Description', hint: 'Optional'),
          TextField(
            controller: _description,
            enabled: !_saving,
            textCapitalization: TextCapitalization.sentences,
            maxLines: 2,
            decoration: const InputDecoration(
              hintText: 'What this was for',
              alignLabelWithHint: true,
              prefixIcon:
                  Icon(Icons.short_text_rounded, size: AppSpacing.iconMd),
            ),
          ),

          if (widget.draft.reference != null) ...<Widget>[
            const SizedBox(height: AppSpacing.md),
            _ReferenceRow(reference: widget.draft.reference!),
          ],

          if (widget.sms.availableBalance != null) ...<Widget>[
            const SizedBox(height: AppSpacing.md),
            _BalanceNote(
              balance: widget.sms.availableBalance!,
              currency: settings.currency,
            ),
          ],

          if (_error != null) ...<Widget>[
            const SizedBox(height: AppSpacing.lg),
            InlineError(message: _error!),
          ],

          if (_checkingDuplicate) ...<Widget>[
            const SizedBox(height: AppSpacing.md),
            Text(
              'Checking for a matching expense…',
              style: theme.textTheme.labelSmall,
            ),
          ],
        ],
      ),
    );
  }

  String? _categoryHint() => switch (_categorySource) {
        SmsCategorySource.keyword =>
          _categoryReason == null ? null : 'Suggested, $_categoryReason',
        SmsCategorySource.assistant => 'Suggested by the assistant',
        SmsCategorySource.fallback => 'Not recognised — change if you can',
        SmsCategorySource.user || SmsCategorySource.none => null,
      };

  // ---------------------------------------------------------------------

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _error = null;
      _submitted = true;
    });

    // A warning the user has not acknowledged turns the first press into an
    // acknowledgement rather than a save, so a duplicate can never be
    // created by the same tap that revealed the warning.
    if (_duplicate != null && !_duplicateAccepted) {
      setState(() => _duplicateAccepted = true);
      return;
    }

    final double? amount = Validators.parseAmount(_amount.text);
    if (amount == null) {
      setState(() => _error = 'Enter the amount that was spent.');
      return;
    }
    if (_categoryId == null) {
      setState(() => _error = 'Choose a category for this expense.');
      return;
    }

    final String? userId = context.read<AuthProvider>().userId;
    if (userId == null) {
      setState(() => _error = 'You are signed out. Please sign in again.');
      return;
    }

    setState(() => _saving = true);

    final String? reference = widget.draft.reference;
    final ExpenseProvider provider = context.read<ExpenseProvider>();

    // An ordinary expense, built and saved through exactly the path the Add
    // Expense form uses. The ledger debit, the balance and the category
    // totals all follow from that, and an imported expense is
    // indistinguishable from a typed one once stored.
    final Expense expense = Expense(
      id: '',
      userId: userId,
      amount: amount,
      expenseDate: _date,
      categoryId: _categoryId,
      bankAccountId: _bankAccountId,
      merchant: _merchant.text,
      description: _description.text,
      notes: reference == null ? null : SmsReferenceNote.forReference(reference),
    );

    final bool ok = await provider.create(expense);
    if (!mounted) return;

    if (ok) {
      AppFeedback.success(context, 'Expense added');
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _saving = false;
        _error = provider.errorMessage ?? 'Could not save the expense.';
      });
    }
  }
}

// -------------------------------------------------------------------------

/// One line on how the parse went, so the user knows whether to skim or check.
class _ParseSummary extends StatelessWidget {
  const _ParseSummary({required this.sms});

  final ParsedBankSms sms;

  @override
  Widget build(BuildContext context) {
    final List<String> missing = <String>[
      if (sms.counterparty == null) 'payee',
      if (sms.date == null) 'date',
    ];

    if (missing.isEmpty) {
      return AppNotice(
        icon: Icons.check_circle_outline_rounded,
        tone: ToneColors.income(context),
        message: 'Read the amount, account, payee and date. Nothing is saved '
            'until you confirm.',
      );
    }

    return AppNotice(
      icon: Icons.fact_check_outlined,
      tone: ToneColors.warning(context),
      message: missing.length == 1
          ? 'The message did not state a ${missing.first}. Check it below '
              'before adding.'
          : 'The message did not state a ${missing.join(' or a ')}. Check '
              'them below before adding.',
    );
  }
}

/// Says whether the bank account was identified, and how.
class _AccountMatchNotice extends StatelessWidget {
  const _AccountMatchNotice({
    required this.match,
    required this.sms,
    required this.overridden,
  });

  final SmsAccountMatch? match;
  final ParsedBankSms sms;

  /// True once the user has picked something other than the matched account.
  final bool overridden;

  @override
  Widget build(BuildContext context) {
    if (overridden) {
      return const AppNotice(
        icon: Icons.edit_outlined,
        message: 'Using the account you picked.',
      );
    }

    final SmsAccountMatch? found = match;
    if (found == null) {
      final String named = <String?>[sms.bankName, sms.last4]
              .whereType<String>()
              .isEmpty
          ? 'The message'
          : '${sms.bankName ?? 'The bank'}'
              '${sms.last4 == null ? '' : ' ••••${sms.last4}'}';

      return AppNotice(
        icon: Icons.help_outline_rounded,
        tone: ToneColors.warning(context),
        message: '$named is not one of your accounts. '
            'Pick the right one below — none will be created for you.',
      );
    }

    return AppNotice(
      icon: found.strength == SmsMatchStrength.exact
          ? Icons.verified_outlined
          : Icons.info_outline_rounded,
      tone: found.strength == SmsMatchStrength.exact
          ? ToneColors.income(context)
          : null,
      message: 'Matched ${found.account.displayLabel} by ${found.reason}.',
    );
  }
}

/// Cash plus every bank account, each showing its own last four digits.
class _AccountPicker extends StatelessWidget {
  const _AccountPicker({
    required this.accounts,
    required this.selectedAccountId,
    required this.onSelected,
    required this.enabled,
  });

  final List<BankAccount> accounts;
  final String? selectedAccountId;
  final ValueChanged<String?> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (accounts.isEmpty) {
      return const AppNotice(
        message: 'No bank accounts yet. This will be recorded as cash, which '
            'leaves every balance untouched.',
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
            label: account.displayLabel,
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

/// Warns that this transaction may already be recorded.
class _DuplicateWarning extends StatelessWidget {
  const _DuplicateWarning({
    required this.existing,
    required this.byReference,
    required this.currency,
  });

  final Expense existing;

  /// True when the transaction id matched, which is proof rather than a
  /// resemblance and is worth saying differently.
  final bool byReference;

  final String currency;

  @override
  Widget build(BuildContext context) {
    final String amount =
        Formatters.currency(existing.amount, currencyCode: currency);
    final String when = Formatters.dayMonthYear(existing.expenseDate);

    return AppNotice(
      icon: Icons.content_copy_outlined,
      tone: ToneColors.warning(context),
      message: byReference
          ? 'This message has already been added: $amount · '
              '${existing.title} on $when.'
          : 'An expense of $amount from the same account on $when is already '
              'recorded. Add it again only if you really paid twice.',
    );
  }
}

/// The transaction id, shown because it is saved with the expense and is what
/// stops the same message being imported twice.
class _ReferenceRow extends StatelessWidget {
  const _ReferenceRow({required this.reference});

  final String reference;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return SurfaceCard(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.tag_rounded,
            size: AppSpacing.iconSm,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text('Reference', style: theme.textTheme.labelMedium),
                const SizedBox(height: AppSpacing.xxs),
                Text(
                  reference,
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const AppBadge(label: 'Saved in notes'),
        ],
      ),
    );
  }
}

/// The balance the bank quoted, for reassurance that the right message was
/// pasted. Never saved: balances are derived from the ledger, and storing a
/// figure from an SMS would give the app a second, conflicting source.
class _BalanceNote extends StatelessWidget {
  const _BalanceNote({required this.balance, required this.currency});

  final double balance;
  final String currency;

  @override
  Widget build(BuildContext context) {
    return AppNotice(
      icon: Icons.account_balance_wallet_outlined,
      message: 'Your bank quoted a balance of '
          '${Formatters.currency(balance, currencyCode: currency)} in this '
          'message. It is shown for checking only and is not saved.',
    );
  }
}

/// Pinned Cancel / Add expense pair.
class _ConfirmBar extends StatelessWidget {
  const _ConfirmBar({
    required this.confirmLabel,
    required this.busy,
    required this.onConfirm,
    required this.onCancel,
  });

  final String confirmLabel;
  final bool busy;
  final VoidCallback onConfirm;
  final VoidCallback? onCancel;

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
      child: AppButtonRow(
        confirmLabel: confirmLabel,
        onConfirm: onConfirm,
        onCancel: onCancel,
        busy: busy,
      ),
    );
  }
}
