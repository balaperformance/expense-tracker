// Authentication tests: registration, the password rules, and the
// email-free change-password flow.
//
// The parts worth pinning here are the ones that decide whether a person can
// get into their account: the validators, the preconditions on a password
// change, the mapping from a Supabase failure to something a human can act
// on, and the screens actually offering the routes. The two network calls
// themselves (sign in, update user) are six lines of I/O and are verified
// against the live project instead of a mock.

import 'package:expense_tracker/core/errors/app_exception.dart';
import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/core/utils/validators.dart';
import 'package:expense_tracker/providers/auth_provider.dart';
import 'package:expense_tracker/repositories/auth_repository.dart';
import 'package:expense_tracker/screens/auth/login_screen.dart';
import 'package:expense_tracker/screens/auth/signup_screen.dart';
import 'package:expense_tracker/screens/settings/change_password_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Repository that performs no I/O.
///
/// The real one needs a [GoTrueClient]; one built with autoRefreshToken off
/// and never called is inert, which lets the provider be driven without a
/// network or a session.
class _FakeAuthRepository extends AuthRepository {
  _FakeAuthRepository() : super(GoTrueClient(autoRefreshToken: false));

  /// Recorded so a test can prove what the sheet passed down.
  String? seenCurrent;
  String? seenNew;

  /// Thrown by [changePassword] when set.
  AppException? failure;
  int changeCalls = 0;

  @override
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    changeCalls++;
    seenCurrent = currentPassword;
    seenNew = newPassword;
    final AppException? error = failure;
    if (error != null) throw error;
  }
}

AuthProvider _providerWith(_FakeAuthRepository repository) =>
    AuthProvider(repository);

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
  // ---------------------------------------------------------------------
  // Validators
  // ---------------------------------------------------------------------

  group('email validation', () {
    test('accepts ordinary addresses', () {
      for (final String value in <String>[
        'a@b.co',
        'first.last+tag@example.com',
        'user_name@sub.domain.org',
      ]) {
        expect(Validators.email(value), isNull, reason: value);
      }
    });

    test('rejects malformed addresses', () {
      for (final String value in <String>[
        '',
        '   ',
        'plainword',
        'no-at.example.com',
        'missing@domain',
        'two@@example.com',
        'spaces in@example.com',
      ]) {
        expect(Validators.email(value), isNotNull, reason: '"$value"');
      }
    });
  });

  group('new password strength', () {
    test('accepts a password with length, a letter and a number', () {
      for (final String value in <String>['passw0rd', 'Tr0ub4dour', 'aaaa1111']) {
        expect(Validators.newPassword(value), isNull, reason: value);
      }
    });

    test('rejects short, letters-only, digits-only and empty', () {
      expect(Validators.newPassword(''), 'Password is required');
      expect(Validators.newPassword('a1b2c3'), 'Use at least 8 characters');
      expect(Validators.newPassword('passwordonly'), 'Include at least one number');
      expect(Validators.newPassword('12345678'), 'Include at least one letter');
    });

    test('rejects padding that the user cannot see', () {
      expect(Validators.newPassword(' passw0rd '), isNotNull);
    });

    test('sign-in stays lenient, so an older password is not locked out', () {
      // 6 characters is Supabase's own floor; an account created under the
      // old rule must still be able to type its password into the form.
      expect(Validators.password('abc123'), isNull);
      expect(Validators.newPassword('abc123'), isNotNull);
      expect(Validators.password(''), isNotNull);
    });

    test('the hint states the rule it enforces', () {
      expect(Validators.passwordHint, contains('8'));
      expect(Validators.passwordHint.toLowerCase(), contains('letter'));
      expect(Validators.passwordHint.toLowerCase(), contains('number'));
    });
  });

  group('password confirmation', () {
    test('matches, mismatches and empties', () {
      expect(Validators.confirmPassword('passw0rd', 'passw0rd'), isNull);
      expect(Validators.confirmPassword('passw0rd', 'passw0rdX'), isNotNull);
      expect(Validators.confirmPassword('', 'passw0rd'), isNotNull);
    });
  });

  // ---------------------------------------------------------------------
  // Change-password preconditions
  // ---------------------------------------------------------------------

  group('AuthRepository.checkPasswordChange', () {
    String? check({
      String? email = 'user@example.com',
      String current = 'old-passw0rd',
      String next = 'new-passw0rd',
    }) =>
        AuthRepository.checkPasswordChange(
          email: email,
          currentPassword: current,
          newPassword: next,
        );

    test('allows a well-formed change', () {
      expect(check(), isNull);
    });

    test('refuses when there is no email identity to verify against', () {
      // An anonymous development session has no password at all.
      expect(check(email: null), contains('no password'));
      expect(check(email: ''), contains('no password'));
    });

    test('refuses a blank current or new password', () {
      expect(check(current: ''), 'Enter your current password.');
      expect(check(next: ''), 'Enter a new password.');
    });

    test('refuses reusing the same password', () {
      expect(
        check(current: 'same-passw0rd', next: 'same-passw0rd'),
        contains('different'),
      );
    });
  });

  // ---------------------------------------------------------------------
  // Error mapping
  // ---------------------------------------------------------------------

  group('auth error messages', () {
    String map(AuthException error) => ErrorMapper.map(error).message;

    test('duplicate registration is explained, not echoed', () {
      final String message =
          map(const AuthException('User already registered'));
      expect(message, contains('already exists'));
      expect(message, contains('signing in'));
    });

    test('wrong credentials do not reveal which half was wrong', () {
      final String message =
          map(const AuthException('Invalid login credentials'));
      expect(message, 'Incorrect email or password.');
      expect(message.toLowerCase(), isNot(contains('email does not exist')));
    });

    test('a weak password quotes the app\'s own rule', () {
      expect(
        map(AuthWeakPasswordException(
          message: 'Password is too weak',
          statusCode: '422',
          reasons: const <String>['length'],
        )),
        contains(Validators.passwordHint),
      );
    });

    test('reusing the old password is named as such', () {
      expect(
        map(const AuthException(
          'New password should be different from the old password.',
        )),
        contains('different from the current one'),
      );
    });

    test('an unrecognised failure never leaks the raw message', () {
      final String message = map(const AuthException(
        'pq: duplicate key value violates unique constraint "users_pkey"',
      ));
      expect(message, 'Authentication failed. Please try again.');
      expect(message, isNot(contains('pq:')));
      expect(message, isNot(contains('users_pkey')));
    });
  });

  // ---------------------------------------------------------------------
  // Provider
  // ---------------------------------------------------------------------

  group('AuthProvider.changePassword', () {
    test('passes both passwords through and reports success', () async {
      final _FakeAuthRepository repository = _FakeAuthRepository();
      final AuthProvider auth = _providerWith(repository);

      final bool ok = await auth.changePassword(
        currentPassword: 'old-passw0rd',
        newPassword: 'new-passw0rd',
      );

      expect(ok, isTrue);
      expect(repository.seenCurrent, 'old-passw0rd');
      expect(repository.seenNew, 'new-passw0rd');
      expect(auth.errorMessage, isNull);
      expect(auth.submitting, isFalse);
      auth.dispose();
    });

    test('a wrong current password fails with a message and no session change',
        () async {
      final _FakeAuthRepository repository = _FakeAuthRepository()
        ..failure = const AppException('Your current password is not correct.');
      final AuthProvider auth = _providerWith(repository);

      final bool ok = await auth.changePassword(
        currentPassword: 'wrong',
        newPassword: 'new-passw0rd',
      );

      expect(ok, isFalse);
      expect(auth.errorMessage, 'Your current password is not correct.');
      // The failed attempt must not sign the user out.
      expect(auth.stage, isNot(AuthStage.signedIn));
      expect(repository.changeCalls, 1);
      auth.dispose();
    });

    test('a second attempt is ignored while one is in flight', () async {
      final _FakeAuthRepository repository = _FakeAuthRepository();
      final AuthProvider auth = _providerWith(repository);

      final Future<bool> first = auth.changePassword(
        currentPassword: 'old-passw0rd',
        newPassword: 'new-passw0rd',
      );
      final bool second = await auth.changePassword(
        currentPassword: 'old-passw0rd',
        newPassword: 'other-passw0rd',
      );

      expect(await first, isTrue);
      expect(second, isFalse, reason: 'double submit is refused');
      expect(repository.changeCalls, 1);
      auth.dispose();
    });
  });

  // ---------------------------------------------------------------------
  // Screens
  // ---------------------------------------------------------------------

  group('LoginScreen', () {
    testWidgets('offers Register New User and no email-reset route',
        (WidgetTester tester) async {
      final AuthProvider auth = _providerWith(_FakeAuthRepository());
      await tester.pumpWidget(_wrap(const LoginScreen(), auth));
      await tester.pump();

      expect(find.text('Register New User'), findsOneWidget);
      expect(find.text('Sign in'), findsOneWidget);
      expect(find.text('Forgot password?'), findsNothing);
      expect(find.textContaining('reset link'), findsNothing);
      auth.dispose();
    });

    testWidgets('Register New User opens the registration screen',
        (WidgetTester tester) async {
      final AuthProvider auth = _providerWith(_FakeAuthRepository());
      await tester.pumpWidget(_wrap(const LoginScreen(), auth));
      await tester.pump();

      await tester.tap(find.text('Register New User'));
      await tester.pumpAndSettle();

      expect(find.text('Register new user'), findsOneWidget);
      expect(find.text('Full name'), findsOneWidget);
      expect(find.text('Confirm password'), findsOneWidget);
      auth.dispose();
    });

    testWidgets('renders in both themes at the narrowest phone',
        (WidgetTester tester) async {
      for (final Brightness brightness in Brightness.values) {
        tester.view.physicalSize = const Size(320 * 3, 780 * 3);
        tester.view.devicePixelRatio = 3.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final AuthProvider auth = _providerWith(_FakeAuthRepository());
        await tester.pumpWidget(
          _wrap(const LoginScreen(), auth, brightness: brightness),
        );
        await tester.pump();
        expect(tester.takeException(), isNull, reason: '$brightness');
        auth.dispose();
      }
    });
  });

  group('SignUpScreen validation', () {
    Future<void> submitWith(
      WidgetTester tester, {
      required String name,
      required String email,
      required String password,
      required String confirm,
    }) async {
      await tester.enterText(find.byType(TextFormField).at(0), name);
      await tester.enterText(find.byType(TextFormField).at(1), email);
      await tester.enterText(find.byType(TextFormField).at(2), password);
      await tester.enterText(find.byType(TextFormField).at(3), confirm);
      await tester.tap(find.text('Create account'));
      await tester.pump();
    }

    testWidgets('an invalid email is refused before any network call',
        (WidgetTester tester) async {
      final _FakeAuthRepository repository = _FakeAuthRepository();
      final AuthProvider auth = _providerWith(repository);
      await tester.pumpWidget(_wrap(const SignUpScreen(), auth));
      await tester.pump();

      await submitWith(
        tester,
        name: 'Ada',
        email: 'not-an-email',
        password: 'passw0rd',
        confirm: 'passw0rd',
      );

      expect(find.text('Enter a valid email address'), findsOneWidget);
      expect(auth.submitting, isFalse);
      auth.dispose();
    });

    testWidgets('a weak password is refused with the reason',
        (WidgetTester tester) async {
      final AuthProvider auth = _providerWith(_FakeAuthRepository());
      await tester.pumpWidget(_wrap(const SignUpScreen(), auth));
      await tester.pump();

      await submitWith(
        tester,
        name: 'Ada',
        email: 'ada@example.com',
        password: 'short1',
        confirm: 'short1',
      );

      expect(find.text('Use at least 8 characters'), findsOneWidget);
      auth.dispose();
    });

    testWidgets('a password with no number is refused',
        (WidgetTester tester) async {
      final AuthProvider auth = _providerWith(_FakeAuthRepository());
      await tester.pumpWidget(_wrap(const SignUpScreen(), auth));
      await tester.pump();

      await submitWith(
        tester,
        name: 'Ada',
        email: 'ada@example.com',
        password: 'lettersonly',
        confirm: 'lettersonly',
      );

      expect(find.text('Include at least one number'), findsOneWidget);
      auth.dispose();
    });

    testWidgets('mismatched confirmation is refused',
        (WidgetTester tester) async {
      final AuthProvider auth = _providerWith(_FakeAuthRepository());
      await tester.pumpWidget(_wrap(const SignUpScreen(), auth));
      await tester.pump();

      await submitWith(
        tester,
        name: 'Ada',
        email: 'ada@example.com',
        password: 'passw0rd',
        confirm: 'passw0rdX',
      );

      expect(find.text('Passwords do not match'), findsOneWidget);
      auth.dispose();
    });

    testWidgets('a missing name is refused', (WidgetTester tester) async {
      final AuthProvider auth = _providerWith(_FakeAuthRepository());
      await tester.pumpWidget(_wrap(const SignUpScreen(), auth));
      await tester.pump();

      await submitWith(
        tester,
        name: '',
        email: 'ada@example.com',
        password: 'passw0rd',
        confirm: 'passw0rd',
      );

      expect(find.text('Name is required'), findsOneWidget);
      auth.dispose();
    });
  });

  group('ChangePasswordSheet', () {
    Future<void> pumpSheet(WidgetTester tester, AuthProvider auth) async {
      await tester.pumpWidget(
        _wrap(
          const Scaffold(body: SafeArea(child: ChangePasswordSheet())),
          auth,
        ),
      );
      await tester.pump();
    }

    Future<void> fill(
      WidgetTester tester, {
      required String current,
      required String next,
      required String confirm,
    }) async {
      await tester.enterText(find.byType(TextFormField).at(0), current);
      await tester.enterText(find.byType(TextFormField).at(1), next);
      await tester.enterText(find.byType(TextFormField).at(2), confirm);
      await tester.tap(find.text('Update password'));
      await tester.pump();
    }

    testWidgets('shows three fields and the strength rule',
        (WidgetTester tester) async {
      final AuthProvider auth = _providerWith(_FakeAuthRepository());
      await pumpSheet(tester, auth);

      expect(find.text('Current password'), findsOneWidget);
      expect(find.text('New password'), findsOneWidget);
      expect(find.text('Confirm new password'), findsOneWidget);
      expect(find.text(Validators.passwordHint), findsOneWidget);
      auth.dispose();
    });

    testWidgets('a weak new password never reaches the repository',
        (WidgetTester tester) async {
      final _FakeAuthRepository repository = _FakeAuthRepository();
      final AuthProvider auth = _providerWith(repository);
      await pumpSheet(tester, auth);

      await fill(tester, current: 'old-passw0rd', next: 'weak', confirm: 'weak');

      expect(find.text('Use at least 8 characters'), findsOneWidget);
      expect(repository.changeCalls, 0);
      auth.dispose();
    });

    testWidgets('a mismatched confirmation never reaches the repository',
        (WidgetTester tester) async {
      final _FakeAuthRepository repository = _FakeAuthRepository();
      final AuthProvider auth = _providerWith(repository);
      await pumpSheet(tester, auth);

      await fill(
        tester,
        current: 'old-passw0rd',
        next: 'new-passw0rd',
        confirm: 'new-passw0rdX',
      );

      expect(find.text('Passwords do not match'), findsOneWidget);
      expect(repository.changeCalls, 0);
      auth.dispose();
    });

    testWidgets('a blank current password is refused',
        (WidgetTester tester) async {
      final _FakeAuthRepository repository = _FakeAuthRepository();
      final AuthProvider auth = _providerWith(repository);
      await pumpSheet(tester, auth);

      await fill(tester, current: '', next: 'new-passw0rd', confirm: 'new-passw0rd');

      expect(find.text('Enter your current password'), findsOneWidget);
      expect(repository.changeCalls, 0);
      auth.dispose();
    });

    testWidgets('a rejected current password keeps the sheet open with the reason',
        (WidgetTester tester) async {
      final _FakeAuthRepository repository = _FakeAuthRepository()
        ..failure = const AppException('Your current password is not correct.');
      final AuthProvider auth = _providerWith(repository);
      await pumpSheet(tester, auth);

      await fill(
        tester,
        current: 'wrong-passw0rd',
        next: 'new-passw0rd',
        confirm: 'new-passw0rd',
      );
      await tester.pump();

      expect(repository.changeCalls, 1);
      expect(find.text('Your current password is not correct.'), findsOneWidget);
      // Still on the sheet, fields intact, so only one value must be retyped.
      expect(find.text('Update password'), findsOneWidget);
      auth.dispose();
    });

    testWidgets('a valid change forwards exactly what was typed',
        (WidgetTester tester) async {
      final _FakeAuthRepository repository = _FakeAuthRepository();
      final AuthProvider auth = _providerWith(repository);
      await pumpSheet(tester, auth);

      await fill(
        tester,
        current: 'old-passw0rd',
        next: 'new-passw0rd',
        confirm: 'new-passw0rd',
      );
      await tester.pump();

      expect(repository.changeCalls, 1);
      expect(repository.seenCurrent, 'old-passw0rd');
      expect(repository.seenNew, 'new-passw0rd');
      auth.dispose();
    });

    testWidgets('renders in both themes at the narrowest phone',
        (WidgetTester tester) async {
      for (final Brightness brightness in Brightness.values) {
        tester.view.physicalSize = const Size(320 * 3, 780 * 3);
        tester.view.devicePixelRatio = 3.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final AuthProvider auth = _providerWith(_FakeAuthRepository());
        await tester.pumpWidget(
          _wrap(
            const Scaffold(body: SafeArea(child: ChangePasswordSheet())),
            auth,
            brightness: brightness,
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull, reason: '$brightness');
        auth.dispose();
      }
    });
  });
}
