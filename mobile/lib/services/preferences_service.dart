import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Device-local preferences.
///
/// Theme lives here rather than in `profiles` because the table has no column
/// for it, and a display preference is arguably per-device anyway. Currency is
/// mirrored here purely as a cache so the first frame after launch can format
/// money before the profile round-trip completes.
class PreferencesService {
  PreferencesService(this._prefs);

  final SharedPreferences _prefs;

  static const String _themeKey = 'pref_theme_mode';
  static const String _currencyKey = 'pref_currency_cache';
  static const String _hideBalancesKey = 'pref_hide_balances';

  static Future<PreferencesService> create() async =>
      PreferencesService(await SharedPreferences.getInstance());

  ThemeMode get themeMode {
    switch (_prefs.getString(_themeKey)) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    await _prefs.setString(_themeKey, switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    });
  }

  /// Whether bank balances are masked on the dashboard.
  ///
  /// Defaults to hidden: the dashboard is the screen most likely to be open
  /// in public, and a balance you chose to reveal is safer than one you have
  /// to remember to hide. Stored per device, like the theme.
  bool get hideBalances => _prefs.getBool(_hideBalancesKey) ?? true;

  Future<void> setHideBalances(bool value) =>
      _prefs.setBool(_hideBalancesKey, value);

  static const String _pushUserKey = 'pref_push_user';
  static const String _pushTokenKey = 'pref_push_token';

  /// The account push notifications were turned on for on this phone, and
  /// the token registered for it — null when they are off here. Per device,
  /// like the theme: each phone opts in on its own.
  String? get pushUser => _prefs.getString(_pushUserKey);
  String? get pushToken => _prefs.getString(_pushTokenKey);

  Future<void> setPush({required String? userId, required String? token}) async {
    if (userId == null) {
      await _prefs.remove(_pushUserKey);
    } else {
      await _prefs.setString(_pushUserKey, userId);
    }
    if (token == null) {
      await _prefs.remove(_pushTokenKey);
    } else {
      await _prefs.setString(_pushTokenKey, token);
    }
  }

  String? get cachedCurrency => _prefs.getString(_currencyKey);

  Future<void> setCachedCurrency(String code) =>
      _prefs.setString(_currencyKey, code);

  /// Called on sign-out. Theme is intentionally kept: it is a device setting,
  /// not user data.
  Future<void> clearUserScoped() => _prefs.remove(_currencyKey);
}
