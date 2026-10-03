// Push notifications on the phone: what the app does with the Android bridge
// and the server — asking for permission only when told, registering this
// phone for the signed-in account, never showing another account's
// notifications, cleaning up on sign-out, and the four shared switches.
//
// The bridge and the database are fakes that record every call; nothing here
// touches a network, Firebase or a real account.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/models/notification_prefs.dart';
import 'package:expense_tracker/providers/notification_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/repositories/notification_repository.dart';
import 'package:expense_tracker/repositories/profile_repository.dart';
import 'package:expense_tracker/screens/settings/notifications_section.dart';
import 'package:expense_tracker/services/preferences_service.dart';
import 'package:expense_tracker/services/push/notification_route.dart';
import 'package:expense_tracker/services/push/push_platform.dart';
import 'package:expense_tracker/services/schema_capabilities.dart';

class FakePushPlatform implements PushPlatform {
  PushDeviceStatus deviceStatus =
      const PushDeviceStatus(available: true, permission: 'notDetermined');
  String answer = 'granted';
  String token = 'token-1';
  bool failToken = false;
  String? launchPath;
  final List<String> calls = <String>[];
  final List<String?> users = <String?>[];
  final StreamController<String> paths = StreamController<String>.broadcast();

  @override
  Future<PushDeviceStatus> status() async {
    calls.add('status');
    return deviceStatus;
  }

  @override
  Future<String> requestPermission() async {
    calls.add('requestPermission');
    deviceStatus = PushDeviceStatus(available: deviceStatus.available, permission: answer);
    return answer;
  }

  @override
  Future<String> getToken() async {
    calls.add('getToken');
    if (failToken) throw const PushPlatformException('failed', 'no token');
    return token;
  }

  @override
  Future<void> deleteToken() async => calls.add('deleteToken');

  @override
  Future<void> setUser(String? userId) async {
    calls.add('setUser');
    users.add(userId);
  }

  @override
  Future<String> timeZone() async => 'Asia/Kolkata';

  @override
  Future<Map<String, String?>> deviceInfo() async =>
      <String, String?>{'device': 'Test Phone', 'appVersion': '1.0.0'};

  @override
  Future<String?> takeLaunchPath() async {
    final String? path = launchPath;
    launchPath = null;
    return path;
  }

  @override
  Future<void> openSettings() async => calls.add('openSettings');

  @override
  Stream<String> get openedPaths => paths.stream;
}

class FakeNotificationRepository extends NotificationRepository {
  FakeNotificationRepository(super.client);

  NotificationPrefs stored = NotificationPrefs.defaults;
  final List<Map<String, Object?>> registered = <Map<String, Object?>>[];
  final List<String> unregistered = <String>[];
  final List<(NotificationPref, bool)> saved = <(NotificationPref, bool)>[];
  bool failSave = false;
  bool failUnregister = false;

  @override
  Future<NotificationPrefs> fetchPrefs(String userId) async => stored;

  @override
  Future<void> savePref(String userId, NotificationPref pref, bool value) async {
    if (failSave) throw StateError('offline');
    saved.add((pref, value));
    stored = stored.withValue(pref, value);
  }

  @override
  Future<void> registerToken({
    required String token,
    required String timezone,
    String? appVersion,
    String? device,
  }) async =>
      registered.add(<String, Object?>{
        'token': token,
        'timezone': timezone,
        'appVersion': appVersion,
        'device': device,
      });

  @override
  Future<void> unregisterToken({required String userId, required String token}) async {
    if (failUnregister) throw StateError('offline');
    unregistered.add('$userId:$token');
  }
}

void main() {
  late FakePushPlatform platform;
  late FakeNotificationRepository repository;
  late PreferencesService preferences;
  late DateTime now;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    preferences = await PreferencesService.create();
    platform = FakePushPlatform();
    repository = FakeNotificationRepository(SupabaseClient(
      'http://localhost:54321',
      'test-anon-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    ));
    now = DateTime(2026, 10, 3, 21, 0);
    SchemaCapabilities.debugReset();
    SchemaCapabilities.debugOverride(notifications: true);
  });

  tearDown(SchemaCapabilities.debugReset);

  NotificationProvider provider() => NotificationProvider(
        platform: platform,
        repository: repository,
        preferences: preferences,
        clock: () => now,
      );

  group('what this phone can do', () {
    test('without the Android bridge, notifications live in the other apps',
        () async {
      platform.deviceStatus = PushDeviceStatus.unsupported;
      final NotificationProvider notifications = provider();
      await notifications.attach('u1');

      expect(notifications.support, PushSupport.unsupported);
      expect(await notifications.enable(), EnableResult.unavailable);
      expect(repository.registered, isEmpty);
      expect(platform.calls, isNot(contains('requestPermission')));
    });

    test('a build without a Firebase project is not set up yet', () async {
      platform.deviceStatus =
          const PushDeviceStatus(available: false, permission: 'granted');
      final NotificationProvider notifications = provider();
      await notifications.attach('u1');

      expect(notifications.support, PushSupport.notConfigured);
      expect(await notifications.enable(), EnableResult.unavailable);
    });

    test('nothing is offered before the migrations exist', () async {
      SchemaCapabilities.debugOverride(notifications: false);
      final NotificationProvider notifications = provider();
      await notifications.attach('u1');

      expect(notifications.available, isFalse);
      expect(await notifications.enable(), EnableResult.unavailable);
    });
  });

  group('turning notifications on and off', () {
    test('asks once, registers this phone with its time zone, and shows only '
        'this account\'s notifications', () async {
      final NotificationProvider notifications = provider();
      await notifications.attach('u1');
      expect(platform.calls, isNot(contains('requestPermission')),
          reason: 'opening the app never asks');

      expect(await notifications.enable(), EnableResult.enabled);
      expect(platform.calls.where((String c) => c == 'requestPermission'), hasLength(1));
      expect(repository.registered.single, <String, Object?>{
        'token': 'token-1',
        'timezone': 'Asia/Kolkata',
        'appVersion': '1.0.0',
        'device': 'Test Phone',
      });
      expect(platform.users.last, 'u1');
      expect(preferences.pushUser, 'u1');
      expect(notifications.enabledHere, isTrue);
    });

    test('a refusal registers nothing; whether to ask again is Android\'s call',
        () async {
      platform.answer = 'denied';
      final NotificationProvider notifications = provider();
      await notifications.attach('u1');

      expect(await notifications.enable(), EnableResult.denied);
      expect(platform.calls, isNot(contains('getToken')));
      expect(repository.registered, isEmpty);
      expect(notifications.enabledHere, isFalse);
      expect(notifications.permission, 'denied');

      // Settings offers "Open settings" from here on; a second tap would go
      // to Android, which shows its prompt again only if it still may.
      await notifications.enable();
      expect(platform.calls.where((String c) => c == 'requestPermission'), hasLength(2));
      expect(repository.registered, isEmpty);
    });

    test('turning off stops this phone at once, then removes the token',
        () async {
      final NotificationProvider notifications = provider();
      await notifications.attach('u1');
      await notifications.enable();
      platform.calls.clear();

      await notifications.disable();
      expect(platform.calls.first, 'setUser');
      expect(platform.users.last, isNull);
      expect(repository.unregistered, <String>['u1:token-1']);
      expect(platform.calls.last, 'deleteToken');
      expect(preferences.pushUser, isNull);
      expect(notifications.enabledHere, isFalse);
    });

    test('turning off still deletes the token when the server cannot be told',
        () async {
      final NotificationProvider notifications = provider();
      await notifications.attach('u1');
      await notifications.enable();
      repository.failUnregister = true;

      await expectLater(notifications.disable(), throwsA(isA<StateError>()));
      expect(platform.calls.last, 'deleteToken');
      expect(platform.users.last, isNull);
      expect(preferences.pushUser, isNull);
    });
  });

  group('keeping a phone registered', () {
    test('coming back renews it at most once an hour', () async {
      final NotificationProvider notifications = provider();
      await notifications.attach('u1');
      await notifications.enable();
      expect(repository.registered, hasLength(1));

      now = now.add(const Duration(minutes: 10));
      await notifications.sync();
      expect(repository.registered, hasLength(1));

      // Firebase may replace a token; the new one is registered.
      platform.token = 'token-2';
      now = now.add(const Duration(minutes: 55));
      await notifications.sync();
      expect(repository.registered.map((Map<String, Object?> r) => r['token']),
          <String>['token-1', 'token-2']);
      expect(preferences.pushToken, 'token-2');
    });

    test('a phone blocked in Android settings is not registered, and says so',
        () async {
      final NotificationProvider notifications = provider();
      await notifications.attach('u1');
      await notifications.enable();
      platform.deviceStatus =
          const PushDeviceStatus(available: true, permission: 'denied');

      await notifications.sync(force: true);
      expect(repository.registered, hasLength(1));
      expect(notifications.blockedHere, isTrue);
      expect(notifications.enabledHere, isFalse);
    });

    test('a failed renewal is tried again on the next resume', () async {
      final NotificationProvider notifications = provider();
      await notifications.attach('u1');
      await notifications.enable();
      platform.failToken = true;

      now = now.add(const Duration(hours: 2));
      await notifications.sync();
      platform.failToken = false;
      await notifications.sync();
      expect(repository.registered, hasLength(2));
    });
  });

  group('one account per phone', () {
    test('signing out removes the token while the session exists, and never '
        'throws', () async {
      final NotificationProvider notifications = provider();
      await notifications.attach('u1');
      await notifications.enable();
      repository.failUnregister = true;

      await notifications.releaseForSignOut();
      expect(platform.users.last, isNull);
      expect(platform.calls.last, 'deleteToken');
      expect(preferences.pushUser, isNull);
    });

    test('after a session ends the phone shows nothing; the same user signing '
        'back in renews it, another user starts with it off', () async {
      final NotificationProvider notifications = provider();
      await notifications.attach('u1');
      await notifications.enable();

      notifications.reset();
      await Future<void>.delayed(Duration.zero);
      expect(platform.users.last, isNull);

      await notifications.attach('u2');
      expect(repository.registered, hasLength(1), reason: 'not for another account');
      expect(notifications.enabledHere, isFalse);

      notifications.reset();
      await notifications.attach('u1');
      expect(repository.registered, hasLength(2));
      expect(platform.users.last, 'u1');
      expect(notifications.enabledHere, isTrue);
    });
  });

  group('the four switches', () {
    test('are read for the account and saved for every device', () async {
      repository.stored = const NotificationPrefs(summary: false);
      final NotificationProvider notifications = provider();
      await notifications.attach('u1');
      expect(notifications.prefs.summary, isFalse);
      expect(notifications.prefs.daily, isTrue);

      expect(await notifications.setPref(NotificationPref.daily, false), isTrue);
      expect(notifications.prefs.daily, isFalse);
      expect(repository.saved.single, (NotificationPref.daily, false));
    });

    test('a switch whose save failed goes back', () async {
      repository.failSave = true;
      final NotificationProvider notifications = provider();
      await notifications.attach('u1');

      expect(await notifications.setPref(NotificationPref.lowBalance, false), isFalse);
      expect(notifications.prefs.lowBalance, isTrue);
      expect(notifications.errorMessage, isNotNull);
    });

    test('read from the table as the server reads them: missing means on', () {
      expect(NotificationPrefs.fromMap(null).cardDue, isTrue);
      final NotificationPrefs prefs = NotificationPrefs.fromMap(
          <String, dynamic>{'daily_reminder': false, 'card_due': null});
      expect(prefs.daily, isFalse);
      expect(prefs.cardDue, isTrue);
    });
  });

  group('Settings → Notifications', () {
    Future<NotificationProvider> pump(
      WidgetTester tester,
      double width,
      Future<void> Function(NotificationProvider) prepare,
    ) async {
      tester.view.physicalSize = Size(width * 2, 720 * 2);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final NotificationProvider notifications = provider();
      await tester.runAsync(() => prepare(notifications));
      final SettingsProvider settings = SettingsProvider(
        repository: ProfileRepository(SupabaseClient(
          'http://localhost:54321',
          'test-anon-key',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        )),
        preferences: preferences,
      );
      await tester.pumpWidget(MultiProvider(
        providers: <ChangeNotifierProvider<dynamic>>[
          ChangeNotifierProvider<NotificationProvider>.value(value: notifications),
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          home: const Scaffold(
            body: SingleChildScrollView(
              padding: EdgeInsets.all(16),
              child: NotificationsSection(),
            ),
          ),
        ),
      ));
      await tester.pump();
      return notifications;
    }

    for (final double width in <double>[320, 360, 411]) {
      testWidgets('offers Turn on and the four switches at $width dp',
          (WidgetTester tester) async {
        await pump(tester, width, (NotificationProvider n) => n.attach('u1'));
        expect(find.text('Turn on notifications'), findsOneWidget);
        expect(find.text('Turn on'), findsOneWidget);
        expect(find.text('Daily expense reminder'), findsOneWidget);
        expect(find.text('Spending summary'), findsOneWidget);
        expect(find.text('Low bank balance'), findsOneWidget);
        expect(find.text('When an account drops below ₹500'), findsOneWidget);
        expect(find.text('Credit card due reminder'), findsOneWidget);
        expect(find.byType(Switch), findsNWidgets(4));
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('says when this phone has them on, blocked or not set up',
        (WidgetTester tester) async {
      await pump(tester, 360, (NotificationProvider n) async {
        await n.attach('u1');
        await n.enable();
      });
      expect(find.text('On for this phone'), findsOneWidget);
      expect(find.text('Turn off'), findsOneWidget);
    });

    testWidgets('a blocked phone is sent to Android settings',
        (WidgetTester tester) async {
      platform.deviceStatus =
          const PushDeviceStatus(available: true, permission: 'denied');
      await pump(tester, 360, (NotificationProvider n) => n.attach('u1'));
      expect(find.text('Blocked on this phone'), findsOneWidget);
      await tester.tap(find.text('Open settings'));
      await tester.runAsync(() async {});
      expect(platform.calls, contains('openSettings'));
    });

    testWidgets('a build without Firebase says it is not set up',
        (WidgetTester tester) async {
      platform.deviceStatus =
          const PushDeviceStatus(available: false, permission: 'granted');
      await pump(tester, 360, (NotificationProvider n) => n.attach('u1'));
      expect(find.text('Not set up yet'), findsOneWidget);
      expect(find.text('Turn on'), findsNothing);
    });

    testWidgets('is hidden until the migrations exist',
        (WidgetTester tester) async {
      SchemaCapabilities.debugOverride(notifications: false);
      await pump(tester, 360, (NotificationProvider n) => n.attach('u1'));
      expect(find.text('Notifications'), findsNothing);
      expect(find.byType(Switch), findsNothing);
    });
  });

  group('a tapped notification', () {
    test('hands its page to the shell once — from a launch or while running',
        () async {
      platform.launchPath = '/reports';
      final NotificationProvider notifications = provider();
      await notifications.collectLaunchPath();
      expect(notifications.takePendingPath(), '/reports');
      expect(notifications.takePendingPath(), isNull);

      platform.paths.add('/accounts/abc-123');
      await Future<void>.delayed(Duration.zero);
      expect(notifications.takePendingPath(), '/accounts/abc-123');
    });

    test('opens only pages inside the app', () {
      expect(NotificationRoute.parse('/expenses/new').destination,
          NotificationDestination.addExpense);
      expect(NotificationRoute.parse('/reports').destination,
          NotificationDestination.reports);
      final NotificationRoute account =
          NotificationRoute.parse('/accounts/3f2a-77');
      expect(account.destination, NotificationDestination.account);
      expect(account.id, '3f2a-77');
      expect(NotificationRoute.parse('/cards/c1').id, 'c1');
      for (final String? path in <String?>[
        null,
        '',
        '//evil.example/x',
        'https://evil.example',
        '/accounts/../../etc',
        '/cards/',
        '/settings',
      ]) {
        expect(NotificationRoute.parse(path).destination,
            NotificationDestination.home,
            reason: '$path');
      }
    });
  });
}
