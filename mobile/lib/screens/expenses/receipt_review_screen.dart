import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/utils/date_utils.dart';
import '../../core/utils/validators.dart';
import '../../models/expense_category.dart';
import '../../models/expense_prefill.dart';
import '../../models/payment_method.dart';
import '../../providers/category_provider.dart';
import '../../providers/payment_method_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/receipt/receipt_result.dart';
import '../../services/receipt/receipt_prefill.dart';
import '../../widgets/category_avatar.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/app_fields.dart';
import '../../widgets/common/money_text.dart';
import '../../widgets/common/surface_card.dart';

/// Check what the scan read, before anything is saved.
///
/// Every extracted field is a normal editable control, not a read-only
/// preview with an edit affordance — a scan is a draft, and the fastest way to
/// fix a misread total is to type over it. Fields the extractor was unsure of
/// are marked, so the user knows where to look instead of proof-reading all
/// of them.
///
/// Pops an [ExpensePrefill]. Nothing is written here; the caller opens the
/// ordinary Add Expense form on the result.
class ReceiptReviewScreen extends StatefulWidget {
  const ReceiptReviewScreen({super.key, required this.result});

  final ReceiptResult result;

  @override
  State<ReceiptReviewScreen> createState() => _ReceiptReviewScreenState();
}

class _ReceiptReviewScreenState extends State<ReceiptReviewScreen> {
  static const ReceiptPrefill _prefillBuilder = ReceiptPrefill();

  late final TextEditingController _amount;
  late final TextEditingController _merchant;
  late final TextEditingController _description;

  late DateTime _date;
  String? _categoryId;
  String? _paymentMethodId;

  /// Why the category was pre-selected, shown once so the suggestion is
  /// transparent rather than magic.
  String? _categoryReason;

  bool _amountTouched = false;
  bool _seeded = false;

  @override
  void initState() {
    super.initState();
    // Controllers must exist before the first build; the values that depend
    // on the category and payment-method lists arrive in [_seedOnce], which
    // needs a context to read providers from.
    _amount = TextEditingController();
    _merchant = TextEditingController();
    _description = TextEditingController();
    _date = widget.result.date.value ?? AppDateUtils.today();
  }

  /// Fills the form from the scan, once, using the same mapping the tests
  /// exercise.
  void _seedOnce() {
    if (_seeded) return;
    _seeded = true;

    final List<ExpenseCategory> categories =
        context.read<CategoryProvider>().categories;
    final ExpensePrefill prefill = _prefillBuilder.build(
      result: widget.result,
      categories: categories,
      paymentMethods: context.read<PaymentMethodProvider>().methods,
    );

    _amount.text = prefill.amount == null ? '' : _plain(prefill.amount!);
    _merchant.text = prefill.merchant ?? '';
    _description.text = prefill.description ?? '';
    _date = prefill.date ?? AppDateUtils.today();
    _categoryId = prefill.categoryId;
    _paymentMethodId = prefill.paymentMethodId;
    _categoryReason = _prefillBuilder.categoryReason(
      result: widget.result,
      categories: categories,
    );
  }

  static String _plain(double value) {
    final String text = value.toStringAsFixed(2);
    return text.endsWith('.00') ? text.substring(0, text.length - 3) : text;
  }

  @override
  void dispose() {
    _amount.dispose();
    _merchant.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _seedOnce();

    final ThemeData theme = Theme.of(context);
    final SettingsProvider settings = context.watch<SettingsProvider>();
    final List<ExpenseCategory> categories =
        context.watch<CategoryProvider>().categories;
    final List<PaymentMethod> methods =
        context.watch<PaymentMethodProvider>().methods;

    final ReceiptResult result = widget.result;
    final bool amountReady = Validators.parseAmount(_amount.text) != null;

    return Scaffold(
      appBar: AppBar(title: const Text('Check the receipt')),
      bottomNavigationBar: _ContinueBar(
        enabled: amountReady,
        onPressed: _continue,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.page,
          AppSpacing.md,
          AppSpacing.page,
          AppSpacing.xl,
        ),
        children: <Widget>[
          _ScanSummary(result: result),
          const SizedBox(height: AppSpacing.lg),

          // -----------------------------------------------------------
          // Amount — always checked, because it is what gets saved
          // -----------------------------------------------------------
          Row(
            children: <Widget>[
              const Expanded(child: FieldLabel('Amount', isRequired: true)),
              _ConfidencePill(confidence: result.total.confidence),
            ],
          ),
          AmountField(
            controller: _amount,
            symbol: settings.currencySymbol,
            autofocus: !result.hasUsableTotal,
            tone: ToneColors.expense(context),
            onChanged: (_) => setState(() => _amountTouched = true),
          ),
          if (!amountReady && _amountTouched) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Enter the amount you paid.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.xl),

          // -----------------------------------------------------------
          // Merchant and date
          // -----------------------------------------------------------
          Row(
            children: <Widget>[
              const Expanded(child: FieldLabel('Merchant')),
              _ConfidencePill(confidence: result.merchant.confidence),
            ],
          ),
          TextField(
            controller: _merchant,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              hintText: 'Who you paid',
              prefixIcon: Icon(
                Icons.storefront_outlined,
                size: AppSpacing.iconMd,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),

          Row(
            children: <Widget>[
              const Expanded(child: FieldLabel('Date', isRequired: true)),
              _ConfidencePill(confidence: result.date.confidence),
            ],
          ),
          DateField(
            date: _date,
            onChanged: (DateTime value) => setState(() => _date = value),
          ),
          const SizedBox(height: AppSpacing.lg),

          // -----------------------------------------------------------
          // Category — suggested where possible, never imposed
          // -----------------------------------------------------------
          FieldLabel(
            'Category',
            hint: _categoryReason == null ? null : 'Suggested, $_categoryReason',
          ),
          if (categories.isEmpty)
            const AppNotice(
              message: 'No categories yet. You can pick one on the next step.',
            )
          else
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: categories.map((ExpenseCategory category) {
                final bool selected = category.id == _categoryId;
                return AppChoiceChip(
                  label: category.name,
                  selected: selected,
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
                    _categoryId = selected ? null : category.id;
                    _categoryReason = null;
                  }),
                );
              }).toList(),
            ),
          const SizedBox(height: AppSpacing.lg),

          // -----------------------------------------------------------
          // Description, prefilled from the items the scan could read
          // -----------------------------------------------------------
          const FieldLabel('Description', hint: 'Optional'),
          TextField(
            controller: _description,
            textCapitalization: TextCapitalization.sentences,
            maxLines: 2,
            decoration: const InputDecoration(
              hintText: 'What this was for',
              alignLabelWithHint: true,
              prefixIcon: Icon(Icons.short_text_rounded, size: AppSpacing.iconMd),
            ),
          ),

          if (methods.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppSpacing.lg),
            const FieldLabel('Payment method', hint: 'Optional'),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: methods.map((PaymentMethod method) {
                final bool selected = method.id == _paymentMethodId;
                return AppChoiceChip(
                  label: method.name,
                  selected: selected,
                  onSelected: () => setState(
                    () => _paymentMethodId = selected ? null : method.id,
                  ),
                );
              }).toList(),
            ),
          ],

          if (result.lineItems.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppSpacing.xl),
            SectionHeader(
              title: 'Items read',
              caption: '${result.lineItems.length} lines',
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            ),
            _ItemsCard(
              items: result.lineItems,
              currencyCode: settings.currency,
            ),
          ],
        ],
      ),
    );
  }

  void _continue() {
    final double? amount = Validators.parseAmount(_amount.text);
    if (amount == null) {
      setState(() => _amountTouched = true);
      return;
    }

    Navigator.of(context).pop(
      ExpensePrefill(
        amount: amount,
        merchant: _blankToNull(_merchant.text),
        date: _date,
        description: _blankToNull(_description.text),
        categoryId: _categoryId,
        paymentMethodId: _paymentMethodId,
        source: ExpensePrefillSource.receiptScan,
      ),
    );
  }

  static String? _blankToNull(String value) {
    final String trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

/// One line saying how the scan went, so the user knows whether to skim or to
/// check carefully.
class _ScanSummary extends StatelessWidget {
  const _ScanSummary({required this.result});

  final ReceiptResult result;

  @override
  Widget build(BuildContext context) {
    final List<String> unsure = result.fieldsToVerify;

    if (unsure.isEmpty) {
      return AppNotice(
        icon: Icons.check_circle_outline_rounded,
        tone: ToneColors.income(context),
        message: 'Read the amount, merchant and date. Check them and '
            'continue.',
      );
    }

    return AppNotice(
      icon: Icons.fact_check_outlined,
      tone: ToneColors.warning(context),
      message: unsure.length == 1
          ? 'Check the ${unsure.first} — the scan was not sure about it.'
          : 'Check the ${_join(unsure)} — the scan was not sure about them.',
    );
  }

  static String _join(List<String> words) {
    if (words.length == 2) return '${words[0]} and ${words[1]}';
    return '${words.sublist(0, words.length - 1).join(', ')} and ${words.last}';
  }
}

/// Marks a field the extractor guessed at. Absent when it is confident, so
/// the screen is not covered in badges.
class _ConfidencePill extends StatelessWidget {
  const _ConfidencePill({required this.confidence});

  final ReceiptConfidence confidence;

  @override
  Widget build(BuildContext context) {
    if (confidence == ReceiptConfidence.high) return const SizedBox.shrink();

    return AppBadge(
      label: confidence.label,
      icon: confidence == ReceiptConfidence.none
          ? Icons.remove_circle_outline_rounded
          : Icons.help_outline_rounded,
      tone: confidence == ReceiptConfidence.none
          ? null
          : ToneColors.warning(context),
    );
  }
}

/// The purchased lines, when the receipt listed them legibly.
///
/// Read-only on purpose: items are context for the person checking the total,
/// not data the app stores. Anything worth keeping goes in the description,
/// which is editable.
class _ItemsCard extends StatelessWidget {
  const _ItemsCard({required this.items, required this.currencyCode});

  final List<ReceiptLineItem> items;
  final String currencyCode;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return SurfaceCard(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      child: Column(
        children: <Widget>[
          for (final ReceiptLineItem item in items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      item.display,
                      style: theme.textTheme.bodyMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  MoneyText(
                    item.amount,
                    currency: currencyCode,
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Pinned primary action, matching the Add Expense save bar.
class _ContinueBar extends StatelessWidget {
  const _ContinueBar({required this.enabled, required this.onPressed});

  final bool enabled;
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
        label: 'Continue',
        icon: Icons.arrow_forward_rounded,
        onPressed: enabled ? onPressed : null,
      ),
    );
  }
}
