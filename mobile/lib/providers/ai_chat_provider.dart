import 'package:flutter/foundation.dart';

import '../core/utils/uuid.dart';
import '../models/ai_chat.dart';
import '../services/ai/ai_chat_service.dart';

/// The conversation with the assistant.
///
/// Held in memory for the session and nowhere else: the server keeps no
/// transcript, the database has no chat table, and `reset` on sign-out drops
/// it. Each request carries only a short, text-only tail of the conversation
/// so the model has context without ever receiving a full history or a
/// database.
class AiChatProvider extends ChangeNotifier {
  AiChatProvider(this._service, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final AiChatService _service;
  final DateTime Function() _clock;

  /// Longest message the app will send. Matches the server's limit so the
  /// user hears about it before a round trip rather than after.
  static const int maxMessageChars = 1000;

  /// Turns of context sent with each message. The server caps this too.
  static const int historyTurns = 10;

  static const List<String> suggestedQuestions = <String>[
    'What did I spend this month?',
    'Where am I spending the most?',
    'How much is left in my budget?',
    'What is my current bank balance?',
    'Show my recent expenses.',
  ];

  /// Filled into the input rather than sent, so the amount is the user's.
  static const List<String> suggestedActions = <String>[
    'Add ₹500 for shopping',
    'Add ₹2,000 salary income',
    'Transfer ₹1,000 from HDFC to SBI',
  ];

  final List<ChatMessage> _messages = <ChatMessage>[];
  bool _busy = false;
  String? _lastFailedText;

  /// Incremented whenever a confirmed write changed data, so the screen that
  /// opened the assistant knows to refresh its figures on return.
  int _dataRevision = 0;

  bool _disposed = false;

  List<ChatMessage> get messages => List<ChatMessage>.unmodifiable(_messages);
  bool get busy => _busy;
  bool get isEmpty => _messages.isEmpty;
  int get dataRevision => _dataRevision;

  /// The most recent failed send, offered for a one-tap retry.
  String? get lastFailedText => _lastFailedText;

  /// Sends [raw]. Returns false without sending when the input is unusable.
  Future<bool> send(String raw) async {
    final String text = raw.trim();
    if (text.isEmpty || _busy) return false;
    if (text.length > maxMessageChars) return false;

    final ChatMessage outgoing = ChatMessage(
      id: Uuid.v4(),
      role: ChatRole.user,
      text: text,
      status: ChatMessageStatus.sending,
    );
    final List<ChatHistoryTurn> history = _historyBefore();
    _messages.add(outgoing);
    _busy = true;
    _lastFailedText = null;
    _notify();

    try {
      final AiChatReply reply = await _service.send(
        message: text,
        history: history,
        today: _clock(),
      );
      _replace(outgoing.id, outgoing.copyWith(status: ChatMessageStatus.sent));
      _messages.add(ChatMessage(
        id: Uuid.v4(),
        role: ChatRole.assistant,
        text: reply.reply,
        pendingAction: reply.pendingAction,
        provider: reply.provider,
      ));
      if (reply.dataChanged) _dataRevision++;
      return true;
    } catch (error) {
      final String message = _describe(error);
      _replace(
        outgoing.id,
        outgoing.copyWith(status: ChatMessageStatus.failed, error: message),
      );
      _lastFailedText = text;
      return false;
    } finally {
      _busy = false;
      _notify();
    }
  }

  /// Re-sends the last failed message, removing its failed bubble first so
  /// the transcript does not show the same words twice.
  Future<bool> retryLast() async {
    final String? text = _lastFailedText;
    if (text == null || _busy) return false;
    _messages.removeWhere(
      (ChatMessage m) => m.isUser && m.status == ChatMessageStatus.failed && m.text == text,
    );
    _lastFailedText = null;
    return send(text);
  }

  /// Executes the write proposed in [messageId]. Nothing is written until
  /// this is called, and the server checks everything again when it is.
  Future<bool> confirm(String messageId) async {
    final int index = _messages.indexWhere((ChatMessage m) => m.id == messageId);
    if (index < 0 || _busy) return false;
    final ChatMessage card = _messages[index];
    final PendingAction? action = card.pendingAction;
    if (action == null || !card.actionOpen) return false;

    if (action.isExpired(_clock())) {
      _messages[index] = card.copyWith(
        actionState: PendingActionState.failed,
        actionError: 'That request has expired. Please ask again.',
      );
      _notify();
      return false;
    }

    _messages[index] = card.copyWith(
      actionState: PendingActionState.confirming,
      clearActionError: true,
    );
    _busy = true;
    _notify();

    try {
      final AiChatReply reply = await _service.confirm(action: action, today: _clock());
      _replace(messageId, card.copyWith(actionState: PendingActionState.confirmed));
      _messages.add(ChatMessage(
        id: Uuid.v4(),
        role: ChatRole.assistant,
        text: reply.reply,
      ));
      if (reply.dataChanged) _dataRevision++;
      return true;
    } catch (error) {
      final AiChatException failure = error is AiChatException
          ? error
          : const AiChatException(AiChatFailure.unknown, 'Something went wrong. Please try again.');
      // A rejection is final — the server said no and re-asking is the way
      // forward. A transient failure leaves the card open to try again.
      final PendingActionState next = failure.kind == AiChatFailure.rejected ||
              failure.kind == AiChatFailure.unauthenticated
          ? PendingActionState.failed
          : PendingActionState.pending;
      _replace(
        messageId,
        card.copyWith(actionState: next, actionError: failure.message),
      );
      return false;
    } finally {
      _busy = false;
      _notify();
    }
  }

  /// Declines a proposed write. Local only; the server never prepared
  /// anything that needs undoing.
  void cancel(String messageId) {
    final int index = _messages.indexWhere((ChatMessage m) => m.id == messageId);
    if (index < 0) return;
    final ChatMessage card = _messages[index];
    if (!card.actionOpen) return;
    _messages[index] = card.copyWith(actionState: PendingActionState.cancelled);
    _messages.add(const ChatMessage(
      id: 'cancel-note',
      role: ChatRole.assistant,
      text: 'Okay, nothing was saved.',
    ).withFreshId());
    _notify();
  }

  /// Starts a new conversation. The figures the assistant reported are not
  /// affected; only the transcript goes.
  void clear() {
    if (_busy) return;
    _messages.clear();
    _lastFailedText = null;
    _notify();
  }

  /// Sign-out. Everything goes, including the revision counter.
  void reset() {
    _messages.clear();
    _lastFailedText = null;
    _busy = false;
    _dataRevision = 0;
    _notify();
  }

  // -------------------------------------------------------------------------

  /// The context sent with a message: the last few *delivered* turns as
  /// plain text. Failed sends, cards and provider names are not context.
  List<ChatHistoryTurn> _historyBefore() {
    final List<ChatHistoryTurn> turns = <ChatHistoryTurn>[];
    for (final ChatMessage m in _messages) {
      if (m.isUser && m.status != ChatMessageStatus.sent) continue;
      if (m.text.trim().isEmpty) continue;
      turns.add(ChatHistoryTurn(role: m.role, content: m.text));
    }
    if (turns.length <= historyTurns) return turns;
    return turns.sublist(turns.length - historyTurns);
  }

  void _replace(String id, ChatMessage replacement) {
    final int index = _messages.indexWhere((ChatMessage m) => m.id == id);
    if (index >= 0) _messages[index] = replacement;
  }

  static String _describe(Object error) {
    if (error is AiChatException) return error.message;
    return 'Something went wrong. Please try again.';
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

extension on ChatMessage {
  ChatMessage withFreshId() => ChatMessage(
        id: Uuid.v4(),
        role: role,
        text: text,
        status: status,
        error: error,
        pendingAction: pendingAction,
        actionState: actionState,
        actionError: actionError,
        provider: provider,
      );
}
