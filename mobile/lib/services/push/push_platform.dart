import 'dart:async';

import 'package:flutter/services.dart';

/// What the phone can do about push notifications right now.
class PushDeviceStatus {
  const PushDeviceStatus({required this.available, required this.permission});

  /// Not an Android build (iOS, tests): there is no bridge at all.
  static const PushDeviceStatus unsupported =
      PushDeviceStatus(available: false, permission: 'unsupported');

  /// This build was given a Firebase project (google-services.json).
  final bool available;

  /// 'granted', 'denied', 'notDetermined' — or 'unsupported'.
  final String permission;

  bool get supported => permission != 'unsupported';
  bool get granted => permission == 'granted';
  bool get denied => permission == 'denied';
}

/// The Android side of push notifications (PushBridge.kt). Nothing here talks
/// to the server; the provider registers what this hands it.
abstract class PushPlatform {
  Future<PushDeviceStatus> status();

  /// Asks the user (Android 13+, once); returns the permission afterwards.
  Future<String> requestPermission();

  /// This install's FCM registration token.
  Future<String> getToken();

  /// Forgets the token: the server's sends to it fail from now on.
  Future<void> deleteToken();

  /// Whose notifications may be shown on this phone; null for nobody.
  Future<void> setUser(String? userId);

  /// The phone's IANA time zone, e.g. Asia/Kolkata.
  Future<String> timeZone();

  /// {device, appVersion} — kept with the token so the user can tell devices apart.
  Future<Map<String, String?>> deviceInfo();

  /// The page a tapped notification opened the app on, once.
  Future<String?> takeLaunchPath();

  Future<void> openSettings();

  /// Pages tapped notifications ask for while the app is running.
  Stream<String> get openedPaths;

  /// A push for the signed-in account arrived while the app was running —
  /// open or in the background. Carries nothing: the in-app history reads
  /// the message from the server, where the sender saved it first.
  Stream<void> get received;
}

class PushPlatformException implements Exception {
  const PushPlatformException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

class MethodChannelPushPlatform implements PushPlatform {
  MethodChannelPushPlatform([
    this._channel = const MethodChannel('expense_tracker/push'),
  ]) {
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'openPath' && call.arguments is String) {
        _paths.add(call.arguments as String);
      } else if (call.method == 'pushReceived') {
        _received.add(null);
      }
      return null;
    });
  }

  final MethodChannel _channel;
  final StreamController<String> _paths = StreamController<String>.broadcast();
  final StreamController<void> _received = StreamController<void>.broadcast();

  @override
  Stream<String> get openedPaths => _paths.stream;

  @override
  Stream<void> get received => _received.stream;

  Future<T?> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      throw const PushPlatformException(
        'unsupported',
        'Push notifications are available in the Android app.',
      );
    } on PlatformException catch (error) {
      throw PushPlatformException(
        error.code,
        error.message ?? 'Push notifications are not available right now.',
      );
    }
  }

  @override
  Future<PushDeviceStatus> status() async {
    try {
      final Map<Object?, Object?>? reply =
          await _invoke<Map<Object?, Object?>>('status');
      return PushDeviceStatus(
        available: reply?['available'] == true,
        permission: (reply?['permission'] as String?) ?? 'denied',
      );
    } on PushPlatformException catch (error) {
      if (error.code == 'unsupported') return PushDeviceStatus.unsupported;
      rethrow;
    }
  }

  @override
  Future<String> requestPermission() async =>
      (await _invoke<String>('requestPermission')) ?? 'denied';

  @override
  Future<String> getToken() async {
    final String? token = await _invoke<String>('getToken');
    if (token == null || token.isEmpty) {
      throw const PushPlatformException('failed', 'No push token was issued.');
    }
    return token;
  }

  @override
  Future<void> deleteToken() => _invoke<void>('deleteToken');

  @override
  Future<void> setUser(String? userId) =>
      _invoke<void>('setUser', <String, Object?>{'userId': userId});

  @override
  Future<String> timeZone() async =>
      (await _invoke<String>('timeZone')) ?? 'UTC';

  @override
  Future<Map<String, String?>> deviceInfo() async {
    final Map<Object?, Object?>? reply =
        await _invoke<Map<Object?, Object?>>('deviceInfo');
    return <String, String?>{
      'device': reply?['device'] as String?,
      'appVersion': reply?['appVersion'] as String?,
    };
  }

  @override
  Future<String?> takeLaunchPath() => _invoke<String>('takeLaunchPath');

  @override
  Future<void> openSettings() => _invoke<void>('openSettings');
}
