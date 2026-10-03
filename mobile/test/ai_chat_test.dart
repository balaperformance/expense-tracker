// AI assistant client tests.
//
// The app's half of the assistant is deliberately thin: it sends text to one
// authenticated function and renders what comes back. What is worth pinning
// here is exactly that thinness — no key, no model, no calculation — and the
// confirmation contract: a proposed write is never executed until the user
// taps Confirm, and a failed send can be retried without duplicating itself.

import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/models/ai_chat.dart';
import 'package:expense_tracker/providers/ai_chat_provider.dart';
import 'package:expense_tracker/screens/assistant/ai_chat_screen.dart';
import 'package:expense_tracker/services/ai/ai_chat_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FunctionException;

/// Scripted service. Records every call so tests can assert what was sent.
class FakeAiChatService implements AiChatService {
  final List<Map<String, dynamic>> sends = <Map<String, dynamic>>[];
  final List<PendingAction> confirms = <PendingAction>[];
  final List<Object> script = <Object>[];

  /// Merchant names passed to [suggestCategory], for the SMS import tests.
  final List<String> classified = <String>[];

  /// What [suggestCategory] answers. Null is the realistic default: the
  /// classifier has no opinion unless a test gives it one.
  String? categoryAnswer;

  /// Set to make classification fail the way an outage would.
  Object? categoryError;

  void reply(String text, {PendingAction? action}) =>
      script.add(AiChatReply(reply: text, pendingAction: action));

  void fail(AiChatException error) => script.add(error);

  Object _next() {
    if (script.isEmpty) return const AiChatReply(reply: '(no script)');
    return script.removeAt(0);
  }

  @override
  Future<AiChatReply> send({
    required String message,
    required List<ChatHistoryTurn> history,
    required DateTime today,
  }) async {
    sends.add(<String, dynamic>{
      'message': message,
      'history': history.map((ChatHistoryTurn t) => t.toJson()).toList(),
      'today': today,
    });
    final Object next = _next();
    if (next is AiChatException) throw next;
    return next as AiChatReply;
  }

  @override
  Future<AiChatReply> confirm({
    required PendingAction action,
    required DateTime today,
  }) async {
    confirms.add(action);
    final Object next = _next();
    if (next is AiChatException) throw next;
    final AiChatReply reply = next as AiChatReply;
    return AiChatReply(reply: reply.reply, dataChanged: true);
  }

  /// Mirrors the real service's contract: never throws, and answers null when
  /// it has nothing useful to say.
  @override
  Future<String?> suggestCategory({required String merchant}) async {
    classified.add(merchant);
    if (categoryError != null) return null;
    return categoryAnswer;
  }
}

PendingAction _expenseAction({DateTime? expiresAt}) => PendingAction(
      id: 'pa-1',
      tool: 'create_expense',
      args: <String, dynamic>{
        'amount': 500,
        'date': '2026-09-22',
        'category_id': '11111111-0000-4000-8000-000000000002',
        'category_name': 'Shopping',
      },
      summary: 'Add ₹500 expense under Shopping?',
      expiresAt: expiresAt,
    );

final DateTime _now = DateTime(2026, 9, 22, 10);

AiChatProvider _provider(FakeAiChatService service) =>
    AiChatProvider(service, clock: () => _now);

void main() {
  group('AiChatReply parsing', () {
    test('reads a reply with a pending action', () {
      final AiChatReply reply = AiChatReply.fromJson(<String, dynamic>{
        'reply': 'Add ₹500 expense under Shopping?',
        'pending_action': <String, dynamic>{
          'id': 'x',
          'tool': 'create_expense',
          'args': <String, dynamic>{'amount': 500},
          'summary': 'Add ₹500 expense under Shopping?',
          'expires_at': '2026-09-22T10:10:00Z',
        },
        'provider': 'gemini',
        'data_changed': false,
      });
      expect(reply.reply, 'Add ₹500 expense under Shopping?');
      expect(reply.pendingAction?.tool, 'create_expense');
      expect(reply.pendingAction?.args['amount'], 500);
      expect(reply.pendingAction?.expiresAt, DateTime.utc(2026, 9, 22, 10, 10));
      expect(reply.provider, 'gemini');
      expect(reply.dataChanged, isFalse);
    });

    test('tolerates a null action and rejects a shapeless body', () {
      final AiChatReply reply = AiChatReply.fromJson(<String, dynamic>{
        'reply': 'Hi',
        'pending_action': null,
      });
      expect(reply.pendingAction, isNull);
      expect(() => AiChatReply.fromJson('nope'), throwsFormatException);
      expect(() => AiChatReply.fromJson(<String, dynamic>{'reply': 1}), throwsFormatException);
    });

    test('a pending action round-trips through toJson unchanged', () {
      final PendingAction action = _expenseAction(expiresAt: DateTime.utc(2026, 9, 22, 10, 10));
      final PendingAction? back = PendingAction.fromJson(action.toJson());
      expect(back?.tool, action.tool);
      expect(back?.args, action.args);
      expect(back?.summary, action.summary);
      expect(back?.expiresAt, action.expiresAt);
    });
  });

  group('error mapping', () {
    AiChatException map(int status, [Object? details]) =>
        SupabaseAiChatService.mapFunctionException(
          FunctionException(status: status, details: details),
        );

    test('every status the function owns has a user-facing message', () {
      expect(map(401).kind, AiChatFailure.unauthenticated);
      expect(map(413).kind, AiChatFailure.tooLong);
      expect(map(429).kind, AiChatFailure.rateLimited);
      expect(map(422, <String, dynamic>{'message': 'Savings only has ₹5,500 available.'}).message,
          'Savings only has ₹5,500 available.');
      expect(map(503, <String, dynamic>{'error': 'not_configured', 'message': 'x'}).kind,
          AiChatFailure.notConfigured);
      expect(map(503, <String, dynamic>{'error': 'provider_unavailable'}).kind,
          AiChatFailure.unavailable);
      expect(map(500).kind, AiChatFailure.unknown);
    });

    test('an unknown failure never echoes transport details', () {
      final AiChatException error = map(502, '<html>Bad Gateway from nginx/1.2</html>');
      expect(error.message, isNot(contains('nginx')));
      expect(error.message, isNot(contains('html')));
    });

    test('retryability follows the kind', () {
      expect(map(429).isRetryable, isTrue);
      expect(map(503, <String, dynamic>{'error': 'provider_unavailable'}).isRetryable, isTrue);
      expect(map(422).isRetryable, isFalse);
      expect(map(401).isRetryable, isFalse);
    });
  });

  group('AiChatProvider', () {
    test('send appends the question and the answer, and marks the question sent', () async {
      final FakeAiChatService service = FakeAiChatService()..reply('₹4,000 this month.');
      final AiChatProvider provider = _provider(service);

      expect(await provider.send('  What did I spend?  '), isTrue);

      expect(provider.messages.length, 2);
      expect(provider.messages[0].isUser, isTrue);
      expect(provider.messages[0].text, 'What did I spend?');
      expect(provider.messages[0].status, ChatMessageStatus.sent);
      expect(provider.messages[1].text, '₹4,000 this month.');
      expect(provider.busy, isFalse);
      expect(service.sends.single['today'], _now);
    });

    test('rejects blank and oversized input without a round trip', () async {
      final FakeAiChatService service = FakeAiChatService();
      final AiChatProvider provider = _provider(service);
      expect(await provider.send('   '), isFalse);
      expect(await provider.send('x' * (AiChatProvider.maxMessageChars + 1)), isFalse);
      expect(service.sends, isEmpty);
      expect(provider.isEmpty, isTrue);
    });

    test('history is the delivered text before this message, capped', () async {
      final FakeAiChatService service = FakeAiChatService();
      for (int i = 0; i < 15; i++) {
        service.reply('answer $i');
      }
      final AiChatProvider provider = _provider(service);
      for (int i = 0; i < 15; i++) {
        await provider.send('question $i');
      }

      final List<Object?> history = service.sends.last['history'] as List<Object?>;
      expect(history.length, AiChatProvider.historyTurns);
      // The most recent turns, ending with the previous answer.
      expect((history.last as Map<String, dynamic>)['content'], 'answer 13');
      expect((history.last as Map<String, dynamic>)['role'], 'assistant');
      // The first message carried no history at all.
      expect(service.sends.first['history'], isEmpty);
    });

    test('a failed send is marked failed and can be retried once, without duplicates', () async {
      final FakeAiChatService service = FakeAiChatService()
        ..fail(const AiChatException(AiChatFailure.unavailable, 'Busy right now.'))
        ..reply('Here you go.');
      final AiChatProvider provider = _provider(service);

      expect(await provider.send('balance?'), isFalse);
      expect(provider.messages.single.status, ChatMessageStatus.failed);
      expect(provider.messages.single.error, 'Busy right now.');
      expect(provider.lastFailedText, 'balance?');

      expect(await provider.retryLast(), isTrue);
      expect(provider.messages.length, 2);
      expect(provider.messages.where((ChatMessage m) => m.isUser).length, 1);
      expect(provider.lastFailedText, isNull);
      expect(service.sends.length, 2);
    });

    test('a failed message is not sent back as context', () async {
      final FakeAiChatService service = FakeAiChatService()
        ..fail(const AiChatException(AiChatFailure.network, 'Offline.'))
        ..reply('ok');
      final AiChatProvider provider = _provider(service);
      await provider.send('lost');
      await provider.send('found');
      expect(service.sends.last['history'], isEmpty);
    });

    test('a proposed write is NOT executed until confirm is called', () async {
      final FakeAiChatService service = FakeAiChatService()
        ..reply('Add ₹500 expense under Shopping?', action: _expenseAction());
      final AiChatProvider provider = _provider(service);

      await provider.send('Add ₹500 for shopping');
      final ChatMessage card = provider.messages.last;
      expect(card.hasAction, isTrue);
      expect(card.actionOpen, isTrue);
      expect(card.actionState, PendingActionState.pending);
      expect(service.confirms, isEmpty, reason: 'confirmation is required');
      expect(provider.dataRevision, 0);
    });

    test('confirm executes once, appends the outcome and bumps the revision', () async {
      final FakeAiChatService service = FakeAiChatService()
        ..reply('Add ₹500 expense under Shopping?', action: _expenseAction())
        ..reply('Done. ₹500 was added to Shopping.');
      final AiChatProvider provider = _provider(service);

      await provider.send('Add ₹500 for shopping');
      final String cardId = provider.messages.last.id;

      expect(await provider.confirm(cardId), isTrue);
      expect(service.confirms.single.tool, 'create_expense');
      expect(service.confirms.single.args['amount'], 500);
      expect(provider.messages[1].actionState, PendingActionState.confirmed);
      expect(provider.messages.last.text, 'Done. ₹500 was added to Shopping.');
      expect(provider.dataRevision, 1);

      // A second tap does nothing: the card is no longer open.
      expect(await provider.confirm(cardId), isFalse);
      expect(service.confirms.length, 1);
    });

    test('cancel closes the card locally and calls nothing', () async {
      final FakeAiChatService service = FakeAiChatService()
        ..reply('Add ₹500 expense under Shopping?', action: _expenseAction());
      final AiChatProvider provider = _provider(service);
      await provider.send('Add ₹500 for shopping');
      final String cardId = provider.messages.last.id;

      provider.cancel(cardId);
      expect(provider.messages[1].actionState, PendingActionState.cancelled);
      expect(provider.messages.last.text, 'Okay, nothing was saved.');
      expect(service.confirms, isEmpty);
      expect(await provider.confirm(cardId), isFalse);
      expect(provider.dataRevision, 0);
    });

    test('a rejected confirmation is final; a transient failure leaves the card open', () async {
      final FakeAiChatService service = FakeAiChatService()
        ..reply('Transfer ₹5,000 from Savings to Salary Account?', action: _expenseAction())
        ..fail(const AiChatException(AiChatFailure.unavailable, 'Busy.'))
        ..fail(const AiChatException(AiChatFailure.rejected, 'Savings only has ₹4,500 available.'));
      final AiChatProvider provider = _provider(service);
      await provider.send('move 5000');
      final String cardId = provider.messages.last.id;

      expect(await provider.confirm(cardId), isFalse);
      expect(provider.messages[1].actionState, PendingActionState.pending);
      expect(provider.messages[1].actionError, 'Busy.');

      expect(await provider.confirm(cardId), isFalse);
      expect(provider.messages[1].actionState, PendingActionState.failed);
      expect(provider.messages[1].actionError, 'Savings only has ₹4,500 available.');
      expect(service.confirms.length, 2);
      expect(provider.dataRevision, 0);
    });

    test('an expired card cannot be confirmed', () async {
      final FakeAiChatService service = FakeAiChatService()
        ..reply('Add?', action: _expenseAction(expiresAt: _now.subtract(const Duration(minutes: 1))));
      final AiChatProvider provider = _provider(service);
      await provider.send('add 500 shopping');
      expect(await provider.confirm(provider.messages.last.id), isFalse);
      expect(provider.messages.last.actionState, PendingActionState.failed);
      expect(service.confirms, isEmpty);
    });

    test('clear and reset empty the transcript', () async {
      final FakeAiChatService service = FakeAiChatService()..reply('hi');
      final AiChatProvider provider = _provider(service);
      await provider.send('hello');
      provider.clear();
      expect(provider.isEmpty, isTrue);
      provider.reset();
      expect(provider.dataRevision, 0);
    });
  });

  group('AiChatScreen renders', () {
    Future<void> pump(
      WidgetTester tester,
      AiChatProvider provider, {
      double width = 360,
      Brightness brightness = Brightness.light,
    }) async {
      tester.view.physicalSize = Size(width * 3, 780 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ChangeNotifierProvider<AiChatProvider>.value(
          value: provider,
          child: MaterialApp(
            theme: brightness == Brightness.dark ? AppTheme.dark : AppTheme.light,
            home: const AiChatScreen(),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('the empty state shows every suggested prompt at every width, both themes',
        (WidgetTester tester) async {
      for (final Brightness brightness in Brightness.values) {
        for (final double width in <double>[320, 360, 411]) {
          final AiChatProvider provider = _provider(FakeAiChatService());
          await pump(tester, provider, width: width, brightness: brightness);
          expect(tester.takeException(), isNull, reason: '$width $brightness');
          for (final String q in AiChatProvider.suggestedQuestions) {
            expect(find.text(q), findsOneWidget);
          }
          expect(find.text('Ask about your money'), findsOneWidget);
          provider.dispose();
        }
      }
    });

    testWidgets('tapping a question sends it; tapping an action only fills the field',
        (WidgetTester tester) async {
      final FakeAiChatService service = FakeAiChatService()..reply('₹4,000.');
      final AiChatProvider provider = _provider(service);
      await pump(tester, provider);

      await tester.tap(find.text('Add ₹500 for shopping'));
      await tester.pump();
      expect(service.sends, isEmpty);
      expect(find.widgetWithText(TextField, 'Add ₹500 for shopping'), findsOneWidget);

      await tester.tap(find.text('What did I spend this month?'));
      await tester.pump();
      await tester.pump();
      expect(service.sends.single['message'], 'What did I spend this month?');
      expect(find.text('₹4,000.'), findsOneWidget);
      provider.dispose();
    });

    testWidgets('a proposed write renders as a card and Confirm calls the service',
        (WidgetTester tester) async {
      final FakeAiChatService service = FakeAiChatService()
        ..reply('Add ₹500 expense under Shopping?', action: _expenseAction())
        ..reply('Done. ₹500 was added to Shopping.');
      final AiChatProvider provider = _provider(service);
      await provider.send('Add ₹500 for shopping');
      await pump(tester, provider);

      expect(find.text('Add ₹500 expense under Shopping?'), findsOneWidget);
      expect(find.text('Needs confirmation'), findsOneWidget);
      expect(find.text('Confirm'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(service.confirms, isEmpty);

      await tester.tap(find.text('Confirm'));
      await tester.pump();
      await tester.pump();
      expect(service.confirms.length, 1);
      expect(find.text('Saved'), findsOneWidget);
      expect(find.text('Done. ₹500 was added to Shopping.'), findsOneWidget);
      expect(find.text('Confirm'), findsNothing);
      provider.dispose();
    });

    testWidgets('a failed send shows the reason and a Retry control',
        (WidgetTester tester) async {
      final FakeAiChatService service = FakeAiChatService()
        ..fail(const AiChatException(AiChatFailure.unavailable, 'Busy right now.'))
        ..reply('Better now.');
      final AiChatProvider provider = _provider(service);
      await provider.send('balance?');
      await pump(tester, provider);

      expect(find.text('Busy right now.'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Better now.'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
      provider.dispose();
    });

    testWidgets('the transcript renders long content at 320px without overflow',
        (WidgetTester tester) async {
      final FakeAiChatService service = FakeAiChatService()
        ..reply('Your total expenses this month are ₹1,23,45,678.90 across '
            'Food, Transport, Shopping, Bills, Entertainment and Health.');
      final AiChatProvider provider = _provider(service);
      await provider.send('An extraordinarily long question that keeps going and going '
          'well past the width of any phone screen to test wrapping');
      for (final Brightness brightness in Brightness.values) {
        await pump(tester, provider, width: 320, brightness: brightness);
        expect(tester.takeException(), isNull, reason: '$brightness');
      }
      provider.dispose();
    });
  });
}
