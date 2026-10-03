import 'dart:async';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/utils/date_utils.dart';
import '../../models/ai_chat.dart';

/// The app's entire knowledge of the AI: one authenticated function.
///
/// There is no Gemini or Groq code, key, model name or endpoint anywhere in
/// the app. The service posts the user's words to the `ai-chat` Edge Function
/// with the session token the Supabase client already holds, and reads back
/// a reply. Which model answered, which tools ran and what they read is the
/// server's business.
abstract class AiChatService {
  /// Sends one message with a short, text-only history.
  Future<AiChatReply> send({
    required String message,
    required List<ChatHistoryTurn> history,
    required DateTime today,
  });

  /// Executes a write the server prepared and the user approved.
  Future<AiChatReply> confirm({
    required PendingAction action,
    required DateTime today,
  });

  /// Suggests a spending category for one merchant name.
  ///
  /// Used by bank-SMS import when the on-device keyword rules find nothing.
  /// Only the payee is sent — never the message, the amount, the account or
  /// the reference — and the answer is only ever a category name.
  ///
  /// Returns null for "no opinion". Implementations must not throw: a
  /// classification that fails is not worth interrupting an import for, and
  /// the caller falls back to its own catch-all category.
  Future<String?> suggestCategory({required String merchant});
}

class SupabaseAiChatService implements AiChatService {
  const SupabaseAiChatService(this._client);

  final SupabaseClient _client;

  static const String functionName = 'ai-chat';

  /// A little over the server's own 60s budget, so a slow answer is the
  /// server's to time out and report, not ours to guess about.
  static const Duration _timeout = Duration(seconds: 75);

  @override
  Future<AiChatReply> send({
    required String message,
    required List<ChatHistoryTurn> history,
    required DateTime today,
  }) {
    return _invoke(<String, dynamic>{
      'action': 'chat',
      'message': message,
      'history': history.map((ChatHistoryTurn t) => t.toJson()).toList(),
      'client_context': _clientContext(today),
    });
  }

  @override
  Future<AiChatReply> confirm({
    required PendingAction action,
    required DateTime today,
  }) {
    return _invoke(<String, dynamic>{
      'action': 'confirm',
      'pending_action': action.toJson(),
      'client_context': _clientContext(today),
    });
  }

  /// Longest merchant name sent. Matches the function's own cap, so an
  /// absurd payee is trimmed here rather than bounced with a 413.
  static const int maxMerchantChars = 120;

  @override
  Future<String?> suggestCategory({required String merchant}) async {
    final String payee = merchant.trim();
    if (payee.isEmpty) return null;
    if (_client.auth.currentSession == null) return null;

    try {
      final FunctionResponse response = await _client.functions
          .invoke(
            functionName,
            body: <String, dynamic>{
              'action': 'classify',
              'merchant': payee.length > maxMerchantChars
                  ? payee.substring(0, maxMerchantChars)
                  : payee,
            },
          )
          .timeout(_classifyTimeout);

      final Object? data = response.data;
      if (data is! Map) return null;
      final Object? category = data['category'];
      return category is String && category.trim().isNotEmpty
          ? category.trim()
          : null;
    } catch (_) {
      // Every failure means the same thing here — no suggestion — and the
      // import continues with the catch-all category. Surfacing a rate limit
      // or an outage as an error would block a flow that never needed the
      // AI to work in the first place.
      return null;
    }
  }

  /// Shorter than a chat turn. This runs while the user waits on a parse, and
  /// a suggestion that arrives late is worth less than one skipped.
  static const Duration _classifyTimeout = Duration(seconds: 20);

  /// Only the calendar date: the phone knows its time zone and the server
  /// does not, so "this month" is decided here. Nothing else about the
  /// device is sent.
  static Map<String, dynamic> _clientContext(DateTime today) =>
      <String, dynamic>{'today': AppDateUtils.toDateString(today)};

  Future<AiChatReply> _invoke(Map<String, dynamic> body) async {
    if (_client.auth.currentSession == null) {
      throw const AiChatException(
        AiChatFailure.unauthenticated,
        'You are signed out. Sign in again to use the assistant.',
      );
    }

    try {
      final FunctionResponse response = await _client.functions
          .invoke(functionName, body: body)
          .timeout(_timeout);
      return AiChatReply.fromJson(response.data);
    } on FunctionException catch (error) {
      throw mapFunctionException(error);
    } on AiChatException {
      rethrow;
    } on TimeoutException {
      throw const AiChatException(
        AiChatFailure.unavailable,
        'The assistant took too long to answer. Please try again.',
      );
    } on SocketException {
      throw const AiChatException(
        AiChatFailure.network,
        'No internet connection. Check your network and try again.',
      );
    } on FormatException catch (error) {
      throw AiChatException(AiChatFailure.unknown, error.message);
    } catch (_) {
      throw const AiChatException(
        AiChatFailure.unknown,
        'Something went wrong. Please try again.',
      );
    }
  }

  /// Turns an HTTP failure into something the user can read.
  ///
  /// The function writes its `message` field for people and never puts a
  /// stack trace, query or provider payload in it, so that text is trusted
  /// for the statuses the function owns. Anything else — a gateway error, a
  /// non-JSON body — gets a generic line.
  static AiChatException mapFunctionException(FunctionException error) {
    final Object? details = error.details;
    final String? serverMessage = details is Map ? details['message'] as String? : null;
    final String? code = details is Map ? details['error'] as String? : null;

    switch (error.status) {
      case 401:
        return const AiChatException(
          AiChatFailure.unauthenticated,
          'Your session has expired. Please sign in again.',
        );
      case 413:
        return AiChatException(
          AiChatFailure.tooLong,
          serverMessage ?? 'That message is too long. Try asking in fewer words.',
        );
      case 422:
        return AiChatException(
          AiChatFailure.rejected,
          serverMessage ?? 'That could not be done. Please ask again.',
        );
      case 429:
        return AiChatException(
          AiChatFailure.rateLimited,
          serverMessage ?? 'You are sending messages quickly. Give it a moment.',
          retryAfter: _retryAfter(details),
        );
      case 503:
        return code == 'not_configured'
            ? AiChatException(
                AiChatFailure.notConfigured,
                serverMessage ?? 'The assistant is not set up yet.',
              )
            : AiChatException(
                AiChatFailure.unavailable,
                serverMessage ?? 'The assistant is busy right now. Please try again in a moment.',
              );
      case 400:
        return AiChatException(
          AiChatFailure.rejected,
          serverMessage ?? 'That request could not be understood.',
        );
      default:
        return const AiChatException(
          AiChatFailure.unknown,
          'Something went wrong. Please try again.',
        );
    }
  }

  static Duration? _retryAfter(Object? details) {
    if (details is! Map) return null;
    final Object? seconds = details['retry_after'];
    return seconds is num ? Duration(seconds: seconds.toInt()) : null;
  }
}
