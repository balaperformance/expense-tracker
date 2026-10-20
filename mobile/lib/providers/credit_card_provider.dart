import '../core/constants/app_constants.dart';
import '../core/errors/app_exception.dart';
import '../core/utils/date_utils.dart';
import '../core/utils/formatters.dart';
import '../models/bank_account.dart';
import '../models/card_statement.dart';
import '../models/credit_card.dart';
import '../models/emi_plan.dart';
import '../models/ledger_entry.dart';
import '../repositories/credit_card_repository.dart';
import '../repositories/emi_plan_repository.dart';
import '../repositories/income_repository.dart';
import '../repositories/ledger_repository.dart';
import '../services/schema_capabilities.dart';
import 'async_state.dart';

/// A card with its derived figures.
class CardOverview {
  const CardOverview({required this.card, required this.summary});

  final CreditCard card;
  final CardSummary summary;
}

/// Credit cards and every movement on them.
///
/// The outstanding, available credit and bill status are recomputed from the
/// movements on every read — never stored — so they cannot drift from the
/// purchases, payments and card transactions that produced them. Every write
/// reloads, and bumps [revision] so screens showing bank balances know a
/// bill payment may have moved one.
class CreditCardProvider extends AsyncProvider {
  CreditCardProvider({
    required CreditCardRepository repository,
    required LedgerRepository ledger,
    EmiPlanRepository? plans,
    IncomeRepository? income,
  })  : _repository = repository,
        _ledger = ledger,
        _plans = plans,
        _income = income;

  final CreditCardRepository _repository;
  final LedgerRepository _ledger;
  final EmiPlanRepository? _plans;

  /// For an EMI reimbursement that replaces an income recorded by mistake.
  final IncomeRepository? _income;

  List<CreditCard> _cards = <CreditCard>[];
  List<CardEntry> _entries = <CardEntry>[];
  List<EmiPlan> _emiPlans = <EmiPlan>[];
  String? _userId;
  bool _stale = true;
  int _revision = 0;

  /// False until migration 004 has been applied.
  bool get available => SchemaCapabilities.creditCards;

  int get revision => _revision;

  List<CreditCard> get cards => List<CreditCard>.unmodifiable(_cards);

  bool get hasCards => _cards.isNotEmpty;

  @override
  bool get isEmptyData => _cards.isEmpty;

  /// Today's figures for every card, in the order they were added.
  List<CardOverview> get overviews {
    final DateTime today = AppDateUtils.today();
    return _cards
        .map((CreditCard card) => CardOverview(
              card: card,
              summary: summariseCard(card, _entries, today),
            ))
        .toList();
  }

  /// Cards offered for a new purchase: active ones, plus [keepId] (the card a
  /// purchase being edited is already on, even if it was since deactivated).
  List<CardOverview> selectable({String? keepId}) => overviews
      .where((CardOverview o) => o.card.isActive || o.card.id == keepId)
      .toList();

  CreditCard? byId(String? id) {
    if (id == null) return null;
    for (final CreditCard card in _cards) {
      if (card.id == id) return card;
    }
    return null;
  }

  CardOverview? overviewFor(String id) {
    for (final CardOverview o in overviews) {
      if (o.card.id == id) return o;
    }
    return null;
  }

  /// One card's whole history.
  List<CardEntry> entriesFor(String cardId) =>
      _entries.where((CardEntry e) => e.cardId == cardId).toList();

  /// Every EMI plan (migration 016); empty before it.
  List<EmiPlan> get allPlans => List<EmiPlan>.unmodifiable(_emiPlans);

  /// Every card's movements — what EMI figures across cards are read from.
  List<CardEntry> get allEntries => List<CardEntry>.unmodifiable(_entries);

  List<EmiPlan> plansFor(String cardId) =>
      _emiPlans.where((EmiPlan p) => p.cardId == cardId).toList();

  EmiPlan? planById(String? id) {
    if (id == null) return null;
    for (final EmiPlan plan in _emiPlans) {
      if (plan.id == id) return plan;
    }
    return null;
  }

  void invalidate() => _stale = true;

  Future<void> load({required String userId, bool force = false}) async {
    if (_userId != userId) {
      _userId = userId;
      _stale = true;
      _cards = <CreditCard>[];
      _entries = <CardEntry>[];
      _emiPlans = <EmiPlan>[];
    }
    // Re-probe while the feature looks missing: 004 may have been applied
    // since the app started.
    if (!available) {
      try {
        await _repository.refreshCapabilities();
      } catch (error) {
        setError(error);
        return;
      }
    }
    if (!available) {
      setReady();
      return;
    }
    if (!_stale && !force && isReady) return;
    if (_cards.isEmpty) setLoading();
    try {
      final EmiPlanRepository? plans = _plans;
      final List<Object> results = await Future.wait(<Future<Object>>[
        _repository.fetchCards(userId),
        _repository.fetchEntries(userId: userId),
        if (plans != null && SchemaCapabilities.emi)
          plans.fetchPlans(userId: userId),
      ]);
      _cards = results[0] as List<CreditCard>;
      _entries = results[1] as List<CardEntry>;
      _emiPlans =
          results.length > 2 ? results[2] as List<EmiPlan> : <EmiPlan>[];
      _stale = false;
      setReady();
    } catch (error) {
      setError(error);
    }
  }

  Future<void> _reload() async {
    final String? userId = _userId;
    if (userId == null) return;
    _stale = true;
    _revision++;
    await load(userId: userId, force: true);
  }

  Future<bool> _write(Future<void> Function(String userId) action) async {
    final String? userId = _userId;
    if (userId == null) return false;
    final bool ok = await guard(() => action(userId));
    if (ok) await _reload();
    return ok;
  }

  Future<bool> save(CreditCard card) => _write((String userId) {
        final CreditCard owned = CreditCard(
          id: card.id,
          userId: userId,
          cardName: card.cardName,
          issuer: card.issuer,
          network: card.network,
          last4: card.last4,
          creditLimit: card.creditLimit,
          openingOutstanding: card.openingOutstanding,
          statementDay: card.statementDay,
          paymentDueDay: card.paymentDueDay,
          paymentAccountId: card.paymentAccountId,
          isActive: card.isActive,
          notes: card.notes,
        );
        return card.id.isEmpty
            ? _repository.create(owned)
            : _repository.update(owned);
      });

  Future<bool> delete(String cardId) => _write(
        (String userId) => _repository.delete(userId: userId, id: cardId),
      );

  /// Counts for the delete confirmation; null when they could not be read.
  Future<({int purchases, int payments, int others})?> activity(
    String cardId,
  ) async {
    final String? userId = _userId;
    if (userId == null) return null;
    try {
      return await _repository.activity(userId: userId, cardId: cardId);
    } catch (_) {
      return null;
    }
  }

  Future<bool> recordTransaction({
    required String cardId,
    required CardTransactionKind kind,
    required LedgerDirection direction,
    required double amount,
    required DateTime date,
    String? description,
    String? reference,
    String? originalExpenseId,
    String? emiPlanId,
    String? emiComponent,
    DateTime? statementDate,
  }) =>
      _write((String userId) => _repository.recordTransaction(
            userId: userId,
            cardId: cardId,
            kind: kind,
            direction: direction,
            amount: amount,
            date: date,
            description: description,
            reference: reference,
            originalExpenseId: originalExpenseId,
            emiPlanId: emiPlanId,
            emiComponent: emiComponent,
            statementDate: statementDate,
          ));

  /// Adds or edits an EMI plan (and the claim it is, when someone else pays
  /// it). Resolves to the plan's id, or null when it could not be saved.
  Future<String?> savePlan(EmiPlan plan) async {
    final EmiPlanRepository? plans = _plans;
    final String? userId = _userId;
    if (plans == null || userId == null) return null;
    String? id;
    final bool ok = await guard(() async {
      if (plan.id.isEmpty) {
        id = await plans.create(userId: userId, plan: plan);
      } else {
        await plans.update(userId: userId, plan: plan);
        id = plan.id;
      }
    });
    if (ok) await _reload();
    return ok ? id : null;
  }

  Future<bool> deletePlan(String id) {
    final EmiPlanRepository? plans = _plans;
    if (plans == null) return Future<bool>.value(false);
    return _write((String userId) => plans.delete(userId: userId, id: id));
  }

  /// Money in that pays back an EMI someone else owes on a card — a
  /// repayment of the plan's claim, never income. [fromIncome]: an income it
  /// replaces. Resolves to whether it was saved and, when the replaced income
  /// could not be removed, a warning to show; [errorMessage] says why on
  /// failure.
  Future<({bool ok, String? warning})> recordEmiReimbursement({
    required EmiPlan plan,
    required String person,
    required String accountId,
    required double amount,
    required DateTime date,
    required double left,
    double allowance = 0,
    String? note,
    ({String id, String? bankAccountId})? fromIncome,
  }) async {
    final EmiPlanRepository? plans = _plans;
    final IncomeRepository? income = _income;
    final String? userId = _userId;
    if (plans == null || income == null || userId == null) {
      return (ok: false, warning: null);
    }
    String? warning;
    final bool ok = await guard(() async {
      warning = await plans.recordEmiReimbursement(
        userId: userId,
        ledger: _ledger,
        income: income,
        plan: plan,
        person: person,
        accountId: accountId,
        amount: amount,
        date: date,
        left: left,
        allowance: allowance,
        note: note,
        fromIncome: fromIncome,
      );
    });
    if (ok) await _reload();
    return (ok: ok, warning: warning);
  }

  /// Counts for a plan's delete confirmation; null when they could not be read.
  Future<({int components, int repayments})?> planActivity(String id) async {
    final EmiPlanRepository? plans = _plans;
    final String? userId = _userId;
    if (plans == null || userId == null) return null;
    try {
      return await plans.activity(userId: userId, id: id);
    } catch (_) {
      return null;
    }
  }

  /// Removes a movement from the table it lives in. A purchase is an expense
  /// and is edited or deleted there.
  Future<bool> deleteEntry(CardEntry entry) => _write((String userId) {
        switch (entry.source) {
          case CardEntrySource.card:
            return _repository.deleteTransaction(userId: userId, id: entry.id);
          case CardEntrySource.account:
            return _ledger.deleteEntry(userId: userId, id: entry.id);
          case CardEntrySource.expense:
            throw const AppException(
              'This purchase is an expense. Open it to edit or delete it.',
            );
        }
      });

  /// Recognises an existing bank debit as a card's bill payment (or, with a
  /// null [cardId], undoes that). No row is added.
  Future<bool> link({required String entryId, required String? cardId}) =>
      _write((String userId) => _ledger.linkToCard(
            userId: userId,
            entryId: entryId,
            cardId: cardId,
          ));

  /// Pays a card bill. From an account it is one debit on that account naming
  /// the card, checked against a balance re-derived from the ledger a moment
  /// before the write, as a transfer is. In cash it is one card transaction.
  /// Either way it is never an expense.
  Future<bool> payBill({
    required CreditCard card,
    required BankAccount? account,
    required double? amount,
    required DateTime date,
    String? note,
    String currencyCode = AppConstants.defaultCurrencyCode,
  }) =>
      _write((String userId) async {
        if (!available) {
          throw const AppException(
            'Credit cards need the 004 migration. Run '
            'supabase/004_credit_cards.sql, then try again.',
          );
        }
        final CardPaymentDraft draft = CardPaymentDraft(
          cardId: card.id,
          hasSource: true,
          accountId: account?.id,
          amount: amount,
          date: date,
          note: note,
        );
        final CardPaymentProblem? shape = checkCardPayment(draft, null);
        if (shape != null) throw AppException(shape.message());
        final String description = cardPaymentDescription(card, note);
        if (account == null) {
          await _repository.recordTransaction(
            userId: userId,
            cardId: card.id,
            kind: CardTransactionKind.payment,
            direction: LedgerDirection.credit,
            amount: amount!,
            date: date,
            description: description,
          );
          return;
        }
        final double balance = account.openingBalance +
            await _ledger.netFor(userId: userId, accountId: account.id);
        final CardPaymentProblem? problem = checkCardPayment(draft, balance);
        if (problem != null) {
          throw AppException(problem.message(
            sourceLabel: account.nickname,
            availableText:
                Formatters.currency(balance, currencyCode: currencyCode),
          ));
        }
        await _ledger.recordCardPayment(
          userId: userId,
          accountId: account.id,
          cardId: card.id,
          amount: amount!,
          date: date,
          description: description,
        );
      });

  /// Debits on [accountId] around [date] — the window Pay bill checks for a
  /// payment already on the account. Money lent before migration 014 is left
  /// out: it stays money lent and is never offered as a bill payment, as on
  /// the web. Empty when the read fails: the check is a guard, not a
  /// requirement, and the confirmation still runs.
  Future<List<LedgerEntry>?> nearbyDebits({
    required String accountId,
    required DateTime date,
  }) async {
    final String? userId = _userId;
    if (userId == null) return null;
    try {
      final List<Object> read = await Future.wait(<Future<Object>>[
        _ledger.fetchForAccount(
          userId: userId,
          accountId: accountId,
          from: DateTime(date.year, date.month, date.day - 4),
          toExclusive: DateTime(date.year, date.month, date.day + 5),
        ),
        _ledger.fetchLentEntryIds(userId: userId),
      ]);
      final Set<String> lent = read[1] as Set<String>;
      return (read[0] as List<LedgerEntry>)
          .where((LedgerEntry e) => !lent.contains(e.id))
          .toList();
    } catch (_) {
      return null;
    }
  }

  void reset() {
    _cards = <CreditCard>[];
    _entries = <CardEntry>[];
    _emiPlans = <EmiPlan>[];
    _userId = null;
    _stale = true;
    safeNotify();
  }
}
