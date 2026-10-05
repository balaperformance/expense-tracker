// The bell's notification history: the rows as the web app reads them,
// optimistic marks that go back when the save fails, a Mark all / Clear that
// changes nothing counted as a failure, Clear keeping unread ones, refreshes
// on a push / resume / timer, and the bell and its sheet.
//
// The database is an in-memory fake; nothing here touches a network or a
// real account.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:expense_tracker/core/errors/app_exception.dart';
import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/models/notification_item.dart';
import 'package:expense_tracker/providers/notification_inbox_provider.dart';
import 'package:expense_tracker/providers/notification_provider.dart';
import 'package:expense_tracker/repositories/notification_repository.dart';
import 'package:expense_tracker/services/preferences_service.dart';
import 'package:expense_tracker/services/schema_capabilities.dart';
import 'package:expense_tracker/widgets/common/notification_bell.dart';

import 'notifications_test.dart' show FakePushPlatform;

SupabaseClient _client() => SupabaseClient(
      'http://localhost:54321',
      'test-anon-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );

/// The user's `notification_log` rows, in memory.
class FakeInboxRepository extends NotificationRepository {
  FakeInboxRepository() : super(_client());

  final List<FakeRow> rows = <FakeRow>[];
  final List<String> calls = <String>[];
  int fetches = 0;

  bool failFetch = false;
  bool failSave = false;

  /// Forces the changed count an update reports (e.g. 0: applied to nothing).
  int? changedOverride;

  /// Holds saves (or fetches) until completed.
  Completer<void>? saveGate;
  Completer<void>? fetchGate;

  void add(String key, {required DateTime sentAt, bool read = false, String? url, String kind = 'daily', String? title}) {
    rows.add(FakeRow(key, kind, sentAt, read, url, title ?? 'Title $key'));
  }

  FakeRow row(String key) => rows.firstWhere((FakeRow r) => r.key == key);

  @override
  Future<List<NotificationItem>> fetchInbox(String userId) async {
    fetches++;
    calls.add('fetch');
    final List<NotificationItem> snapshot = <NotificationItem>[
      for (final FakeRow r in rows)
        if (!r.cleared) r.item,
    ];
    await fetchGate?.future;
    if (failFetch) throw const AppException('No internet connection.');
    return snapshot..sort(NotificationItem.newestFirst);
  }

  Future<int> _update(String call, Iterable<FakeRow> targets, void Function(FakeRow) apply) async {
    calls.add(call);
    await saveGate?.future;
    if (failSave) throw const AppException('No internet connection.');
    // An update the database accepted but applied to nothing changes nothing.
    final int? forced = changedOverride;
    if (forced != null) return forced;
    final List<FakeRow> changed = targets.toList();
    changed.forEach(apply);
    return changed.length;
  }

  @override
  Future<int> markInboxRead(String userId, String key) => _update(
      'markRead:$key',
      rows.where((FakeRow r) => r.key == key && !r.read),
      (FakeRow r) => r.read = true);

  @override
  Future<int> markAllInboxRead(String userId) => _update(
      'markAllRead', rows.where((FakeRow r) => !r.read), (FakeRow r) => r.read = true);

  @override
  Future<int> clearReadInbox(String userId) => _update(
      'clearRead',
      rows.where((FakeRow r) => r.read && !r.cleared),
      (FakeRow r) => r.cleared = true);
}

class FakeRow {
  FakeRow(this.key, this.kind, this.sentAt, this.read, this.url, this.title);

  final String key;
  final String kind;
  final DateTime sentAt;
  bool read;
  bool cleared = false;
  final String? url;
  final String title;

  NotificationItem get item => NotificationItem(
        key: key,
        kind: kind,
        title: title,
        body: 'Body $key',
        path: NotificationItem.safePath(url),
        sentAt: sentAt,
        read: read,
      );
}

/// Lets queued futures (and the refresh after a save) finish.
Future<void> settle() async {
  for (int i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late FakeInboxRepository repository;
  late StreamController<void> pushes;

  setUp(() {
    repository = FakeInboxRepository()
      ..add('a', sentAt: DateTime(2026, 10, 5, 22), url: '/reports')
      ..add('b', sentAt: DateTime(2026, 10, 4, 20), kind: 'lowBalance')
      ..add('c', sentAt: DateTime(2026, 10, 3, 9), read: true);
    pushes = StreamController<void>.broadcast();
    SchemaCapabilities.debugReset();
    SchemaCapabilities.debugOverride(notificationInbox: true, notificationClear: true);
  });

  tearDown(() {
    SchemaCapabilities.debugReset();
    pushes.close();
  });

  NotificationInboxProvider provider({Duration? every}) {
    final NotificationInboxProvider inbox = NotificationInboxProvider(
      repository: repository,
      pushes: pushes.stream,
      observeLifecycle: false,
      refreshEvery: every ?? NotificationInboxProvider.refreshInterval,
    );
    inbox.attachUser('u1');
    return inbox;
  }

  Future<NotificationInboxProvider> loaded({Duration? every}) async {
    final NotificationInboxProvider inbox = provider(every: every);
    inbox.activate();
    await settle();
    return inbox;
  }

  group('the rows, as the web app reads them', () {
    test('a generic or missing title reads as its kind; only in-app paths', () {
      final NotificationItem? item = NotificationItem.fromRow(<String, dynamic>{
        'event_key': 'daily:2026-10-05',
        'kind': 'daily',
        'sent_at': '2026-10-05T16:30:00+00:00',
        'title': 'Expense Tracker',
        'body': '  Add today’s expenses  ',
        'url': 'https://evil.example',
        'read_at': null,
      });
      expect(item, isNotNull);
      expect(item!.title, 'Daily expense reminder');
      expect(item.body, 'Add today’s expenses');
      expect(item.path, isNull);
      expect(item.read, isFalse);
      expect(item.sentAt, DateTime.parse('2026-10-05T16:30:00Z').toLocal());

      final NotificationItem other = NotificationItem.fromRow(<String, dynamic>{
        'event_key': 'x',
        'kind': 'somethingNew',
        'sent_at': '2026-10-05T16:30:00Z',
        'title': 'Low balance in HDFC',
        'url': '/accounts/a1',
        'read_at': '2026-10-05T17:00:00Z',
      })!;
      expect(other.title, 'Low balance in HDFC');
      expect(other.path, '/accounts/a1');
      expect(other.read, isTrue);
      expect(NotificationItem.kindLabel('somethingNew'), 'Notification');

      for (final String? path in <String?>[null, '', 'reports', '//evil.example', '/${'x' * 200}']) {
        expect(NotificationItem.safePath(path), isNull, reason: '$path');
      }
    });

    test('malformed rows are dropped; newest first', () {
      final List<NotificationItem> items = NotificationItem.fromRows(<Map<String, dynamic>>[
        <String, dynamic>{'event_key': 'old', 'kind': 'daily', 'sent_at': '2026-10-01T10:00:00Z'},
        <String, dynamic>{'event_key': '', 'kind': 'daily', 'sent_at': '2026-10-02T10:00:00Z'},
        <String, dynamic>{'event_key': 'bad', 'kind': 'daily', 'sent_at': 'not a date'},
        <String, dynamic>{'event_key': 'new', 'kind': 'summary', 'sent_at': '2026-10-04T10:00:00Z'},
      ]);
      expect(items.map((NotificationItem i) => i.key), <String>['new', 'old']);
      expect(NotificationItem.unreadCount(items), 2);
      expect(NotificationItem.withRead(items, <String>{'old'}).map((NotificationItem i) => i.read),
          <bool>[false, true]);
      expect(NotificationItem.unreadCount(NotificationItem.withRead(items)), 0);
    });

    test('the badge is the count, capped; nothing for none', () {
      expect(NotificationItem.badgeLabel(0), isNull);
      expect(NotificationItem.badgeLabel(-1), isNull);
      expect(NotificationItem.badgeLabel(1), '1');
      expect(NotificationItem.badgeLabel(99), '99');
      expect(NotificationItem.badgeLabel(100), '99+');
    });

    test('when it was sent, in the phone\'s time', () {
      final DateTime now = DateTime(2026, 10, 5, 23); // a Monday
      expect(NotificationItem.sentLabel(DateTime(2026, 10, 5, 22), now: now), 'Today · 10:00 PM');
      expect(NotificationItem.sentLabel(DateTime(2026, 10, 4, 20), now: now), 'Yesterday · 8:00 PM');
      expect(NotificationItem.sentLabel(DateTime(2026, 10, 1, 9, 5), now: now), 'Thursday · 9:05 AM');
      expect(NotificationItem.sentLabel(DateTime(2026, 3, 12, 9), now: now), '12 Mar · 9:00 AM');
      expect(NotificationItem.sentLabel(DateTime(2025, 3, 12, 0, 30), now: now), '12 Mar 2025 · 12:30 AM');
    });
  });

  group('reading the history', () {
    test('is read once a bell is shown, and counts unread and read', () async {
      final NotificationInboxProvider inbox = provider();
      expect(repository.fetches, 0, reason: 'nothing is read before a bell is shown');
      inbox.activate();
      await settle();
      expect(inbox.loaded, isTrue);
      expect(inbox.items.map((NotificationItem i) => i.key), <String>['a', 'b', 'c']);
      expect(inbox.unreadCount, 2);
      expect(inbox.readCount, 1);
      expect(inbox.badge, '2');

      inbox.activate();
      await settle();
      expect(repository.fetches, 1, reason: 'activating again reads nothing more');
      inbox.dispose();
    });

    test('nothing is read before migration 010', () async {
      SchemaCapabilities.debugOverride(notificationInbox: false);
      final NotificationInboxProvider inbox = provider();
      inbox.activate();
      await settle();
      expect(inbox.available, isFalse);
      expect(repository.fetches, 0);
      inbox.dispose();
    });

    test('a failed refresh keeps what is shown', () async {
      final NotificationInboxProvider inbox = await loaded();
      repository.failFetch = true;
      await inbox.refresh();
      expect(inbox.items, hasLength(3));
      expect(inbox.hasError, isTrue);
      inbox.dispose();
    });

    test('another account\'s notifications are never kept', () async {
      final NotificationInboxProvider inbox = await loaded();
      inbox.attachUser('u2');
      expect(inbox.items, isEmpty);
      expect(inbox.loaded, isFalse);
      inbox.attachUser(null);
      inbox.activate();
      await settle();
      expect(repository.fetches, 1, reason: 'nobody is signed in');
      inbox.dispose();
    });
  });

  group('marking read', () {
    test('one shows at once, and goes back if the save fails', () async {
      final NotificationInboxProvider inbox = await loaded();
      repository.saveGate = Completer<void>();
      repository.failSave = true;

      final Future<String?> result = inbox.markRead('a');
      expect(inbox.items.first.read, isTrue, reason: 'optimistic');
      expect(inbox.unreadCount, 1);

      repository.saveGate!.complete();
      expect(await result, NotificationInboxProvider.markFailedMessage);
      expect(inbox.items.first.read, isFalse, reason: 'rolled back');
      expect(inbox.unreadCount, 2);
      await settle();
      expect(repository.fetches, 2, reason: 'read again after the save');
      inbox.dispose();
    });

    test('one saves, and one already read elsewhere is not a failure', () async {
      final NotificationInboxProvider inbox = await loaded();
      expect(await inbox.markRead('a'), isNull);
      expect(repository.row('a').read, isTrue);

      // Read on another device since: the update changes nothing.
      repository.row('b').read = true;
      expect(await inbox.markRead('b'), isNull);
      expect(inbox.items[1].read, isTrue);
      expect(await inbox.markRead('c'), isNull, reason: 'already read here');
      expect(repository.calls.where((String c) => c.startsWith('markRead')), hasLength(2));
      inbox.dispose();
    });

    test('Mark all as read marks every one', () async {
      final NotificationInboxProvider inbox = await loaded();
      expect(await inbox.markAllRead(), isNull);
      expect(inbox.unreadCount, 0);
      await settle();
      expect(repository.rows.every((FakeRow r) => r.read), isTrue);
      expect(inbox.unreadCount, 0);
      inbox.dispose();
    });

    test('a Mark all that changes nothing is a failure, and goes back', () async {
      final NotificationInboxProvider inbox = await loaded();
      repository.changedOverride = 0;
      expect(await inbox.markAllRead(), NotificationInboxProvider.markFailedMessage);
      expect(inbox.unreadCount, 2);
      expect(inbox.items.map((NotificationItem i) => i.read), <bool>[false, false, true]);
      inbox.dispose();
    });

    test('a refresh that began before a mark does not undo it', () async {
      final NotificationInboxProvider inbox = await loaded();
      final Completer<void> gate = Completer<void>();
      repository.fetchGate = gate;
      final Future<void> stale = inbox.refresh(); // reads 'a' as unread
      repository.fetchGate = null;
      expect(await inbox.markRead('a'), isNull);
      await settle();
      // The stale read answers only now, after the mark.
      gate.complete();
      await stale;
      expect(inbox.items.first.read, isTrue);
      expect(inbox.unreadCount, 1);
      inbox.dispose();
    });
  });

  group('clearing read ones', () {
    test('keeps unread ones', () async {
      final NotificationInboxProvider inbox = await loaded();
      expect(inbox.canClear, isTrue);
      expect(await inbox.clearRead(), isNull);
      expect(inbox.items.map((NotificationItem i) => i.key), <String>['a', 'b']);
      expect(inbox.items.every((NotificationItem i) => !i.read), isTrue);
      await settle();
      expect(repository.row('c').cleared, isTrue);
      expect(repository.row('a').cleared, isFalse);
      expect(inbox.items.map((NotificationItem i) => i.key), <String>['a', 'b']);
      inbox.dispose();
    });

    test('a Clear that changes nothing is a failure, and the read ones come back',
        () async {
      final NotificationInboxProvider inbox = await loaded();
      repository.changedOverride = 0;
      expect(await inbox.clearRead(), NotificationInboxProvider.clearFailedMessage);
      expect(inbox.items.map((NotificationItem i) => i.key), <String>['a', 'b', 'c']);
      inbox.dispose();
    });

    test('a failed Clear says why', () async {
      final NotificationInboxProvider inbox = await loaded();
      repository.failSave = true;
      expect(await inbox.clearRead(), 'No internet connection.');
      expect(inbox.readCount, 1);
      inbox.dispose();
    });

    test('is not offered before migration 012', () async {
      SchemaCapabilities.debugOverride(notificationClear: false);
      final NotificationInboxProvider inbox = await loaded();
      expect(inbox.canClear, isFalse);
      expect(await inbox.clearRead(), isNull);
      expect(repository.calls, isNot(contains('clearRead')));
      expect(inbox.items, hasLength(3));
      inbox.dispose();
    });
  });

  group('keeping it fresh', () {
    test('a push while in front is read at once; in the background, on resume',
        () async {
      final NotificationInboxProvider inbox = await loaded();
      repository.add('d', sentAt: DateTime(2026, 10, 5, 23));
      pushes.add(null);
      await settle();
      expect(repository.fetches, 2);
      expect(inbox.items.first.key, 'd');
      expect(inbox.unreadCount, 3);

      inbox.paused();
      pushes.add(null);
      await settle();
      expect(repository.fetches, 2);

      inbox.resumed();
      await settle();
      expect(repository.fetches, 3);
      inbox.dispose();
    });

    test('every interval while in front, never in the background', () async {
      final NotificationInboxProvider inbox =
          await loaded(every: const Duration(milliseconds: 20));
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(repository.fetches, greaterThanOrEqualTo(3));

      inbox.paused();
      await settle();
      final int before = repository.fetches;
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(repository.fetches, before);
      inbox.dispose();
    });

    test('a push before any bell was shown reads nothing', () async {
      final NotificationInboxProvider inbox = provider();
      pushes.add(null);
      await settle();
      expect(repository.fetches, 0);
      inbox.dispose();
    });
  });

  group('the bell', () {
    late NotificationProvider notifications;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      notifications = NotificationProvider(
        platform: FakePushPlatform(),
        repository: NotificationRepository(_client()),
        preferences: await PreferencesService.create(),
      );
    });

    Future<NotificationInboxProvider> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(360 * 2, 720 * 2);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final NotificationInboxProvider inbox = provider();
      await tester.pumpWidget(MultiProvider(
        providers: <ChangeNotifierProvider<dynamic>>[
          ChangeNotifierProvider<NotificationProvider>.value(value: notifications),
          ChangeNotifierProvider<NotificationInboxProvider>.value(value: inbox),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            appBar: AppBar(actions: const <Widget>[NotificationBell()]),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return inbox;
    }

    Future<void> done(WidgetTester tester, NotificationInboxProvider inbox) async {
      await tester.pumpWidget(const SizedBox.shrink());
      inbox.dispose();
    }

    testWidgets('says how many are unread', (WidgetTester tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      final NotificationInboxProvider inbox = await pump(tester);
      expect(find.bySemanticsLabel('Notifications, 2 unread'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);

      await inbox.markAllRead();
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Notifications'), findsOneWidget);
      expect(find.text('2'), findsNothing);
      semantics.dispose();
      await done(tester, inbox);
    });

    testWidgets('is hidden before migration 010', (WidgetTester tester) async {
      SchemaCapabilities.debugOverride(notificationInbox: false);
      final NotificationInboxProvider inbox = await pump(tester);
      expect(find.byType(IconButton), findsNothing);
      expect(repository.fetches, 0);
      await done(tester, inbox);
    });

    testWidgets('lists them; tapping one marks it read and opens its page',
        (WidgetTester tester) async {
      final NotificationInboxProvider inbox = await pump(tester);
      await tester.tap(find.byTooltip('Notifications'));
      await tester.pumpAndSettle();

      expect(find.text('Notifications'), findsWidgets);
      expect(find.text('2 unread'), findsOneWidget);
      expect(find.text('Title a'), findsOneWidget);
      expect(find.text('Body b'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('unread-dot')), findsNWidgets(2));
      expect(find.text('Mark all as read'), findsOneWidget);
      expect(find.text('Clear 1 read'), findsOneWidget);

      await tester.tap(find.text('Title a'));
      await tester.pumpAndSettle();
      expect(find.text('Title a'), findsNothing, reason: 'the sheet closed');
      expect(repository.row('a').read, isTrue);
      expect(inbox.unreadCount, 1);
      expect(notifications.takePendingPath(), '/reports');
      await done(tester, inbox);
    });

    testWidgets('one with nowhere to go is marked read and the sheet stays',
        (WidgetTester tester) async {
      final NotificationInboxProvider inbox = await pump(tester);
      await tester.tap(find.byTooltip('Notifications'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Title b'));
      await tester.pumpAndSettle();
      expect(find.text('Title b'), findsOneWidget);
      expect(repository.row('b').read, isTrue);
      expect(notifications.takePendingPath(), isNull);
      await done(tester, inbox);
    });

    testWidgets('Mark all as read, then all caught up', (WidgetTester tester) async {
      final NotificationInboxProvider inbox = await pump(tester);
      await tester.tap(find.byTooltip('Notifications'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mark all as read'));
      await tester.pumpAndSettle();
      expect(find.text('Mark all as read'), findsNothing);
      expect(find.text('You’re all caught up'), findsOneWidget);
      expect(find.text('Clear 3 read'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('unread-dot')), findsNothing);
      await done(tester, inbox);
    });

    testWidgets('a Mark all that fails says so in the sheet and goes back',
        (WidgetTester tester) async {
      final NotificationInboxProvider inbox = await pump(tester);
      await tester.tap(find.byTooltip('Notifications'));
      await tester.pumpAndSettle();
      repository.changedOverride = 0;
      await tester.tap(find.text('Mark all as read'));
      await tester.pumpAndSettle();
      expect(find.text(NotificationInboxProvider.markFailedMessage), findsOneWidget);
      expect(find.text('2 unread'), findsOneWidget);
      await done(tester, inbox);
    });

    testWidgets('Clear asks first, and unread ones stay', (WidgetTester tester) async {
      final NotificationInboxProvider inbox = await pump(tester);
      await tester.tap(find.byTooltip('Notifications'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear 1 read'));
      await tester.pumpAndSettle();
      expect(find.text('Clear 1 read notification?'), findsOneWidget);
      expect(find.text('They leave this list. Your 2 unread notifications stay.'),
          findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(repository.calls, isNot(contains('clearRead')));
      expect(find.text('Title c'), findsOneWidget);

      await tester.tap(find.text('Clear 1 read'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();
      expect(repository.row('c').cleared, isTrue);
      expect(find.text('Title c'), findsNothing);
      expect(find.text('Title a'), findsOneWidget);
      expect(find.text('Title b'), findsOneWidget);
      expect(find.textContaining('Clear '), findsNothing);
      await done(tester, inbox);
    });

    testWidgets('no Clear before migration 012', (WidgetTester tester) async {
      SchemaCapabilities.debugOverride(notificationClear: false);
      final NotificationInboxProvider inbox = await pump(tester);
      await tester.tap(find.byTooltip('Notifications'));
      await tester.pumpAndSettle();
      expect(find.text('Title c'), findsOneWidget);
      expect(find.textContaining('Clear '), findsNothing);
      await done(tester, inbox);
    });

    testWidgets('an empty history is all caught up', (WidgetTester tester) async {
      repository.rows.clear();
      final NotificationInboxProvider inbox = await pump(tester);
      expect(find.bySemanticsLabel('Notifications'), findsOneWidget);
      await tester.tap(find.byTooltip('Notifications'));
      await tester.pumpAndSettle();
      expect(find.text('You’re all caught up'), findsOneWidget);
      expect(find.text('Mark all as read'), findsNothing);
      expect(tester.takeException(), isNull);
      await done(tester, inbox);
    });
  });
}
