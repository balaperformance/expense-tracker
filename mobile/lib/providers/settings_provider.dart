import 'package:flutter/material.dart';

import '../core/constants/app_constants.dart';
import '../models/profile.dart';
import '../repositories/profile_repository.dart';
import '../services/preferences_service.dart';
import 'async_state.dart';

/// Profile, currency and theme.
///
/// Theme is device-local (the `profiles` table has no column for it); the
/// profile name and currency round-trip to Supabase.
class SettingsProvider extends AsyncProvider {
  SettingsProvider({
    required ProfileRepository repository,
    required PreferencesService preferences,
  })  : _repository = repository,
        _preferences = preferences {
    _themeMode = _preferences.themeMode;
    _currency =
        _preferences.cachedCurrency ?? AppConstants.defaultCurrencyCode;
    _balancesHidden = _preferences.hideBalances;
  }

  final ProfileRepository _repository;
  final PreferencesService _preferences;

  Profile? _profile;
  late ThemeMode _themeMode;
  late String _currency;
  late bool _balancesHidden;

  Profile? get profile => _profile;
  ThemeMode get themeMode => _themeMode;

  /// Always safe to read, even before the profile loads, because it falls back
  /// to the cached value written on the last successful load.
  String get currency => _currency;

  String get currencySymbol => AppConstants.symbolFor(_currency);

  String get displayName => _profile?.displayName ?? 'there';

  @override
  bool get isEmptyData => _profile == null;

  Future<void> loadProfile({
    required String userId,
    String? fallbackName,
  }) async {
    setLoading();
    try {
      final Profile loaded = await _repository.fetchOrCreate(
        userId: userId,
        fallbackName: fallbackName,
      );
      _profile = loaded;
      _currency = loaded.currency;
      await _preferences.setCachedCurrency(loaded.currency);
      setReady();
    } catch (error) {
      setError(error);
    }
  }

  Future<bool> updateName(String fullName) async {
    final Profile? current = _profile;
    if (current == null) return false;

    return guard(() async {
      final Profile updated = await _repository.update(
        userId: current.id,
        fullName: fullName,
      );
      _profile = updated;
      safeNotify();
    });
  }

  Future<bool> updateCurrency(String code) async {
    final Profile? current = _profile;
    if (current == null) return false;

    final String previous = _currency;
    // Optimistic: money on screen re-formats immediately.
    _currency = code;
    safeNotify();

    final bool ok = await guard(() async {
      final Profile updated = await _repository.update(
        userId: current.id,
        currency: code,
      );
      _profile = updated;
      await _preferences.setCachedCurrency(code);
      safeNotify();
    });

    if (!ok) {
      _currency = previous;
      safeNotify();
    }
    return ok;
  }

  /// Whether bank balances are masked on the dashboard.
  bool get balancesHidden => _balancesHidden;

  /// Flipped by the eye control beside the bank total.
  ///
  /// The write is fire-and-forget after the UI has already updated: the
  /// reveal must feel instant, and a failed disk write only costs the
  /// preference on the next launch.
  Future<void> toggleBalancesHidden() async {
    _balancesHidden = !_balancesHidden;
    safeNotify();
    await _preferences.setHideBalances(_balancesHidden);
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) return;
    _themeMode = mode;
    safeNotify();
    await _preferences.setThemeMode(mode);
  }

  /// Clears user-scoped state on sign-out. Theme is deliberately preserved.
  ///
  /// Balances go back to hidden: the next person to reach this device must
  /// not inherit a reveal the previous account switched on.
  Future<void> reset() async {
    _profile = null;
    _currency = AppConstants.defaultCurrencyCode;
    _balancesHidden = true;
    await _preferences.clearUserScoped();
    await _preferences.setHideBalances(true);
    safeNotify();
  }
}
