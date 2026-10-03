import 'package:flutter/foundation.dart';

import '../core/errors/app_exception.dart';

enum LoadStatus { idle, loading, ready, error }

/// Shared loading/error plumbing for providers.
///
/// Keeps every screen able to render the same four states without each
/// provider reinventing the flags.
abstract class AsyncProvider extends ChangeNotifier {
  LoadStatus _status = LoadStatus.idle;
  String? _errorMessage;
  bool _disposed = false;

  LoadStatus get status => _status;
  String? get errorMessage => _errorMessage;

  bool get isIdle => _status == LoadStatus.idle;
  bool get isLoading => _status == LoadStatus.loading;
  bool get isReady => _status == LoadStatus.ready;
  bool get hasError => _status == LoadStatus.error;

  /// True for the very first load, so screens can show a skeleton instead of
  /// an inline spinner over existing content.
  bool get isInitialLoad => _status == LoadStatus.loading && isEmptyData;

  /// Overridden by subclasses to describe whether they hold any data yet.
  @protected
  bool get isEmptyData => true;

  @protected
  void setLoading() {
    _status = LoadStatus.loading;
    _errorMessage = null;
    safeNotify();
  }

  @protected
  void setReady() {
    _status = LoadStatus.ready;
    _errorMessage = null;
    safeNotify();
  }

  @protected
  void setError(Object error) {
    _status = LoadStatus.error;
    _errorMessage = ErrorMapper.map(error).message;
    safeNotify();
  }

  /// Runs [action], mapping any throw into [errorMessage] and returning
  /// whether it succeeded. Used by mutations that should not blank the screen.
  @protected
  Future<bool> guard(Future<void> Function() action) async {
    try {
      await action();
      _errorMessage = null;
      return true;
    } catch (error) {
      _errorMessage = ErrorMapper.map(error).message;
      safeNotify();
      return false;
    }
  }

  void clearError() {
    if (_errorMessage == null) return;
    _errorMessage = null;
    safeNotify();
  }

  /// `notifyListeners` that tolerates async work finishing after disposal.
  @protected
  void safeNotify() {
    if (_disposed) return;
    notifyListeners();
  }

  @protected
  bool get isDisposed => _disposed;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
