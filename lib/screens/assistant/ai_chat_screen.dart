import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_spacing.dart';
import '../../models/ai_chat.dart';
import '../../providers/ai_chat_provider.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/money_text.dart';
import '../../widgets/common/state_views.dart';
import '../../widgets/common/surface_card.dart';

/// Ask the assistant.
///
/// A conversation, not a form: the user types what they want to know or
/// record, and the reply arrives as a bubble. When the assistant proposes a
/// write it arrives as a card with Confirm and Cancel, and nothing is saved
/// until Confirm is tapped. The screen never computes a figure or touches a
/// repository; every number on it came back from the server.
class AiChatScreen extends StatefulWidget {
  const AiChatScreen({super.key});

  @override
  State<AiChatScreen> createState() => _AiChatScreenState();
}

class _AiChatScreenState extends State<AiChatScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _focus = FocusNode();

  int _seenCount = 0;

  @override
  void initState() {
    super.initState();
    _input.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AiChatProvider chat = context.watch<AiChatProvider>();

    // Keep the newest bubble in view as the conversation grows.
    if (chat.messages.length != _seenCount) {
      _seenCount = chat.messages.length;
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Assistant'),
        actions: <Widget>[
          if (!chat.isEmpty)
            IconButton(
              tooltip: 'New conversation',
              onPressed: chat.busy ? null : chat.clear,
              icon: const Icon(Icons.edit_square),
            ),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      body: Column(
        children: <Widget>[
          Expanded(
            child: chat.isEmpty
                ? _Welcome(onAsk: _send, onFill: _fill)
                : _Transcript(
                    controller: _scroll,
                    messages: chat.messages,
                    busy: chat.busy,
                    onRetry: chat.lastFailedText == null ? null : _retry,
                    onConfirm: _confirm,
                    onCancel: chat.cancel,
                  ),
          ),
          _Composer(
            controller: _input,
            focusNode: _focus,
            busy: chat.busy,
            onSend: () => _send(_input.text),
          ),
        ],
      ),
    );
  }

  Future<void> _send(String text) async {
    final AiChatProvider chat = context.read<AiChatProvider>();
    final bool accepted = await chat.send(text);
    if (accepted && mounted) _input.clear();
  }

  void _fill(String text) {
    _input.text = text;
    _input.selection = TextSelection.collapsed(offset: text.length);
    _focus.requestFocus();
  }

  Future<void> _retry() => context.read<AiChatProvider>().retryLast();

  Future<void> _confirm(String messageId) =>
      context.read<AiChatProvider>().confirm(messageId);

  void _scrollToEnd() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }
}

// ---------------------------------------------------------------------------
// Empty state
// ---------------------------------------------------------------------------

class _Welcome extends StatelessWidget {
  const _Welcome({required this.onAsk, required this.onFill});

  final ValueChanged<String> onAsk;
  final ValueChanged<String> onFill;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.page,
        AppSpacing.lg,
        AppSpacing.page,
        AppSpacing.lg,
      ),
      children: <Widget>[
        Row(
          children: <Widget>[
            IconWell(
              icon: Icons.auto_awesome_rounded,
              tone: theme.colorScheme.primary,
              size: AppSpacing.avatar,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('Ask about your money', style: theme.textTheme.titleMedium),
                  const SizedBox(height: AppSpacing.xxs),
                  Text(
                    'Totals, balances, budgets — or tell me what to record.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.section),
        const SectionHeader(title: 'Ask'),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: <Widget>[
            for (final String question in AiChatProvider.suggestedQuestions)
              _SuggestionChip(label: question, onTap: () => onAsk(question)),
          ],
        ),
        const SizedBox(height: AppSpacing.section),
        const SectionHeader(title: 'Record'),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: <Widget>[
            for (final String action in AiChatProvider.suggestedActions)
              _SuggestionChip(
                label: action,
                icon: Icons.edit_outlined,
                onTap: () => onFill(action),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.section),
        const AppNotice(
          icon: Icons.verified_user_outlined,
          message: 'Answers are worked out from your own records, never '
              'estimated. Anything to be recorded is shown to you first and '
              'saved only when you confirm.',
        ),
      ],
    );
  }
}

class _SuggestionChip extends StatelessWidget {
  const _SuggestionChip({required this.label, required this.onTap, this.icon});

  final String label;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ActionChip(
      onPressed: onTap,
      avatar: icon == null
          ? null
          : Icon(icon, size: AppSpacing.iconSm, color: theme.colorScheme.onSurfaceVariant),
      label: Text(label),
      labelStyle: theme.textTheme.labelLarge,
      side: BorderSide(color: theme.colorScheme.outline),
      backgroundColor: theme.cardTheme.color,
    );
  }
}

// ---------------------------------------------------------------------------
// Transcript
// ---------------------------------------------------------------------------

class _Transcript extends StatelessWidget {
  const _Transcript({
    required this.controller,
    required this.messages,
    required this.busy,
    required this.onRetry,
    required this.onConfirm,
    required this.onCancel,
  });

  final ScrollController controller;
  final List<ChatMessage> messages;
  final bool busy;
  final VoidCallback? onRetry;
  final ValueChanged<String> onConfirm;
  final ValueChanged<String> onCancel;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.page,
        AppSpacing.md,
        AppSpacing.page,
        AppSpacing.md,
      ),
      itemCount: messages.length + (busy ? 1 : 0),
      itemBuilder: (BuildContext context, int index) {
        if (index == messages.length) {
          return const Padding(
            padding: EdgeInsets.only(top: AppSpacing.sm),
            child: _AssistantRow(child: _TypingDots()),
          );
        }
        final ChatMessage message = messages[index];
        final Widget bubble = message.isUser
            ? _UserBubble(message: message, onRetry: onRetry)
            : _AssistantRow(
                child: _AssistantBubble(
                  message: message,
                  onConfirm: () => onConfirm(message.id),
                  onCancel: () => onCancel(message.id),
                ),
              );
        return Padding(
          padding: EdgeInsets.only(top: index == 0 ? 0 : AppSpacing.sm),
          child: bubble,
        );
      },
    );
  }
}

/// Assistant messages sit left with a small mark, so the two voices read
/// apart even before colour is noticed.
class _AssistantRow extends StatelessWidget {
  const _AssistantRow({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: AppSpacing.xs),
          child: IconWell(
            icon: Icons.auto_awesome_rounded,
            tone: theme.colorScheme.primary,
            size: 26,
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(child: child),
      ],
    );
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.message, required this.onRetry});

  final ChatMessage message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool failed = message.status == ChatMessageStatus.failed;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.78,
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm + 2,
          ),
          decoration: BoxDecoration(
            // A solid bubble in the brand tone, so the user's voice and the
            // assistant's glass bubble separate at a glance. A failed send
            // drops back to an error wash so it cannot look delivered.
            color: failed
                ? ToneColors.wash(context, theme.colorScheme.error)
                : theme.colorScheme.primary,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(AppSpacing.radiusLg),
              topRight: Radius.circular(AppSpacing.radiusLg),
              bottomLeft: Radius.circular(AppSpacing.radiusLg),
              bottomRight: Radius.circular(AppSpacing.radiusXs),
            ),
          ),
          child: Text(
            message.text,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: failed ? null : theme.colorScheme.onPrimary,
            ),
          ),
        ),
        if (failed) ...<Widget>[
          const SizedBox(height: AppSpacing.xs),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              Flexible(
                child: Text(
                  message.error ?? 'Not sent',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (onRetry != null) ...<Widget>[
                const SizedBox(width: AppSpacing.xs),
                AppButton(
                  label: 'Retry',
                  icon: Icons.refresh_rounded,
                  variant: AppButtonVariant.ghost,
                  size: AppButtonSize.small,
                  onPressed: onRetry,
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }
}

class _AssistantBubble extends StatelessWidget {
  const _AssistantBubble({
    required this.message,
    required this.onConfirm,
    required this.onCancel,
  });

  final ChatMessage message;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final PendingAction? action = message.pendingAction;

    // A proposal is the card; the bubble text would only repeat its question.
    if (action != null) {
      return _ActionCard(message: message, onConfirm: onConfirm, onCancel: onCancel);
    }

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.82,
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm + 2,
        ),
        decoration: BoxDecoration(
          color: theme.cardTheme.color,
          border: Border.all(color: theme.dividerTheme.color ?? theme.dividerColor),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(AppSpacing.radiusXs),
            topRight: Radius.circular(AppSpacing.radiusLg),
            bottomLeft: Radius.circular(AppSpacing.radiusLg),
            bottomRight: Radius.circular(AppSpacing.radiusLg),
          ),
        ),
        child: SelectableText(message.text, style: theme.textTheme.bodyMedium),
      ),
    );
  }
}

/// The confirmation step. Confirm is the one primary button on the screen
/// while a card is open; everything else steps down from it.
class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.message,
    required this.onConfirm,
    required this.onCancel,
  });

  final ChatMessage message;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final PendingAction action = message.pendingAction!;
    final PendingActionState state = message.actionState;

    final (IconData icon, Color tone) = action.isTransfer
        ? (Icons.swap_horiz_rounded, ToneColors.transfer(context))
        : action.isIncome
            ? (Icons.add_circle_outline_rounded, ToneColors.income(context))
            : (Icons.remove_circle_outline_rounded, ToneColors.expense(context));

    return SurfaceCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              IconWell(icon: icon, tone: tone, size: AppSpacing.avatarSm),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(action.kindLabel, style: theme.textTheme.labelMedium),
              ),
              _StateBadge(state: state),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(action.summary, style: theme.textTheme.titleMedium),
          if (message.actionError != null) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            InlineError(message: message.actionError!),
          ],
          if (state == PendingActionState.pending ||
              state == PendingActionState.confirming) ...<Widget>[
            const SizedBox(height: AppSpacing.md),
            AppButtonRow(
              confirmLabel: 'Confirm',
              onConfirm: state == PendingActionState.confirming ? null : onConfirm,
              onCancel: onCancel,
              busy: state == PendingActionState.confirming,
            ),
          ],
        ],
      ),
    );
  }
}

class _StateBadge extends StatelessWidget {
  const _StateBadge({required this.state});

  final PendingActionState state;

  @override
  Widget build(BuildContext context) {
    return switch (state) {
      PendingActionState.pending ||
      PendingActionState.confirming =>
        const AppBadge(label: 'Needs confirmation'),
      PendingActionState.confirmed => AppBadge(
          label: 'Saved',
          icon: Icons.check_rounded,
          tone: ToneColors.income(context),
        ),
      PendingActionState.cancelled => const AppBadge(label: 'Cancelled'),
      PendingActionState.failed => AppBadge(
          label: 'Not saved',
          tone: Theme.of(context).colorScheme.error,
        ),
    };
  }
}

/// Three rising dots while the server thinks. Deliberately not a spinner:
/// a spinner in a chat reads as "loading the screen", not "typing".
class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color colour = Theme.of(context).colorScheme.onSurfaceVariant;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.md,
        ),
        decoration: BoxDecoration(
          color: Theme.of(context).cardTheme.color,
          border: Border.all(color: Theme.of(context).dividerTheme.color ?? Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
        ),
        child: AnimatedBuilder(
          animation: _controller,
          builder: (BuildContext context, Widget? _) {
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: List<Widget>.generate(3, (int i) {
                final double phase = ((_controller.value - i * 0.18) % 1.0);
                final double lift = phase < 0.5 ? phase * 2 : (1 - phase) * 2;
                return Padding(
                  padding: EdgeInsets.only(
                    right: i == 2 ? 0 : AppSpacing.xs + 1,
                    bottom: lift * 4,
                  ),
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: colour.withOpacity(0.45 + lift * 0.5),
                      shape: BoxShape.circle,
                    ),
                  ),
                );
              }),
            );
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Composer
// ---------------------------------------------------------------------------

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.busy,
    required this.onSend,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool busy;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool canSend = !busy &&
        controller.text.trim().isNotEmpty &&
        controller.text.length <= AiChatProvider.maxMessageChars;

    return Container(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.page,
        AppSpacing.sm,
        AppSpacing.sm,
        AppSpacing.sm + MediaQuery.paddingOf(context).bottom,
      ),
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        border: Border(top: BorderSide(color: theme.dividerTheme.color ?? theme.dividerColor)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              enabled: !busy,
              minLines: 1,
              maxLines: 4,
              maxLength: AiChatProvider.maxMessageChars,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => canSend ? onSend() : null,
              style: theme.textTheme.bodyMedium,
              decoration: const InputDecoration(
                hintText: 'Ask or tell me what to record…',
                counterText: '',
                contentPadding: EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: AppSpacing.md,
                ),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          // Sized to the field, not to the FAB: the send control is a
          // compact icon, the same weight as an app-bar action.
          IconButton.filled(
            tooltip: 'Send',
            onPressed: canSend ? onSend : null,
            iconSize: AppSpacing.iconMd,
            visualDensity: VisualDensity.standard,
            icon: const Icon(Icons.arrow_upward_rounded),
          ),
        ],
      ),
    );
  }
}
