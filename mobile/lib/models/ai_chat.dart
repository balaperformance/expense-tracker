/// Conversation types for the AI assistant.
///
/// Plain values with no Supabase or Flutter dependency, so the provider and
/// the screen can be tested with a fake service. Everything here mirrors the
/// `ai-chat` Edge Function's response contract and nothing else: the app
/// never sees a model, a tool call or a database row.
library;

enum ChatRole { user, assistant }

/// Delivery state of a message the user sent.
enum ChatMessageStatus { sending, sent, failed }

/// Life cycle of a proposed write. It starts pending and ends in exactly one
/// of the other three states; the card is never shown as actionable twice.
enum PendingActionState { pending, confirming, confirmed, cancelled, failed }

/// A write the assistant prepared server-side and is waiting for the user to
/// approve. The arguments are opaque to the app — they are echoed back
/// verbatim on confirm and re-verified by the server.
class PendingAction {
  const PendingAction({
    required this.id,
    required this.tool,
    required this.args,
    required this.summary,
    this.expiresAt,
  });

  final String id;
  final String tool;
  final Map<String, dynamic> args;

  /// The question shown on the card, written by the server.
  final String summary;
  final DateTime? expiresAt;

  bool get isExpense => tool == 'create_expense';
  bool get isIncome => tool == 'create_income';
  bool get isTransfer => tool == 'transfer_money';

  /// Label for the card header.
  String get kindLabel => switch (tool) {
        'create_expense' => 'New expense',
        'create_income' => 'New income',
        'transfer_money' => 'Transfer',
        _ => 'Action',
      };

  bool isExpired(DateTime now) {
    final DateTime? at = expiresAt;
    return at != null && now.isAfter(at);
  }

  static PendingAction? fromJson(Object? json) {
    if (json is! Map) return null;
    final Object? tool = json['tool'];
    final Object? summary = json['summary'];
    final Object? args = json['args'];
    if (tool is! String || summary is! String || args is! Map) return null;

    final Object? expires = json['expires_at'];
    return PendingAction(
      id: (json['id'] as String?) ?? '',
      tool: tool,
      args: Map<String, dynamic>.from(args),
      summary: summary,
      expiresAt: expires is String ? DateTime.tryParse(expires) : null,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'tool': tool,
        'args': args,
        'summary': summary,
        if (expiresAt != null) 'expires_at': expiresAt!.toUtc().toIso8601String(),
      };
}

/// One bubble in the conversation.
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.text,
    this.status = ChatMessageStatus.sent,
    this.error,
    this.pendingAction,
    this.actionState = PendingActionState.pending,
    this.actionError,
    this.provider,
  });

  final String id;
  final ChatRole role;
  final String text;

  /// Only meaningful for user messages.
  final ChatMessageStatus status;

  /// Why sending failed, in words. Shown beside the retry control.
  final String? error;

  /// Present on an assistant message that proposes a write.
  final PendingAction? pendingAction;
  final PendingActionState actionState;

  /// Why a confirmation failed — the card stays on screen with this under it.
  final String? actionError;

  /// Which provider answered. Diagnostic only; never shown as a claim.
  final String? provider;

  bool get isUser => role == ChatRole.user;
  bool get hasAction => pendingAction != null;

  /// True while the card can still be acted on.
  bool get actionOpen =>
      pendingAction != null && actionState == PendingActionState.pending;

  ChatMessage copyWith({
    ChatMessageStatus? status,
    String? error,
    bool clearError = false,
    PendingActionState? actionState,
    String? actionError,
    bool clearActionError = false,
  }) {
    return ChatMessage(
      id: id,
      role: role,
      text: text,
      status: status ?? this.status,
      error: clearError ? null : (error ?? this.error),
      pendingAction: pendingAction,
      actionState: actionState ?? this.actionState,
      actionError: clearActionError ? null : (actionError ?? this.actionError),
      provider: provider,
    );
  }
}

/// What is sent back to the server as context: text only, no cards, no ids.
class ChatHistoryTurn {
  const ChatHistoryTurn({required this.role, required this.content});

  final ChatRole role;
  final String content;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'role': role == ChatRole.user ? 'user' : 'assistant',
        'content': content,
      };
}

/// A successful answer from the Edge Function.
class AiChatReply {
  const AiChatReply({
    required this.reply,
    this.pendingAction,
    this.provider,
    this.dataChanged = false,
  });

  final String reply;
  final PendingAction? pendingAction;
  final String? provider;

  /// True after a confirmed write, so the caller knows to refresh figures.
  final bool dataChanged;

  factory AiChatReply.fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('The assistant returned an unexpected response.');
    }
    final Object? reply = json['reply'];
    if (reply is! String) {
      throw const FormatException('The assistant returned an unexpected response.');
    }
    return AiChatReply(
      reply: reply,
      pendingAction: PendingAction.fromJson(json['pending_action']),
      provider: json['provider'] as String?,
      dataChanged: json['data_changed'] == true,
    );
  }
}

/// Why a request to the assistant failed. Every kind has a message written
/// for the user; nothing from the transport or the server's internals is
/// passed through except the server's own `message`, which it writes for
/// people.
enum AiChatFailure {
  unauthenticated,
  rateLimited,
  notConfigured,
  unavailable,
  rejected,
  tooLong,
  network,
  unknown,
}

class AiChatException implements Exception {
  const AiChatException(this.kind, this.message, {this.retryAfter});

  final AiChatFailure kind;
  final String message;
  final Duration? retryAfter;

  /// Whether the same message is worth sending again unchanged.
  bool get isRetryable => switch (kind) {
        AiChatFailure.rateLimited ||
        AiChatFailure.unavailable ||
        AiChatFailure.network ||
        AiChatFailure.unknown =>
          true,
        _ => false,
      };

  @override
  String toString() => 'AiChatException(${kind.name}): $message';
}
