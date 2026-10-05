import 'dart:async';

import 'package:flutter/widgets.dart';

import '../core/errors/app_exception.dart';
import '../models/notification_item.dart';
import '../repositories/notification_repository.dart';
import '../services/schema_capabilities.dart';
import 'async_state.dart';

/// The header bell's data: the in-app notification history, its unread
/// count, marking items read and clearing read ones — the counterpart of the
/// web app's `hooks/notificationInbox.ts`, on the same table.
///
/// Available once migration 010 is in the database; clearing once 012 is.
///
///  * Marks show at once and go back if the save fails; the failure is
///    returned so the bell can say so.
///  * An update the database accepted but applied to nothing is a failure
///    for Mark all as read and Clear read (one already read elsewhere is fine
///    for a single mark).
///  * The list refreshes every [refreshInterval] while the app is in front,
///    when it comes back, and when a push arrives while it is running.
class NotificationInboxProvider extends AsyncProvider {
  NotificationInboxProvider({
    required NotificationRepository repository,
    Stream<void>? pushes,
    bool observeLifecycle = true,
    Duration refreshEvery = refreshInterval,
  })  : _repository = repository,
        _observeLifecycle = observeLifecycle,
        _refreshEvery = refreshEvery {
    _pushes = pushes?.listen((_) => _onPush());
  }

  /// Notifications are written by the server on a 15-minute schedule; a few
  /// minutes' lag is plenty fresh. The web app's interval.
  static const Duration refreshInterval = Duration(minutes: 5);

  static const String markFailedMessage =
      'Could not mark as read. Check your connection and try again.';
  static const String clearFailedMessage =
      'Could not clear the notifications. Check your connection and try again.';

  final NotificationRepository _repository;
  final bool _observeLifecycle;
  final Duration _refreshEvery;

  StreamSubscription<void>? _pushes;
  AppLifecycleListener? _lifecycle;
  Timer? _timer;

  String? _userId;
  List<NotificationItem> _items = const <NotificationItem>[];
  bool _loaded = false;

  /// A bell has been shown for this user: keep the list fresh from now on.
  bool _active = false;
  bool _foreground = true;

  /// Saves in flight, local edits so far, and fetches started — a fetch that
  /// began before an edit, or while a save is in flight, is not shown (the
  /// save's own refresh follows it).
  int _pending = 0;
  int _edits = 0;
  int _fetches = 0;

  /// The migration the history needs is in place (010).
  bool get available => SchemaCapabilities.notificationInbox;

  /// Read notifications can be cleared from the list (012).
  bool get canClear => available && SchemaCapabilities.notificationClear;

  /// Newest first.
  List<NotificationItem> get items => _items;
  int get unreadCount => NotificationItem.unreadCount(_items);
  int get readCount => _items.length - unreadCount;

  /// The bell's badge, or null for none.
  String? get badge => NotificationItem.badgeLabel(unreadCount);

  /// The history has been read at least once for this user.
  bool get loaded => _loaded;

  @override
  bool get isEmptyData => !_loaded;

  /// Follows the signed-in user (null after signing out): another account's
  /// notifications are never kept. Called from a provider update during a
  /// build, so listeners hear of it just after.
  void attachUser(String? userId) {
    if (userId == _userId) return;
    _clear(userId);
    scheduleMicrotask(safeNotify);
  }

  /// After the session ends.
  void reset() {
    _clear(null);
    clearError();
    safeNotify();
  }

  void _clear(String? userId) {
    _userId = userId;
    _items = const <NotificationItem>[];
    _loaded = false;
    _edits++;
    _active = false;
    _stopTimer();
    _lifecycle?.dispose();
    _lifecycle = null;
  }

  /// A bell is on screen: reads the history once and keeps it fresh while
  /// the app is in front. Safe to call from every bell, every time.
  void activate() {
    if (!available || _userId == null) return;
    if (!_active) {
      _active = true;
      _foreground = true;
      if (_observeLifecycle) {
        _lifecycle ??= AppLifecycleListener(onResume: resumed, onPause: paused);
      }
      _startTimer();
    }
    if (!_loaded && !isLoading) unawaited(refresh());
  }

  /// The app came back to the front: the list may have changed meanwhile.
  void resumed() {
    _foreground = true;
    if (!_active) return;
    _startTimer();
    unawaited(refresh());
  }

  /// The app went to the background: nothing is read until it is back.
  void paused() {
    _foreground = false;
    _stopTimer();
  }

  /// A push that lands while the app is open shows in the list at once; one
  /// that lands in the background is read on resume.
  void _onPush() {
    if (_active && _foreground) unawaited(refresh());
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(_refreshEvery, (_) {
      if (_foreground) unawaited(refresh());
    });
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  /// Reads the history again. A failure keeps what is shown and reports
  /// [errorMessage]; the bell's sheet shows it only when there is nothing
  /// else to show.
  Future<void> refresh() async {
    final String? userId = _userId;
    if (userId == null || !available) return;
    final int fetch = ++_fetches;
    final int edits = _edits;
    if (!_loaded) setLoading();
    try {
      final List<NotificationItem> items = await _repository.fetchInbox(userId);
      if (!_current(fetch, edits, userId)) return;
      _items = List<NotificationItem>.unmodifiable(items);
      _loaded = true;
      setReady();
    } catch (error) {
      if (fetch != _fetches || userId != _userId) return;
      setError(error);
    }
  }

  bool _current(int fetch, int edits, String userId) =>
      fetch == _fetches && edits == _edits && _pending == 0 && userId == _userId;

  /// Marks one notification read. Returns null on success, otherwise what to
  /// tell the user — the mark has gone back by then.
  Future<String?> markRead(String key) async {
    final String? userId = _userId;
    if (userId == null) return null;
    final bool unread =
        _items.any((NotificationItem item) => item.key == key && !item.read);
    if (!unread) return null;
    _edit(NotificationItem.withRead(_items, <String>{key}));
    // One already read on another device changes nothing, and that is fine.
    return _save(
      userId,
      () => _repository.markInboxRead(userId, key),
      rollback: () => _markUnread(<String>{key}),
      failure: (_) => markFailedMessage,
    );
  }

  /// Marks every notification read. Returns null on success, otherwise what
  /// to tell the user — the marks have gone back by then.
  Future<String?> markAllRead() async {
    final String? userId = _userId;
    if (userId == null) return null;
    final Set<String> keys = <String>{
      for (final NotificationItem item in _items)
        if (!item.read) item.key,
    };
    if (keys.isEmpty) return null;
    _edit(NotificationItem.withRead(_items));
    return _save(
      userId,
      () async => _changedSomething(await _repository.markAllInboxRead(userId)),
      rollback: () => _markUnread(keys),
      failure: (_) => markFailedMessage,
    );
  }

  /// Clears read notifications from the list; unread ones stay. Returns null
  /// on success, otherwise what to tell the user — the read ones are back in
  /// the list by then.
  Future<String?> clearRead() async {
    final String? userId = _userId;
    if (userId == null || !canClear) return null;
    final List<NotificationItem> cleared = <NotificationItem>[
      for (final NotificationItem item in _items)
        if (item.read) item,
    ];
    if (cleared.isEmpty) return null;
    _edit(<NotificationItem>[
      for (final NotificationItem item in _items)
        if (!item.read) item,
    ]);
    return _save(
      userId,
      () async => _changedSomething(await _repository.clearReadInbox(userId)),
      rollback: () => _restore(cleared),
      failure: (Object error) => error is _NothingChanged
          ? clearFailedMessage
          : ErrorMapper.map(error).message,
    );
  }

  /// Runs [save]; on failure undoes the optimistic edit with [rollback].
  /// Either way the list is read again afterwards, without waiting for it.
  Future<String?> _save(
    String userId,
    Future<Object?> Function() save, {
    required void Function() rollback,
    required String Function(Object error) failure,
  }) async {
    _pending++;
    String? message;
    try {
      await save();
    } catch (error) {
      message = failure(error);
      if (userId == _userId) {
        rollback();
        _edits++;
        safeNotify();
      }
    } finally {
      _pending--;
    }
    if (userId == _userId) unawaited(refresh());
    return message;
  }

  /// An update the database accepted but applied to nothing is a failure,
  /// not a success.
  static int _changedSomething(int changed) {
    if (changed == 0) throw const _NothingChanged();
    return changed;
  }

  void _edit(List<NotificationItem> items) {
    _items = List<NotificationItem>.unmodifiable(items);
    _edits++;
    safeNotify();
  }

  void _markUnread(Set<String> keys) {
    _items = List<NotificationItem>.unmodifiable(<NotificationItem>[
      for (final NotificationItem item in _items)
        keys.contains(item.key) ? item.copyWith(read: false) : item,
    ]);
  }

  void _restore(List<NotificationItem> cleared) {
    final Set<String> present = <String>{
      for (final NotificationItem item in _items) item.key,
    };
    _items = List<NotificationItem>.unmodifiable(<NotificationItem>[
      ..._items,
      for (final NotificationItem item in cleared)
        if (!present.contains(item.key)) item,
    ]..sort(NotificationItem.newestFirst));
  }

  @override
  void dispose() {
    _pushes?.cancel();
    _stopTimer();
    _lifecycle?.dispose();
    super.dispose();
  }
}

class _NothingChanged implements Exception {
  const _NothingChanged();
}
