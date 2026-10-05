import 'dart:async';

import '../models/receivable.dart';
import '../repositories/receivable_repository.dart';
import 'async_state.dart';

/// Money owed to the user: every claim with its figures (migration 005).
///
/// Read by the "Owed to you" screen, the Accounts screen's summary row and
/// the expense form (who a purchase was paid for, and the people already
/// used). Nothing here is stored: each read recomputes the figures from the
/// claims' own rows.
class ReceivableProvider extends AsyncProvider {
  ReceivableProvider(this._repository);

  final ReceivableRepository _repository;

  List<ClaimSummary> _claims = const <ClaimSummary>[];
  String? _userId;
  Future<void>? _inFlight;

  /// Set when something this provider cannot see may have changed a claim —
  /// an expense saved or deleted — so the next [load] reads again.
  bool _stale = true;

  List<ClaimSummary> get claims => List<ClaimSummary>.unmodifiable(_claims);

  @override
  bool get isEmptyData => _claims.isEmpty;

  /// Total still owed across open claims.
  double get outstanding => totalOutstanding(_claims);

  /// How many claims are still owed, in full or in part.
  int get openCount =>
      _claims.where((ClaimSummary c) => c.status.isOpen).length;

  /// Everyone the user has a claim with, most recent first.
  List<String> get people => knownPeople(_claims);

  /// The claim on [expenseId] when it was paid for someone else.
  ClaimSummary? claimForExpense(String expenseId) {
    for (final ClaimSummary claim in _claims) {
      if (claim.receivable.expenseId == expenseId) return claim;
    }
    return null;
  }

  /// Reads the claims. Cheap when they are already loaded for [userId] and
  /// nothing has changed since, unless [force] is set. A call made while a
  /// read is running waits for that read.
  Future<void> load({required String userId, bool force = false}) {
    if (_userId != userId) {
      // Never show one user's claims to another, even for a frame.
      _userId = userId;
      _claims = const <ClaimSummary>[];
      _stale = true;
      _inFlight = null;
    }
    final Future<void>? running = _inFlight;
    if (running != null) return running;
    if (!force && !_stale && isReady) return Future<void>.value();
    final Future<void> read = _read(userId);
    _inFlight = read;
    return read;
  }

  Future<void> _read(String userId) async {
    setLoading();
    try {
      final List<ClaimSummary> claims = await _repository.fetchClaims(userId);
      if (_userId != userId) return;
      _claims = claims;
      _stale = false;
      setReady();
    } catch (error) {
      if (_userId != userId) return;
      setError(error);
    } finally {
      if (_userId == userId) _inFlight = null;
    }
  }

  /// Follows the signed-in user: another user's claims are dropped at once,
  /// before anything can show them, and read again on the next [load].
  void attachUser(String? userId) {
    if (userId == _userId) return;
    _userId = userId;
    _claims = const <ClaimSummary>[];
    _stale = true;
    _inFlight = null;
    // Called while the tree builds (a proxy provider's update), so the
    // listeners hear of it just after.
    scheduleMicrotask(safeNotify);
  }

  /// Marks the claims as out of date. When they were already showing, they
  /// are read again in the background, so what shows them — the Accounts
  /// row — catches up without a pull to refresh.
  void invalidate() {
    _stale = true;
    final String? userId = _userId;
    if (userId != null && isReady) unawaited(load(userId: userId));
  }

  void reset() {
    _claims = const <ClaimSummary>[];
    _userId = null;
    _stale = true;
    _inFlight = null;
    safeNotify();
  }
}
