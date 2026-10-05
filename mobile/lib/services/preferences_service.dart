import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/theme/app_palette.dart';

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

  static const String _paletteKey = 'pref_palette';

  /// The design language, independent of light/dark. Stored by the same id
  /// the web app uses; anything unrecognised — including nothing saved yet —
  /// reads as Gothic Noir, so everyone stays on it until they choose Matte &
  /// Sand. A device setting, like the theme.
  AppPalette get palette => AppPalette.fromId(_prefs.getString(_paletteKey));

  Future<void> setPalette(AppPalette palette) =>
      _prefs.setString(_paletteKey, palette.id);

  static const String _settingsOpenKey = 'pref_settings_open';

  /// The Settings sections unfolded on this phone, by id — the web app's
  /// `et.settingsOpen`. Every section starts folded.
  Set<String> get settingsOpen =>
      (_prefs.getStringList(_settingsOpenKey) ?? const <String>[]).toSet();

  Future<void> setSettingsOpen(Set<String> ids) =>
      _prefs.setStringList(_settingsOpenKey, ids.toList()..sort());

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

  static const String _pushOffKey = 'pref_push_off';
  static const String _pushAskedKey = 'pref_push_asked';

  /// The user pressed Turn off on this phone. Notifications are on by
  /// default otherwise; signing out is not turning them off.
  bool get pushOff => _prefs.getBool(_pushOffKey) ?? false;

  Future<void> setPushOff(bool value) => value
      ? _prefs.setBool(_pushOffKey, true)
      : _prefs.remove(_pushOffKey);

  /// Android's permission was asked for once by the app on its own, at
  /// sign-in; it is never asked for by itself again.
  bool get pushAsked => _prefs.getBool(_pushAskedKey) ?? false;

  Future<void> setPushAsked() => _prefs.setBool(_pushAskedKey, true);

  String? get cachedCurrency => _prefs.getString(_currencyKey);

  Future<void> setCachedCurrency(String code) =>
      _prefs.setString(_currencyKey, code);

  /// Called on sign-out. Theme, palette and the folded Settings sections are
  /// intentionally kept: they are device settings, not user data.
  Future<void> clearUserScoped() => _prefs.remove(_currencyKey);
}
