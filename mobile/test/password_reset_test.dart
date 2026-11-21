// Password reset from the phone: the address the emailed link lands on, and
// the request screen in every state. The link itself opens the web app's
// reset page (no deep link), whose expired / invalid / success states are
// tested in ui/src/features/auth.

import 'dart:async';

import 'package:expense_tracker/core/config/public_app_url.dart';
import 'package:expense_tracker/core/errors/app_exception.dart';
import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/providers/auth_provider.dart';
import 'package:expense_tracker/repositories/auth_repository.dart';
import 'package:expense_tracker/screens/auth/forgot_password_screen.dart';
import 'package:expense_tracker/screens/auth/login_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Records reset requests; performs no I/O.
class _FakeAuthRepository extends AuthRepository {
  _FakeAuthRepository()
      : super(GoTrueClient(autoRefreshToken: false));

  final List<String> requested = <String>[];

  /// Thrown by [requestPasswordReset] when set.
  AppException? failure;

  /// When set, the request waits for it.
  Completer<void>? gate;

  @override
  Future<void> requestPasswordReset(String email) async {
    requested.add(email);
    final Completer<void>? wait = gate;
    if (wait != null) await wait.future;
    final AppException? error = failure;
    if (error != null) throw error;
  }
}

Widget _wrap(Widget child, AuthProvider auth, {Brightness? brightness}) {
  return ChangeNotifierProvider<AuthProvider>.value(
    value: auth,
    child: MaterialApp(
      theme: brightness == Brightness.dark ? AppTheme.dark : AppTheme.light,
      home: child,
    ),
  );
}

void main() {
  group('PublicAppUrl.resolve', () {
    test('accepts a public https address and trims the slash', () {
      expect(PublicAppUrl.resolve('https://expenses.example.com/'),
          'https://expenses.example.com');
      expect(PublicAppUrl.resolve('  https://example.com/app  '),
          'https://example.com/app');
    });

    test('refuses missing, insecure, loopback and decorated values', () {
      for (final String? value in <String?>[
        null,
        '',
        '   ',
        'not a url',
        'expenses.example.com',
        'http://expenses.example.com',
        'https://localhost:5173',
        'https://127.0.0.1',
        'https://10.0.2.2:5173',
        'https://app.localhost',
        'https://example.com/?x=1',
        'https://example.com/#top',
      ]) {
        expect(PublicAppUrl.resolve(value), isNull, reason: '$value');
      }
    });

    test('builds the reset and confirmation links', () {
      expect(PublicAppUrl.resetPasswordUrl('https://e.example.com'),
          'https://e.example.com/reset-password');
      expect(PublicAppUrl.confirmEmailUrl('https://e.example.com'),
          'https://e.example.com/');
      expect(PublicAppUrl.resetPasswordUrl(null), isNull);
      expect(PublicAppUrl.confirmEmailUrl(null), isNull);
    });

    test('the repository sends reset links to the web reset page', () {
      expect(
        AuthRepository(GoTrueClient(autoRefreshToken: false),
                appUrl: 'https://e.example.com')
            .resetPasswordRedirect,
        'https://e.example.com/reset-password',
      );
      expect(
        AuthRepository(GoTrueClient(autoRefreshToken: false))
            .resetPasswordRedirect,
        isNull,
        reason: 'unset: Supabase uses the Site URL',
      );
    });
  });

  group('ForgotPasswordScreen', () {
    testWidgets('shows the form, prefilled', (WidgetTester tester) async {
      final AuthProvider auth = AuthProvider(_FakeAuthRepository());
      await tester.pumpWidget(_wrap(
        const ForgotPasswordScreen(initialEmail: 'me@example.com'),
        auth,
      ));
      await tester.pump();

      expect(find.text('Reset your password'), findsOneWidget);
      expect(find.text('Send reset link'), findsOneWidget);
      expect(find.text('me@example.com'), findsOneWidget);
      auth.dispose();
    });

    testWidgets('an invalid email never reaches the repository',
        (WidgetTester tester) async {
      final _FakeAuthRepository repository = _FakeAuthRepository();
      final AuthProvider auth = AuthProvider(repository);
      await tester.pumpWidget(_wrap(const ForgotPasswordScreen(), auth));
      await tester.pump();

      await tester.enterText(find.byType(TextFormField), 'nope');
      await tester.tap(find.text('Send reset link'));
      await tester.pump();

      expect(find.text('Enter a valid email address'), findsOneWidget);
      expect(repository.requested, isEmpty);
      auth.dispose();
    });

    testWidgets('shows progress, then the confirmation',
        (WidgetTester tester) async {
      final _FakeAuthRepository repository = _FakeAuthRepository()
        ..gate = Completer<void>();
      final AuthProvider auth = AuthProvider(repository);
      await tester.pumpWidget(_wrap(const ForgotPasswordScreen(), auth));
      await tester.pump();

      await tester.enterText(find.byType(TextFormField), ' me@example.com ');
      await tester.tap(find.text('Send reset link'));
      await tester.pump();

      expect(find.text('Sending…'), findsOneWidget);
      expect(repository.requested, <String>['me@example.com']);

      repository.gate!.complete();
      await tester.pumpAndSettle();

      expect(find.text('Check your email'), findsOneWidget);
      expect(find.textContaining('me@example.com has an account'),
          findsOneWidget);
      expect(find.textContaining('opens a web page'), findsOneWidget);
      expect(find.text('Back to sign in'), findsOneWidget);

      await tester.tap(find.text('Send another link'));
      await tester.pumpAndSettle();
      expect(find.text('Send reset link'), findsOneWidget);
      auth.dispose();
    });

    testWidgets('a failure keeps the form and says why',
        (WidgetTester tester) async {
      final _FakeAuthRepository repository = _FakeAuthRepository()
        ..failure = const AppException(
            'Too many attempts. Please wait a moment and try again.');
      final AuthProvider auth = AuthProvider(repository);
      await tester.pumpWidget(_wrap(const ForgotPasswordScreen(), auth));
      await tester.pump();

      await tester.enterText(find.byType(TextFormField), 'me@example.com');
      await tester.tap(find.text('Send reset link'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Too many attempts'), findsOneWidget);
      expect(find.text('Send reset link'), findsOneWidget);
      expect(find.text('Check your email'), findsNothing);
      auth.dispose();
    });

    testWidgets('opens from sign-in with the typed email',
        (WidgetTester tester) async {
      final AuthProvider auth = AuthProvider(_FakeAuthRepository());
      await tester.pumpWidget(_wrap(const LoginScreen(), auth));
      await tester.pump();

      await tester.enterText(find.byType(TextFormField).first, 'me@example.com');
      await tester.tap(find.text('Forgot password?'));
      await tester.pumpAndSettle();

      expect(find.text('Reset your password'), findsOneWidget);
      expect(find.text('me@example.com'), findsOneWidget);

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Welcome back'), findsOneWidget);
      auth.dispose();
    });

    testWidgets('renders in both themes at the narrowest phone',
        (WidgetTester tester) async {
      for (final Brightness brightness in Brightness.values) {
        tester.view.physicalSize = const Size(320 * 3, 780 * 3);
        tester.view.devicePixelRatio = 3.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final _FakeAuthRepository repository = _FakeAuthRepository();
        final AuthProvider auth = AuthProvider(repository);
        await tester.pumpWidget(_wrap(
          // A fresh screen each pass: the previous one ended on "sent".
          ForgotPasswordScreen(key: ValueKey<Brightness>(brightness)),
          auth,
          brightness: brightness,
        ));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: '$brightness form');

        await tester.enterText(find.byType(TextFormField), 'me@example.com');
        await tester.tap(find.text('Send reset link'));
        await tester.pumpAndSettle();
        expect(find.text('Check your email'), findsOneWidget);
        expect(tester.takeException(), isNull, reason: '$brightness sent');
        auth.dispose();
      }
    });
  });
}
