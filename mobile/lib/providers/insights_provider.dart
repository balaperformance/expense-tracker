import '../core/utils/date_utils.dart';
import '../models/bank_account.dart';
import '../models/credit_card.dart';
import '../models/expense.dart';
import '../models/expense_category.dart';
import '../models/insights.dart';
import '../models/ledger_entry.dart';
import '../models/payment_method.dart';
import '../models/tag.dart';
import '../repositories/credit_card_repository.dart';
import '../repositories/expense_repository.dart';
import '../repositories/income_repository.dart';
import '../repositories/tag_repository.dart';
import '../services/statement_import/statement_engine.dart';
import 'async_state.dart';
import 'credit_card_provider.dart';

/// The names Reports resolves ids against — the lists the app already holds.
class InsightsCatalog {
  const InsightsCatalog({
    required this.categories,
    required this.paymentMethods,
    required this.accounts,
    required this.cards,
  });

  final List<ExpenseCategory> categories;
  final List<PaymentMethod> paymentMethods;
  final List<BankAccount> accounts;
  final List<CardOverview> cards;
}

/// Reports: Highlights, Spending and Analytics.
///
/// Two years of the user's spending is read once (the same rows the web's
/// Reports read) and handed to the shared insights engine — the web app's own
/// analysis, running offline on the phone (assets/statement_engine). Every
/// view after that is a call into the engine with no request: a different
/// range, filter or span costs nothing but the computation.
///
/// Where the engine cannot run (iOS, or an Android System WebView too old for
/// it), [engineUnavailable] is set and the screen shows the month report.
class InsightsProvider extends AsyncProvider {
  InsightsProvider({
    required StatementEngine engine,
    required ExpenseRepository expenses,
    required IncomeRepository income,
    required TagRepository tags,
    required CreditCardRepository cards,
  })  : _engine = engine,
        _expenses = expenses,
        _income = income,
        _tags = tags,
        _cards = cards;

  final StatementEngine _engine;
  final ExpenseRepository _expenses;
  final IncomeRepository _income;
  final TagRepository _tags;
  final CreditCardRepository _cards;

  /// Two years and a month: a year against the year before, and an annual
  /// renewal seen twice.
  static const int historyMonths = 25;

  String? _userId;
  String _currency = 'INR';
  InsightsCatalog? _catalog;
  bool _stale = true;
  bool _engineUnavailable = false;

  InsightsOverview? _overview;
  SpendingView? _spending;
  AnalyticsView? _analytics;
  bool _spendingBusy = false;
  bool _analyticsBusy = false;
  String? _viewError;

  // What the Spending and Analytics views show; kept while the app runs.
  String _preset = 'last3';
  ({DateTime start, DateTime end})? _custom;
  SpendingFilter _filter = SpendingFilter.empty;
  String _groupBy = 'tag';
  int _span = 6;

  InsightsOverview? get overview => _overview;
  SpendingView? get spending => _spending;
  AnalyticsView? get analytics => _analytics;
  bool get spendingBusy => _spendingBusy;
  bool get analyticsBusy => _analyticsBusy;

  /// A Spending or Analytics refresh failed; the last good view stays shown.
  String? get viewError => _viewError;

  bool get engineUnavailable => _engineUnavailable;
  String get preset => _preset;
  ({DateTime start, DateTime end})? get custom => _custom;
  SpendingFilter get filter => _filter;
  String get groupBy => _groupBy;
  int get span => _span;

  @override
  bool get isEmptyData => _overview == null;

  /// Something was recorded or changed: the next [load] reads again.
  void invalidate() => _stale = true;

  Future<void> load({
    required String userId,
    required String currency,
    required InsightsCatalog catalog,
    bool force = false,
  }) async {
    if (_userId != userId) {
      _userId = userId;
      _overview = null;
      _spending = null;
      _analytics = null;
      _filter = SpendingFilter.empty;
      _stale = true;
    }
    _currency = currency;
    _catalog = catalog;
    if (!force && !_stale && _overview != null) return;

    setLoading();
    try {
      await _loadHistory();
      _stale = false;
      setReady();
      await Future.wait(<Future<void>>[refreshSpending(), refreshAnalytics()]);
    } on StatementEngineException catch (error) {
      if (error.code == 'engineUnavailable') {
        _engineUnavailable = true;
        setReady();
      } else {
        setError(error);
      }
    } catch (error) {
      setError(error);
    }
  }

  /// Reads the history and loads it into the engine.
  Future<void> _loadHistory() async {
    final String userId = _userId!;
    final InsightsCatalog catalog = _catalog!;
    final DateTime today = AppDateUtils.today();
    final DateTime fallback = AppDateUtils.addMonths(today, -historyMonths);
    // A custom range reaching further back is read too.
    final DateTime since = _custom != null && _custom!.start.isBefore(fallback)
        ? _custom!.start
        : fallback;

    final List<Object> results = await Future.wait(<Future<Object>>[
      // Up to today: an expense dated ahead has not happened yet.
      _expenses.fetchHistoryRows(
        userId: userId,
        from: since,
        toExclusive: today.add(const Duration(days: 1)),
      ),
      _expenses.fetchPaidForExpenseIds(userId: userId),
      _tags.fetchExpenseTagLinks(userId),
      _cards.fetchCharges(userId: userId, from: since),
      _income.fetchMonthlyTotals(
        userId: userId,
        from: since,
        toExclusive: AppDateUtils.addMonths(AppDateUtils.firstDayOf(today), 1),
      ),
      _tags.fetchTags(userId),
    ]);

    final List<Map<String, dynamic>> rows = results[0] as List<Map<String, dynamic>>;
    final Map<String, String> categoryNames = <String, String>{
      for (final ExpenseCategory c in catalog.categories) c.id: c.name,
    };
    final Map<String, List<String>> links = results[2] as Map<String, List<String>>;

    final Object? value = await _engine.call('insightsLoad', <String, Object?>{
      'today': AppDateUtils.toDateString(today),
      'since': AppDateUtils.toDateString(since),
      'currency': _currency,
      'expenses': <Map<String, Object?>>[
        for (final Map<String, dynamic> r in rows)
          <String, Object?>{
            'id': r['id'],
            'amount': (r['amount'] as num?)?.toDouble() ?? 0,
            'expenseDate': r['expense_date'],
            'categoryId': r['category_id'],
            'paymentMethodId': r['payment_method_id'],
            'bankAccountId': r['bank_account_id'],
            'creditCardId': r['credit_card_id'],
            'merchant': r['merchant'],
            'description': r['description'],
            'category': r['category_id'] == null || categoryNames[r['category_id']] == null
                ? null
                : <String, Object?>{'name': categoryNames[r['category_id']]},
          },
      ],
      'paidFor': (results[1] as Set<String>).toList(),
      'tagLinks': <List<String>>[
        for (final MapEntry<String, List<String>> e in links.entries)
          for (final String tagId in e.value) <String>[e.key, tagId],
      ],
      'cardCharges': _chargesJson(results[3] as List<CardTransaction>),
      'income': results[4] as Map<String, double>,
      'catalog': <String, Object?>{
        'categories': <Map<String, Object?>>[
          for (final ExpenseCategory c in catalog.categories)
            <String, Object?>{'id': c.id, 'name': c.name, 'color': c.color, 'icon': c.icon},
        ],
        'tags': <Map<String, Object?>>[
          for (final Tag t in results[5] as List<Tag>) <String, Object?>{'id': t.id, 'name': t.name},
        ],
        'paymentMethods': <Map<String, Object?>>[
          for (final PaymentMethod m in catalog.paymentMethods) <String, Object?>{'id': m.id, 'name': m.name},
        ],
        'accounts': <Map<String, Object?>>[
          for (final BankAccount a in catalog.accounts) <String, Object?>{'id': a.id, 'name': a.nickname},
        ],
        'cards': <Map<String, Object?>>[
          for (final CardOverview o in catalog.cards) <String, Object?>{'id': o.card.id, 'name': o.card.displayLabel},
        ],
      },
      'cardUses': <Map<String, Object?>>[
        for (final CardOverview o in catalog.cards)
          if (o.card.isActive && o.card.creditLimit > 0)
            <String, Object?>{
              'id': o.card.id,
              'name': o.card.displayLabel,
              'outstanding': o.summary.outstanding,
              'limit': o.card.creditLimit,
              'utilisation': o.summary.utilisation,
            },
      ],
    });
    _overview = InsightsOverview.fromJson((value as Map<Object?, Object?>).cast<String, Object?>());
  }

  /// Fees, interest, refunds and cashback with the web's signs: a fee or
  /// interest charged is positive (a credit of either kind reverses one);
  /// refunds and cashback count only as credits.
  static List<Map<String, Object?>> _chargesJson(List<CardTransaction> charges) {
    final List<Map<String, Object?>> out = <Map<String, Object?>>[];
    for (final CardTransaction t in charges) {
      final bool charged = t.kind == CardTransactionKind.fee || t.kind == CardTransactionKind.interest;
      final bool back = t.kind == CardTransactionKind.refund || t.kind == CardTransactionKind.cashback;
      if (!charged && !back) continue;
      final double amount = charged
          ? (t.direction == LedgerDirection.debit ? t.amount : -t.amount)
          : (t.direction == LedgerDirection.credit ? t.amount : 0);
      if (amount == 0) continue;
      out.add(<String, Object?>{
        'id': t.id,
        'cardId': t.cardId,
        'kind': t.kind.wire,
        'amount': amount,
        'date': AppDateUtils.toDateString(t.txnDate),
        'description': t.description,
        'originalExpenseId': t.originalExpenseId,
      });
    }
    return out;
  }

  /// One engine call against the loaded history, reloading once if the
  /// engine has forgotten it (its WebView was recreated).
  Future<Map<String, Object?>> _call(String name, Map<String, Object?> args) async {
    Future<Map<String, Object?>> run() async {
      final Object? value = await _engine.call(name, <String, Object?>{'session': _overview!.session, ...args});
      return (value as Map<Object?, Object?>).cast<String, Object?>();
    }

    try {
      return await run();
    } on StatementEngineException catch (error) {
      if (error.code != 'insightsExpired') rethrow;
      await _loadHistory();
      return run();
    }
  }

  Map<String, Object?> get _rangeArgs => <String, Object?>{
        'preset': _preset,
        'custom': _custom == null
            ? null
            : <String, String>{
                'start': AppDateUtils.toDateString(_custom!.start),
                'end': AppDateUtils.toDateString(_custom!.end),
              },
        'filter': _filter.toJson(),
      };

  Future<void> refreshSpending() async {
    if (_overview == null) return;
    _spendingBusy = true;
    safeNotify();
    try {
      _spending = SpendingView.fromJson(await _call('insightsSpending', _rangeArgs));
      _viewError = null;
    } catch (error) {
      _viewError = _message(error);
    } finally {
      _spendingBusy = false;
      safeNotify();
    }
  }

  Future<void> refreshAnalytics() async {
    if (_overview == null) return;
    _analyticsBusy = true;
    safeNotify();
    try {
      _analytics = AnalyticsView.fromJson(await _call('insightsAnalytics', <String, Object?>{'span': _span}));
      _viewError = null;
    } catch (error) {
      _viewError = _message(error);
    } finally {
      _analyticsBusy = false;
      safeNotify();
    }
  }

  /// A preset ('thisMonth', 'lastMonth', 'last3', 'last6', 'last12') or a
  /// custom range — which may reach before the loaded history, and then reads
  /// it.
  Future<void> setPeriod(String preset, {({DateTime start, DateTime end})? custom}) async {
    _preset = preset;
    _custom = preset == 'custom' ? custom : null;
    final InsightsOverview? loaded = _overview;
    if (loaded != null && _custom != null && _custom!.start.isBefore(loaded.since)) {
      setLoading();
      try {
        await _loadHistory();
        setReady();
        await refreshAnalytics();
      } catch (error) {
        setError(error);
        return;
      }
    }
    await refreshSpending();
  }

  Future<void> setFilter(SpendingFilter filter) async {
    _filter = filter;
    await refreshSpending();
  }

  void setGroupBy(String groupBy) {
    _groupBy = groupBy;
    safeNotify();
  }

  Future<void> setSpan(int span) async {
    _span = span;
    await refreshAnalytics();
  }

  /// The expenses behind a figure, newest first, with their total.
  Future<({double total, List<InsightRow> rows})> rows(List<String> ids) async {
    final Map<String, Object?> value = await _call('insightsRows', <String, Object?>{'ids': ids});
    final List<Object?> list = (value['rows'] as List<Object?>?) ?? const <Object?>[];
    return (
      total: (value['total'] as num?)?.toDouble() ?? 0,
      rows: list
          .whereType<Map<Object?, Object?>>()
          .map((Map<Object?, Object?> m) => InsightRow.fromJson(m.cast<String, Object?>()))
          .toList(),
    );
  }

  /// The saved expense behind a row, to open it; null when deleted since.
  Future<Expense?> expense(String id) =>
      _expenses.fetchById(userId: _userId ?? '', id: id);

  static String _message(Object error) =>
      error is StatementEngineException ? error.message : 'The report could not be updated. Try again.';
}
