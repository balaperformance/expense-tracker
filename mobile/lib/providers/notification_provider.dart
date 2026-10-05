import 'dart:async';

import '../models/notification_prefs.dart';
import '../repositories/notification_repository.dart';
import '../services/preferences_service.dart';
import '../services/push/push_platform.dart';
import '../services/schema_capabilities.dart';
import 'async_state.dart';

/// What this phone can do about push notifications.
enum PushSupport {
  /// Not read yet.
  checking,

  /// No Android bridge (iOS, tests): notifications go to the Android app and
  /// the web app.
  unsupported,

  /// This build has no Firebase project (google-services.json).
  notConfigured,
  ready,
}

/// The outcome of turning notifications on.
enum EnableResult { enabled, denied, dismissed, unavailable }

/// Push notifications on the phone — the counterpart of the web app's
/// Settings → Notifications, on the same server.
///
/// The `push-notify` Edge Function decides what is due (10 PM reminder,
/// 16th/month-end summary, low balance, card due) from each user's own clock
/// and sends it to every device they have — browsers over Web Push, phones
/// over Firebase Cloud Messaging — once per event. This provider only:
///
///  * turns notifications on by default at sign-in — silently when Android
///    already allows them, otherwise by asking once — unless the user pressed
///    Turn off on this phone; after that only Turn on asks;
///  * registers this phone's token (and its time zone) for the signed-in user,
///    and keeps it registered when the app comes back;
///  * tells the phone whose notifications it may show, so another account's
///    figures are never drawn after a sign-out or a change of user;
///  * removes the token before signing out;
///  * reads and saves the four switches, shared with the web app;
///  * hands the shell the page a tapped notification asked for.
class NotificationProvider extends AsyncProvider {
  NotificationProvider({
    required PushPlatform platform,
    required NotificationRepository repository,
    required PreferencesService preferences,
    DateTime Function()? clock,
  })  : _platform = platform,
        _repository = repository,
        _preferences = preferences,
        _clock = clock ?? DateTime.now {
    _paths = _platform.openedPaths.listen((String path) {
      _pendingPath = path;
      safeNotify();
    });
  }

  final PushPlatform _platform;
  final NotificationRepository _repository;
  final PreferencesService _preferences;
  final DateTime Function() _clock;

  /// Often enough to follow a traveller's time zone, rarely enough to cost
  /// nothing — the web app's interval.
  static const Duration resyncAfter = Duration(hours: 1);

  /// Signing out never waits longer than this for the server.
  static const Duration cleanupTimeout = Duration(seconds: 6);

  StreamSubscription<String>? _paths;
  String? _userId;
  PushSupport _support = PushSupport.checking;
  String _permission = 'notDetermined';
  NotificationPrefs _prefs = NotificationPrefs.defaults;
  bool _prefsLoaded = false;
  bool _busy = false;
  DateTime? _lastSync;
  String? _pendingPath;

  PushSupport get support => _support;
  String get permission => _permission;
  NotificationPrefs get prefs => _prefs;
  bool get prefsLoaded => _prefsLoaded;
  bool get busy => _busy;

  /// The migrations the feature needs are in place (008 and 009).
  bool get available => SchemaCapabilities.notifications;

  /// This phone receives the signed-in user's notifications.
  bool get enabledHere =>
      _userId != null &&
      _preferences.pushUser == _userId &&
      _support == PushSupport.ready &&
      _permission == 'granted';

  /// Turned on here, but Android now blocks them (the user changed it).
  bool get blockedHere =>
      _userId != null && _preferences.pushUser == _userId && _permission == 'denied';

  @override
  bool get isEmptyData => !_prefsLoaded;

  /// After sign-in: this phone's state, the user's switches, and the phone
  /// registered for the user — renewed when it already was, otherwise turned
  /// on by default (see [_enableByDefault]).
  Future<void> attach(String userId) async {
    _userId = userId;
    await refreshStatus();
    if (SchemaCapabilities.notifications) await loadPrefs();
    if (_preferences.pushUser == userId) {
      await _safely(() => _platform.setUser(userId));
      await sync(force: true);
    } else {
      await _enableByDefault();
    }
  }

  /// Notifications are on unless the user turned them off on this phone.
  /// Android's permission is asked for at most once by the app on its own
  /// (Android 13 and later; earlier versions allow them without asking).
  Future<void> _enableByDefault() async {
    if (_preferences.pushOff ||
        _support != PushSupport.ready ||
        !SchemaCapabilities.notifications) {
      return;
    }
    if (_permission != 'granted') {
      if (_permission == 'denied' || _preferences.pushAsked) return;
      await _preferences.setPushAsked();
    }
    try {
      await enable();
    } catch (_) {
      // Not worth interrupting a sign-in for: Settings still offers Turn on.
    }
  }

  Future<void> refreshStatus() async {
    try {
      final PushDeviceStatus status = await _platform.status();
      _support = !status.supported
          ? PushSupport.unsupported
          : (status.available ? PushSupport.ready : PushSupport.notConfigured);
      _permission = status.permission;
    } catch (_) {
      _support = PushSupport.unsupported;
    }
    safeNotify();
  }

  Future<void> loadPrefs() async {
    final String? userId = _userId;
    if (userId == null || !SchemaCapabilities.notifications) return;
    try {
      _prefs = await _repository.fetchPrefs(userId);
      _prefsLoaded = true;
      setReady();
    } catch (error) {
      setError(error);
    }
  }

  /// Turns notifications on for this phone and this account. Asks Android for
  /// permission only if it never has been asked; a refusal is remembered by
  /// Android, so the user is told how to allow it instead of asked again.
  Future<EnableResult> enable() async {
    final String? userId = _userId;
    if (userId == null ||
        _support != PushSupport.ready ||
        !SchemaCapabilities.notifications) {
      return EnableResult.unavailable;
    }
    _busy = true;
    safeNotify();
    try {
      String permission = _permission;
      if (permission != 'granted') permission = await _platform.requestPermission();
      _permission = permission;
      if (permission == 'denied') return EnableResult.denied;
      if (permission != 'granted') return EnableResult.dismissed;
      final String token = await _platform.getToken();
      await _register(token);
      await _platform.setUser(userId);
      await _preferences.setPush(userId: userId, token: token);
      await _preferences.setPushOff(false);
      _lastSync = _clock();
      return EnableResult.enabled;
    } finally {
      _busy = false;
      safeNotify();
    }
  }

  /// Turns notifications off for this phone. The phone stops showing them at
  /// once; the server's record and the token go after.
  Future<void> disable() async {
    final String? userId = _userId;
    if (userId == null) return;
    _busy = true;
    safeNotify();
    final String? token = _preferences.pushToken;
    try {
      await _preferences.setPush(userId: null, token: null);
      await _preferences.setPushOff(true);
      await _safely(() => _platform.setUser(null));
      try {
        if (token != null) {
          await _repository.unregisterToken(userId: userId, token: token);
        }
      } finally {
        // Even when the server could not be told: a deleted token receives
        // nothing, and the server switches it off on its next send.
        await _safely(_platform.deleteToken);
      }
    } finally {
      _busy = false;
      safeNotify();
    }
  }

  /// Keeps an enabled phone registered — its token (which Firebase may
  /// replace) and its time zone. Does nothing for a phone the user has not
  /// turned on, never prompts, and at most once an hour unless [force]d.
  Future<void> sync({bool force = false}) async {
    final String? userId = _userId;
    if (userId == null || _preferences.pushUser != userId) return;
    if (!SchemaCapabilities.notifications) return;
    final DateTime now = _clock();
    final DateTime? last = _lastSync;
    if (!force && last != null && now.difference(last) < resyncAfter) return;
    _lastSync = now;
    try {
      await refreshStatus();
      // Blocked in Android settings: keep the choice; Settings says how to undo it.
      if (_support != PushSupport.ready || _permission != 'granted') return;
      final String token = await _platform.getToken();
      await _register(token);
      await _preferences.setPush(userId: userId, token: token);
      await _platform.setUser(userId);
    } catch (_) {
      // Not worth interrupting anyone for: the next resume tries again.
      _lastSync = null;
    }
  }

  Future<void> _register(String token) async {
    final String timezone = await _platform.timeZone();
    final Map<String, String?> info = await _safelyValue(
        _platform.deviceInfo, const <String, String?>{});
    await _repository.registerToken(
      token: token,
      timezone: timezone,
      appVersion: info['appVersion'],
      device: info['device'],
    );
  }

  /// Saves one switch for every device of the user's; the switch moves at
  /// once and goes back if the save fails.
  Future<bool> setPref(NotificationPref pref, bool value) async {
    final String? userId = _userId;
    if (userId == null) return false;
    final NotificationPrefs before = _prefs;
    _prefs = _prefs.withValue(pref, value);
    safeNotify();
    try {
      await _repository.savePref(userId, pref, value);
      return true;
    } catch (error) {
      _prefs = before;
      setError(error);
      return false;
    }
  }

  Future<void> openSettings() => _safely(_platform.openSettings);

  /// Signing out must stop this phone receiving the account's notifications.
  /// Runs while the session still exists; best effort, never blocks the
  /// sign-out for long, never throws.
  Future<void> releaseForSignOut() async {
    final String? userId = _userId;
    await _safely(() => _platform.setUser(null));
    if (userId == null || _preferences.pushUser != userId) return;
    final String? token = _preferences.pushToken;
    await _preferences.setPush(userId: null, token: null);
    if (token != null) {
      await _safely(() => _repository
          .unregisterToken(userId: userId, token: token)
          .timeout(cleanupTimeout));
    }
    await _safely(() => _platform.deleteToken().timeout(cleanupTimeout));
  }

  /// The page a tapped notification opened the app on, read once at start.
  Future<void> collectLaunchPath() async {
    final String? path = await _safelyValue(_platform.takeLaunchPath, null);
    if (path != null) {
      _pendingPath = path;
      safeNotify();
    }
  }

  /// Opens [path] the way a tapped notification does — the in-app history
  /// uses it, so both reach a page through the shell's one route.
  void openPath(String path) {
    _pendingPath = path;
    safeNotify();
  }

  /// A push arrived while the app was running (PushBridge `pushReceived`),
  /// for the in-app history to refresh. One platform channel serves both.
  Stream<void> get pushesReceived => _platform.received;

  /// The page a tapped notification asked for, for the shell to open — once.
  String? takePendingPath() {
    final String? path = _pendingPath;
    _pendingPath = null;
    return path;
  }

  /// After the session ends: nothing of the previous account stays — not its
  /// switches, and not the phone's permission to show its notifications. The
  /// next account to sign in gets them on by default, unless Turn off was
  /// pressed on this phone.
  void reset() {
    _userId = null;
    _prefs = NotificationPrefs.defaults;
    _prefsLoaded = false;
    _lastSync = null;
    _pendingPath = null;
    _busy = false;
    unawaited(_safely(() => _platform.setUser(null)));
    safeNotify();
  }

  static Future<void> _safely(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      // Best effort.
    }
  }

  static Future<T> _safelyValue<T>(Future<T> Function() action, T fallback) async {
    try {
      return await action();
    } catch (_) {
      return fallback;
    }
  }

  @override
  void dispose() {
    _paths?.cancel();
    super.dispose();
  }
}
