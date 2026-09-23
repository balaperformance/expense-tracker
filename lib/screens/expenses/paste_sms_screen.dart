import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/utils/date_utils.dart';
import '../../models/bank_account.dart';
import '../../models/expense_category.dart';
import '../../providers/bank_account_provider.dart';
import '../../providers/category_provider.dart';
import '../../services/ai/ai_chat_service.dart';
import '../../services/sms/bank_sms.dart';
import '../../services/sms/bank_sms_parser.dart';
import '../../services/sms/sms_category_assistant.dart';
import '../../services/sms/sms_expense_draft.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/app_fields.dart';
import '../../widgets/common/money_text.dart';
import '../../widgets/common/surface_card.dart';
import 'sms_review_screen.dart';

/// Paste a bank alert and turn it into an expense.
///
/// The parsing is deterministic and runs on this device; the AI is consulted
/// only when the on-device rules cannot name a category, and only ever sees
/// the payee. The message itself is never uploaded, never logged and never
/// stored — it lives in a text controller that is cleared when this screen
/// closes.
///
/// Pops `true` when an expense was created, so the caller knows to refresh.
class PasteSmsScreen extends StatefulWidget {
  const PasteSmsScreen({super.key});

  @override
  State<PasteSmsScreen> createState() => _PasteSmsScreenState();
}

class _PasteSmsScreenState extends State<PasteSmsScreen> {
  static const BankSmsParser _parser = BankSmsParser();
  static const SmsDraftBuilder _builder = SmsDraftBuilder();

  final TextEditingController _sms = TextEditingController();

  bool _busy = false;

  /// What went wrong with the last attempt, in the user's terms. Cleared as
  /// soon as they change the text, so a stale complaint never sits under a
  /// message they have already fixed.
  String? _problem;

  @override
  void initState() {
    super.initState();
    _sms.addListener(_onChanged);
  }

  @override
  void dispose() {
    _sms.removeListener(_onChanged);
    // Cleared before disposal so the message text does not sit in a detached
    // controller waiting to be collected.
    _sms.clear();
    _sms.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (_problem != null) setState(() => _problem = null);
  }

  Future<void> _pasteFromClipboard() async {
    final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    final String? text = data?.text;
    if (!mounted) return;

    if (text == null || text.trim().isEmpty) {
      setState(() => _problem = 'There is nothing to paste right now.');
      return;
    }
    setState(() {
      _sms.text = text.length > BankSmsParser.maxInputChars
          ? text.substring(0, BankSmsParser.maxInputChars)
          : text;
      _problem = null;
    });
  }

  void _clear() {
    setState(() {
      _sms.clear();
      _problem = null;
    });
  }

  Future<void> _parse() async {
    FocusScope.of(context).unfocus();

    final ParsedBankSms sms = _parser.parse(_sms.text);

    if (!sms.isUsable) {
      setState(
        () => _problem = 'That does not look like a bank transaction message. '
            'Paste the whole alert, including the amount.',
      );
      return;
    }

    // Credits are real, and pretending one is spending would corrupt every
    // total in the app. Better to say so than to file it wrongly.
    if (sms.isCredit) {
      setState(
        () => _problem = 'That message is money received, not money spent. '
            'Add it from the Income tab instead.',
      );
      return;
    }

    setState(() {
      _busy = true;
      _problem = null;
    });

    final List<ExpenseCategory> categories =
        context.read<CategoryProvider>().categories;
    final List<BankAccount> accounts =
        context.read<BankAccountProvider>().accounts;

    SmsExpenseDraft draft = _builder.build(
      sms: sms,
      accounts: accounts,
      categories: categories,
      today: AppDateUtils.today(),
    );

    draft = await SmsCategoryAssistant(context.read<AiChatService>())
        .refine(draft: draft, categories: categories);

    if (!mounted) return;
    setState(() => _busy = false);

    final bool? saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => SmsReviewScreen(sms: sms, draft: draft),
      ),
    );

    if (saved == true && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool hasText = _sms.text.trim().isNotEmpty;

    return Scaffold(
      appBar: AppBar(title: const Text('Paste bank SMS')),
      bottomNavigationBar: _ParseBar(
        enabled: hasText && !_busy,
        busy: _busy,
        onPressed: _parse,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.page,
          AppSpacing.md,
          AppSpacing.page,
          AppSpacing.xl,
        ),
        children: <Widget>[
          const FieldLabel('Message', isRequired: true),
          TextField(
            controller: _sms,
            enabled: !_busy,
            autofocus: true,
            maxLines: 6,
            minLines: 4,
            maxLength: BankSmsParser.maxInputChars,
            textCapitalization: TextCapitalization.none,
            keyboardType: TextInputType.multiline,
            decoration: const InputDecoration(
              hintText: 'Paste the transaction alert from your bank',
              alignLabelWithHint: true,
              counterText: '',
            ),
          ),
          const SizedBox(height: AppSpacing.sm),

          Row(
            children: <Widget>[
              AppButton(
                label: 'Paste',
                icon: Icons.content_paste_rounded,
                size: AppButtonSize.small,
                variant: AppButtonVariant.tonal,
                onPressed: _busy ? null : _pasteFromClipboard,
              ),
              const SizedBox(width: AppSpacing.sm),
              AppButton(
                label: 'Clear',
                icon: Icons.backspace_outlined,
                size: AppButtonSize.small,
                variant: AppButtonVariant.ghost,
                onPressed: (_busy || !hasText) ? null : _clear,
              ),
            ],
          ),

          if (_problem != null) ...<Widget>[
            const SizedBox(height: AppSpacing.lg),
            AppNotice(
              icon: Icons.error_outline_rounded,
              tone: theme.colorScheme.error,
              message: _problem!,
            ),
          ],

          const SizedBox(height: AppSpacing.xl),
          const _ExampleCard(),

          const SizedBox(height: AppSpacing.lg),
          const AppNotice(
            icon: Icons.lock_outline_rounded,
            message: 'The message is read on this device and is not saved. '
                'If a category cannot be worked out here, only the payee name '
                'is sent to the assistant — never the amount, the account or '
                'the message itself.',
          ),
        ],
      ),
    );
  }
}

/// What a message that works looks like.
///
/// Shown as a real example rather than a description of the format, because
/// the useful question is "will mine work?" and a sample answers it at a
/// glance.
class _ExampleCard extends StatelessWidget {
  const _ExampleCard();

  static const String _sample = 'Sent Rs.2900.00\n'
      'From HDFC Bank A/C *6459\n'
      'To CHENNAI KEY MAKERS\n'
      'On 19/09/26';

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return SurfaceCard(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                Icons.lightbulb_outline_rounded,
                size: AppSpacing.iconSm,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: AppSpacing.sm),
              Text('Messages like this work', style: theme.textTheme.titleSmall),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: ToneColors.wash(context, theme.colorScheme.primary),
              borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
            ),
            child: Text(
              _sample,
              style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            'Debit alerts from most banks are understood, with or without a '
            'transaction id, a balance or a date.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// Pinned primary action, matching the Add Expense save bar.
class _ParseBar extends StatelessWidget {
  const _ParseBar({
    required this.enabled,
    required this.busy,
    required this.onPressed,
  });

  final bool enabled;
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
        label: 'Parse transaction',
        icon: Icons.auto_fix_high_rounded,
        busy: busy,
        busyLabel: 'Reading…',
        onPressed: enabled ? onPressed : null,
      ),
    );
  }
}

/// Entry point row, used on the Add Expense screen beside "Scan a receipt".
class PasteSmsCard extends StatelessWidget {
  const PasteSmsCard({super.key, required this.onTap, this.busy = false});

  final VoidCallback onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color accent = theme.colorScheme.primary;

    return SurfaceCard(
      onTap: busy ? null : onTap,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: AppSpacing.avatarSm,
            height: AppSpacing.avatarSm,
            decoration: BoxDecoration(
              color: ToneColors.wash(context, accent),
              borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
            ),
            child: Icon(
              Icons.sms_outlined,
              size: AppSpacing.iconMd,
              color: accent,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text('Paste bank SMS', style: theme.textTheme.titleSmall),
                const SizedBox(height: AppSpacing.xxs),
                Text(
                  'Read an alert from your bank',
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          AppButton(
            label: 'Paste',
            size: AppButtonSize.small,
            variant: AppButtonVariant.tonal,
            icon: Icons.content_paste_rounded,
            onPressed: busy ? null : onTap,
          ),
        ],
      ),
    );
  }
}

/// Opens the paste flow. Resolves true when an expense was created.
Future<bool> startSmsImport(BuildContext context) async {
  final bool? saved = await Navigator.of(context).push<bool>(
    MaterialPageRoute<bool>(builder: (_) => const PasteSmsScreen()),
  );
  return saved ?? false;
}
