/// Credit cards: billing cycles, the card statement and its summary figures.
/// Pure, so every rule is unit-tested — a port of the web app's
/// `domain/creditCards.ts`, with the same rules and the same wording.
///
/// A card's movements live where the rest of the app already keeps them,
/// each stored exactly once:
///   purchase      an expense with `creditCardId` — spending, like any expense
///   bill payment  a bank ledger debit with `creditCardId` (from an account),
///                 or a card transaction of kind payment (cash)
///   refund, cashback, fee, interest, adjustment — a card transaction
/// They are merged here into one list of [CardEntry], seen from the card's
/// side: debit raises the outstanding, credit lowers it. Money is summed in
/// whole cents so long histories cannot drift.
library;

import 'bank_account.dart';
import 'credit_card.dart';
import 'expense.dart';
import 'expense_category.dart';
import 'ledger_entry.dart';
import 'money_transfer.dart';
import '../core/utils/money.dart';

// ---------------------------------------------------------------------------
// Entries
// ---------------------------------------------------------------------------

enum CardEntryKind { purchase, refund, cashback, payment, fee, interest, adjustment }

extension CardEntryKindLabel on CardEntryKind {
  String get label => switch (this) {
        CardEntryKind.purchase => 'Purchase',
        CardEntryKind.refund => 'Refund',
        CardEntryKind.cashback => 'Cashback',
        CardEntryKind.payment => 'Bill payment',
        CardEntryKind.fee => 'Fee',
        CardEntryKind.interest => 'Interest',
        CardEntryKind.adjustment => 'Adjustment',
      };

  static CardEntryKind fromTransaction(CardTransactionKind kind) =>
      switch (kind) {
        CardTransactionKind.refund => CardEntryKind.refund,
        CardTransactionKind.cashback => CardEntryKind.cashback,
        CardTransactionKind.payment => CardEntryKind.payment,
        CardTransactionKind.fee => CardEntryKind.fee,
        CardTransactionKind.interest => CardEntryKind.interest,
        CardTransactionKind.adjustment => CardEntryKind.adjustment,
      };
}

/// Which table a movement lives in — and therefore where it is edited.
enum CardEntrySource { expense, card, account }

/// The direction a card transaction must have; the database enforces the same pairs.
LedgerDirection directionForKind(
  CardTransactionKind kind, {
  LedgerDirection adjustment = LedgerDirection.debit,
}) =>
    switch (kind) {
      CardTransactionKind.refund ||
      CardTransactionKind.cashback ||
      CardTransactionKind.payment =>
        LedgerDirection.credit,
      CardTransactionKind.fee ||
      CardTransactionKind.interest =>
        LedgerDirection.debit,
      CardTransactionKind.adjustment => adjustment,
    };

/// One movement on a card, from whichever table it lives in.
class CardEntry {
  const CardEntry({
    required this.key,
    required this.source,
    required this.id,
    required this.cardId,
    required this.kind,
    required this.direction,
    required this.amount,
    required this.date,
    this.description,
    this.category,
    this.accountId,
    this.originalExpenseId,
    this.reference,
    this.emiPlanId,
    this.emiComponent,
    this.statementDate,
    this.createdAt,
    this.expense,
  });

  /// Unique across the three sources.
  final String key;
  final CardEntrySource source;

  /// The row's id in its own table.
  final String id;
  final String cardId;
  final CardEntryKind kind;
  final LedgerDirection direction;
  final double amount;
  final DateTime date;
  final String? description;
  final ExpenseCategory? category;

  /// The bank account a bill payment came from; null for cash and the rest.
  final String? accountId;
  final String? originalExpenseId;
  final String? reference;

  /// The EMI plan this is an instalment component of (migration 016).
  final String? emiPlanId;
  final String? emiComponent;

  /// The statement it was billed on, when the import knew it. The cycle it
  /// is filed under then comes from this date, not the transaction date.
  final DateTime? statementDate;
  final DateTime? createdAt;

  /// The purchase's own expense row, so it can be opened and edited there.
  final Expense? expense;

  bool get isCharge => direction == LedgerDirection.debit;

  /// The date the entry is filed under: the statement it was billed on when
  /// known (a 20 Aug charge billed on 20 Sep belongs to September), else the
  /// transaction date, which the card's statement day places in a cycle.
  DateTime get billingDate => statementDate ?? date;

  /// What the entry does to the outstanding.
  double get outstandingDelta => isCharge ? amount : -amount;

  String get title {
    final String? text = description?.trim();
    return (text != null && text.isNotEmpty) ? text : kind.label;
  }

  static CardEntry? fromExpense(Expense expense) {
    final String? cardId = expense.creditCardId;
    if (cardId == null) return null;
    return CardEntry(
      key: 'expense:${expense.id}',
      source: CardEntrySource.expense,
      id: expense.id,
      cardId: cardId,
      kind: CardEntryKind.purchase,
      direction: LedgerDirection.debit,
      amount: expense.amount,
      date: expense.expenseDate,
      description: expense.title,
      category: expense.category,
      emiPlanId: expense.emiPlanId,
      emiComponent: expense.emiComponent,
      statementDate: expense.statementDate,
      createdAt: expense.createdAt,
      expense: expense,
    );
  }

  static CardEntry fromCardTransaction(CardTransaction t) => CardEntry(
        key: 'card:${t.id}',
        source: CardEntrySource.card,
        id: t.id,
        cardId: t.cardId,
        kind: CardEntryKindLabel.fromTransaction(t.kind),
        direction: t.direction,
        amount: t.amount,
        date: t.txnDate,
        description: t.description,
        originalExpenseId: t.originalExpenseId,
        reference: t.reference,
        emiPlanId: t.emiPlanId,
        emiComponent: t.emiComponent,
        statementDate: t.statementDate,
        createdAt: t.createdAt,
      );

  /// A bank debit that paid the card: the same row that lowered the bank balance.
  static CardEntry? fromPayment(LedgerEntry entry) {
    final String? cardId = entry.creditCardId;
    if (cardId == null || !entry.isDebit) return null;
    return CardEntry(
      key: 'account:${entry.id}',
      source: CardEntrySource.account,
      id: entry.id,
      cardId: cardId,
      kind: CardEntryKind.payment,
      direction: LedgerDirection.credit,
      amount: entry.amount,
      date: entry.txnDate,
      description: entry.description,
      accountId: entry.accountId,
      createdAt: entry.createdAt,
    );
  }
}

double _fromCents(int cents) => cents / 100;

/// Oldest first; same-day movements by insertion time, then key — stable across reloads.
List<CardEntry> orderEntries(Iterable<CardEntry> entries) {
  final List<CardEntry> ordered = List<CardEntry>.of(entries);
  ordered.sort((CardEntry a, CardEntry b) {
    final int byDate = a.date.compareTo(b.date);
    if (byDate != 0) return byDate;
    final int byCreated = (a.createdAt ?? DateTime(1970))
        .compareTo(b.createdAt ?? DateTime(1970));
    if (byCreated != 0) return byCreated;
    return a.key.compareTo(b.key);
  });
  return ordered;
}

/// Opening outstanding plus every entry, in whole cents.
double outstandingOf(double openingOutstanding, Iterable<CardEntry> entries) {
  int total = toCents(openingOutstanding);
  for (final CardEntry e in entries) {
    total += toCents(e.outstandingDelta);
  }
  return _fromCents(total);
}

double _sum(Iterable<CardEntry> entries) {
  int total = 0;
  for (final CardEntry e in entries) {
    total += toCents(e.amount);
  }
  return _fromCents(total);
}

// ---------------------------------------------------------------------------
// Billing cycles
// ---------------------------------------------------------------------------

class BillingCycle {
  const BillingCycle({
    required this.start,
    required this.end,
    required this.dueDate,
  });

  /// First day of the cycle.
  final DateTime start;

  /// The statement date: the cycle's last day.
  final DateTime end;
  final DateTime dueDate;

  @override
  bool operator ==(Object other) =>
      other is BillingCycle &&
      other.start == start &&
      other.end == end &&
      other.dueDate == dueDate;

  @override
  int get hashCode => Object.hash(start, end, dueDate);

  @override
  String toString() => 'BillingCycle($start – $end, due $dueDate)';
}

DateTime _date(int year, int month, int day) => DateTime(year, month, day);

int _daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;

/// Day [day] of [anchor]'s month, clamped to that month's length (31 → 28 Feb).
DateTime dayInMonth(DateTime anchor, int day) {
  final int clamped = day.clamp(1, _daysInMonth(anchor.year, anchor.month));
  return _date(anchor.year, anchor.month, clamped);
}

DateTime _addMonths(DateTime anchor, int delta) =>
    DateTime(anchor.year, anchor.month + delta, 1);

DateTime _addDays(DateTime date, int delta) =>
    DateTime(date.year, date.month, date.day + delta);

/// The first [dueDay] strictly after the statement date.
DateTime dueDateAfter(DateTime statementDate, int dueDay) {
  final DateTime sameMonth = dayInMonth(statementDate, dueDay);
  return sameMonth.isAfter(statementDate)
      ? sameMonth
      : dayInMonth(_addMonths(statementDate, 1), dueDay);
}

/// The billing cycle that [date] falls in.
BillingCycle cycleContaining(DateTime date, int statementDay, int dueDay) {
  final DateTime day = DateTime(date.year, date.month, date.day);
  final DateTime closesThisMonth = dayInMonth(day, statementDay);
  final DateTime end = day.isAfter(closesThisMonth)
      ? dayInMonth(_addMonths(day, 1), statementDay)
      : closesThisMonth;
  final DateTime start =
      _addDays(dayInMonth(_addMonths(end, -1), statementDay), 1);
  return BillingCycle(
    start: start,
    end: end,
    dueDate: dueDateAfter(end, dueDay),
  );
}

BillingCycle cardCycleContaining(CreditCard card, DateTime date) =>
    cycleContaining(date, card.statementDay, card.paymentDueDay);

/// The cycle an entry is filed under: the one containing its billing date.
BillingCycle cardCycleOf(CreditCard card, CardEntry entry) =>
    cardCycleContaining(card, entry.billingDate);

/// The closed cycles a card has statements for, newest first: from the
/// cycle before the open one, [count] of them.
List<BillingCycle> recentCycles(CreditCard card, DateTime today, {int count = 12}) {
  final List<BillingCycle> cycles = <BillingCycle>[];
  BillingCycle cycle = cardCycleContaining(
      card, _addDays(cardCycleContaining(card, today).start, -1));
  for (int i = 0; i < count; i++) {
    cycles.add(cycle);
    cycle = cardCycleContaining(card, _addDays(cycle.start, -1));
  }
  return cycles;
}

// ---------------------------------------------------------------------------
// Statement
// ---------------------------------------------------------------------------

enum CardStatementFilter { all, charges, credits }

extension CardStatementFilterLabel on CardStatementFilter {
  String get label => switch (this) {
        CardStatementFilter.all => 'All',
        CardStatementFilter.charges => 'Charges',
        CardStatementFilter.credits => 'Payments & credits',
      };

  bool matches(CardEntry entry) => switch (this) {
        CardStatementFilter.all => true,
        CardStatementFilter.charges => entry.isCharge,
        CardStatementFilter.credits => !entry.isCharge,
      };
}

class CardStatementRow {
  const CardStatementRow({required this.entry, required this.outstandingAfter});

  final CardEntry entry;

  /// Outstanding immediately after [entry].
  final double outstandingAfter;
}

class CardStatement {
  const CardStatement({
    required this.opening,
    required this.closing,
    required this.rows,
    required this.purchases,
    required this.charges,
    required this.payments,
    required this.credits,
  });

  /// Outstanding carried into the period.
  final double opening;

  /// Outstanding at the end of the period, whatever the filter.
  final double closing;

  /// Newest first.
  final List<CardStatementRow> rows;
  final double purchases;

  /// Fees, interest and debit adjustments.
  final double charges;
  final double payments;

  /// Refunds, cashback and credit adjustments.
  final double credits;
}

/// A period's rows are the entries whose billing date falls in [from, to]
/// (inclusive), walked oldest-first from the opening outstanding — the
/// opening outstanding plus everything billed before the period, whatever
/// its transaction date, so a period's opening figure includes all earlier
/// history. The filter is applied after the walk so it never corrupts the
/// running figure, and the totals describe the rows shown.
CardStatement buildCardStatement({
  required double openingOutstanding,
  required Iterable<CardEntry> entries,
  DateTime? from,
  DateTime? to,
  CardStatementFilter filter = CardStatementFilter.all,
}) {
  final List<CardEntry> ordered = orderEntries(entries);
  bool before(CardEntry e) => from != null && e.billingDate.isBefore(from);
  bool after(CardEntry e) => to != null && e.billingDate.isAfter(to);
  int opening = toCents(openingOutstanding);
  for (final CardEntry e in ordered.where(before)) {
    opening += toCents(e.outstandingDelta);
  }
  int running = opening;
  final List<CardStatementRow> rows = <CardStatementRow>[];
  for (final CardEntry entry in ordered) {
    if (before(entry) || after(entry)) continue;
    running += toCents(entry.outstandingDelta);
    if (filter.matches(entry)) {
      rows.add(CardStatementRow(
        entry: entry,
        outstandingAfter: _fromCents(running),
      ));
    }
  }

  final List<CardEntry> shown =
      rows.map((CardStatementRow r) => r.entry).toList();
  bool other(CardEntry e) =>
      e.kind != CardEntryKind.purchase && e.kind != CardEntryKind.payment;
  return CardStatement(
    opening: _fromCents(opening),
    closing: _fromCents(running),
    rows: rows.reversed.toList(),
    purchases: _sum(shown.where((CardEntry e) => e.kind == CardEntryKind.purchase)),
    payments: _sum(shown.where((CardEntry e) => e.kind == CardEntryKind.payment)),
    charges: _sum(shown.where((CardEntry e) => other(e) && e.isCharge)),
    credits: _sum(shown.where((CardEntry e) => other(e) && !e.isCharge)),
  );
}

// ---------------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------------

enum DueStatus { nothingDue, paid, due, overdue }

class StatementDue {
  const StatementDue({
    required this.cycle,
    required this.balance,
    required this.credited,
    required this.remaining,
    required this.status,
    required this.daysToDue,
  });

  /// The last closed cycle.
  final BillingCycle cycle;

  /// Outstanding on the statement date — the bill.
  final double balance;

  /// Payments and other credits dated after the statement date.
  final double credited;

  /// What is still to pay for that bill.
  final double remaining;
  final DueStatus status;

  /// Days from today to the due date; negative once it has passed.
  final int daysToDue;

  /// "Due in 3 days", "Due today", "Overdue by 2 days", "Paid", "Nothing due".
  String get statusText => switch (status) {
        DueStatus.nothingDue => 'Nothing due',
        DueStatus.paid => 'Paid',
        DueStatus.overdue =>
          'Overdue by ${-daysToDue} ${-daysToDue == 1 ? 'day' : 'days'}',
        DueStatus.due => daysToDue == 0
            ? 'Due today'
            : 'Due in $daysToDue ${daysToDue == 1 ? 'day' : 'days'}',
      };
}

class CardSummary {
  const CardSummary({
    required this.outstanding,
    required this.available,
    required this.overLimit,
    required this.utilisation,
    required this.currentCycle,
    required this.unbilled,
    required this.lastStatement,
  });

  final double outstanding;

  /// Limit minus outstanding, never below zero.
  final double available;

  /// How far the outstanding is past the limit; 0 when within it.
  final double overLimit;

  /// Outstanding as a share of the limit (0 with no limit or a credit balance).
  final double utilisation;

  /// The open cycle, closing on the next statement date.
  final BillingCycle currentCycle;

  /// Charges dated in the open cycle — not yet on a statement.
  final double unbilled;
  final StatementDue lastStatement;

  bool get hasCreditBalance => outstanding < 0;
}

int _daysBetween(DateTime from, DateTime to) =>
    DateTime.utc(to.year, to.month, to.day)
        .difference(DateTime.utc(from.year, from.month, from.day))
        .inDays;

/// The card's headline figures on [today]. The opening outstanding counts as
/// billed before tracking began, so a card added mid-cycle shows it as due on
/// the last statement until a payment covers it.
CardSummary summariseCard(
  CreditCard card,
  Iterable<CardEntry> entries,
  DateTime today,
) {
  final DateTime day = DateTime(today.year, today.month, today.day);
  final List<CardEntry> own =
      entries.where((CardEntry e) => e.cardId == card.id).toList();
  final double outstanding = outstandingOf(card.openingOutstanding, own);
  final double limit = card.creditLimit > 0 ? card.creditLimit : 0;

  final BillingCycle currentCycle = cardCycleContaining(card, day);
  final double unbilled = _sum(own.where((CardEntry e) =>
      e.isCharge &&
      !e.billingDate.isBefore(currentCycle.start) &&
      !e.billingDate.isAfter(currentCycle.end)));

  final BillingCycle cycle =
      cardCycleContaining(card, _addDays(currentCycle.start, -1));
  final double balance = outstandingOf(
    card.openingOutstanding,
    own.where((CardEntry e) => !e.billingDate.isAfter(cycle.end)),
  );
  final double credited = _sum(own
      .where((CardEntry e) => !e.isCharge && e.billingDate.isAfter(cycle.end)));
  final double remaining = balance > 0
      ? _fromCents(toCents(balance) - toCents(credited)).clamp(0, double.infinity)
      : 0;

  final DueStatus status;
  if (toCents(balance) <= 0) {
    status = DueStatus.nothingDue;
  } else if (toCents(remaining) <= 0) {
    status = DueStatus.paid;
  } else {
    status = day.isAfter(cycle.dueDate) ? DueStatus.overdue : DueStatus.due;
  }

  return CardSummary(
    outstanding: outstanding,
    available: limit > 0
        ? _fromCents(toCents(limit) - toCents(outstanding))
            .clamp(0, double.infinity)
        : 0,
    overLimit: limit > 0
        ? _fromCents(toCents(outstanding) - toCents(limit))
            .clamp(0, double.infinity)
        : 0,
    utilisation: limit > 0 && outstanding > 0 ? outstanding / limit : 0,
    currentCycle: currentCycle,
    unbilled: unbilled,
    lastStatement: StatementDue(
      cycle: cycle,
      balance: balance,
      credited: credited,
      remaining: remaining,
      status: status,
      daysToDue: _daysBetween(day, cycle.dueDate),
    ),
  );
}

// ---------------------------------------------------------------------------
// Bill payment
// ---------------------------------------------------------------------------

enum CardPaymentProblem {
  noCard,
  noSource,
  invalidAmount,
  amountTooLarge,
  insufficientFunds,
}

extension CardPaymentProblemMessage on CardPaymentProblem {
  String message({String? sourceLabel, String? availableText}) =>
      switch (this) {
        CardPaymentProblem.noCard => 'Choose the card you are paying.',
        CardPaymentProblem.noSource => 'Choose where the payment comes from.',
        CardPaymentProblem.invalidAmount => 'Enter an amount greater than 0.',
        CardPaymentProblem.amountTooLarge => 'That amount is too large.',
        CardPaymentProblem.insufficientFunds => availableText == null
            ? 'Not enough money in ${sourceLabel ?? 'that account'}.'
            : '${sourceLabel ?? 'That account'} only has $availableText '
                'available.',
      };
}

/// Where a bill payment comes from: a tracked bank account ([accountId]), or
/// cash (null).
class CardPaymentDraft {
  const CardPaymentDraft({
    required this.cardId,
    required this.hasSource,
    required this.accountId,
    required this.amount,
    required this.date,
    this.note,
  });

  final String? cardId;

  /// False until the user has chosen account or cash.
  final bool hasSource;

  /// Null with [hasSource] means cash.
  final String? accountId;
  final double? amount;
  final DateTime date;
  final String? note;

  bool get fromAccount => hasSource && accountId != null;
}

/// Validates a bill payment. [availableBalance] is the paying account's
/// balance (null for cash, or to check only the rules that need no balance),
/// compared in whole cents. Paying more than the outstanding is allowed: it
/// leaves a credit balance, as a real overpayment does.
CardPaymentProblem? checkCardPayment(
  CardPaymentDraft draft,
  double? availableBalance,
) {
  if (draft.cardId == null) return CardPaymentProblem.noCard;
  if (!draft.hasSource) return CardPaymentProblem.noSource;
  final double? amount = draft.amount;
  if (amount == null || amount.isNaN || amount <= 0) {
    return CardPaymentProblem.invalidAmount;
  }
  if (amount > TransferValidation.maxAmount) return CardPaymentProblem.amountTooLarge;
  if (draft.fromAccount &&
      availableBalance != null &&
      availableBalance.isFinite &&
      toCents(amount) > toCents(availableBalance)) {
    return CardPaymentProblem.insufficientFunds;
  }
  return null;
}

/// The description stored on the payment: the user's note, else one that names the card.
String cardPaymentDescription(CreditCard card, String? note) {
  final String? text = note?.trim();
  return (text != null && text.isNotEmpty)
      ? text
      : '${card.displayLabel} bill payment';
}

// ---------------------------------------------------------------------------
// Reconciliation with the bank ledger
// ---------------------------------------------------------------------------

/// A bank debit that can be recognised as a bill payment: entered by hand or
/// imported from a statement — not an expense, income or transfer leg, and
/// not already linked to a card.
///
/// Money lent stays money lent (as on the web, where such a debit carries its
/// claim): [lentIds] are the debits recorded as money lent, which are never
/// offered as a card payment — change them from their edit sheet instead.
bool isLinkableDebit(LedgerEntry entry, {Set<String> lentIds = const <String>{}}) =>
    entry.isDebit &&
    entry.expenseId == null &&
    entry.incomeId == null &&
    entry.transferGroupId == null &&
    entry.creditCardId == null &&
    // A balance adjustment's row belongs to the database (migration 021).
    !entry.isBalanceAdjustment &&
    !lentIds.contains(entry.id);

const int paymentMatchDays = 3;

/// Unlinked debits of exactly [amount] within [nearbyDays] of [date], closest
/// first: the payment may already be on the account (imported from a
/// statement), in which case linking it avoids debiting the account twice.
List<LedgerEntry> findLinkableDebits(
  Iterable<LedgerEntry> entries,
  double amount,
  DateTime date, {
  int nearbyDays = paymentMatchDays,
}) {
  final int wanted = toCents(amount);
  final List<LedgerEntry> hits = entries
      .where((LedgerEntry e) =>
          isLinkableDebit(e) &&
          toCents(e.amount) == wanted &&
          _daysBetween(e.txnDate, date).abs() <= nearbyDays)
      .toList();
  hits.sort((LedgerEntry a, LedgerEntry b) {
    final int byDistance = _daysBetween(a.txnDate, date)
        .abs()
        .compareTo(_daysBetween(b.txnDate, date).abs());
    return byDistance != 0 ? byDistance : a.txnDate.compareTo(b.txnDate);
  });
  return hits;
}

/// Expense-backed debits of exactly [amount] near [date]. If a bill payment
/// was imported or typed as an expense, recording the payment again would
/// debit the account twice and count the bill as spending — so the user is
/// warned.
List<LedgerEntry> findExpenseDebits(
  Iterable<LedgerEntry> entries,
  double amount,
  DateTime date, {
  int nearbyDays = paymentMatchDays,
}) {
  final int wanted = toCents(amount);
  return entries
      .where((LedgerEntry e) =>
          e.isDebit &&
          e.expenseId != null &&
          toCents(e.amount) == wanted &&
          _daysBetween(e.txnDate, date).abs() <= nearbyDays)
      .toList();
}

/// How far apart two records of the same bill payment can be: the day it was
/// paid and the day the bank or the card posted it.
const int paymentDuplicateDays = 10;

/// Payments of [cardId] for exactly [amount] within [windowDays] of [date] —
/// from an account (a ledger debit linked to the card) or on the card alone
/// (cash, not tracked, or a card statement imported before the bank one).
/// Recording the same bill again would lower the outstanding twice. Closest
/// first. The web's `findRecordedPayments`.
List<CardEntry> findRecordedPayments(
  Iterable<CardEntry> entries, {
  required String cardId,
  required double amount,
  required DateTime date,
  int windowDays = paymentDuplicateDays,
}) {
  final int wanted = toCents(amount);
  final List<CardEntry> hits = entries
      .where((CardEntry e) =>
          e.kind == CardEntryKind.payment &&
          e.cardId == cardId &&
          toCents(e.amount) == wanted &&
          _daysBetween(e.date, date).abs() <= windowDays)
      .toList()
    ..sort((CardEntry a, CardEntry b) {
      final int byDistance = _daysBetween(a.date, date)
          .abs()
          .compareTo(_daysBetween(b.date, date).abs());
      return byDistance != 0 ? byDistance : a.key.compareTo(b.key);
    });
  return hits;
}

// ---------------------------------------------------------------------------
// Bill payments, for the record (never spending)
// ---------------------------------------------------------------------------

/// The card accounting rules this app applies from this date on (the billing
/// cycle of 20 Oct – 20 Nov 2026): a card statement's EMI interest, GST and
/// processing fees are imported as expenses, so the whole instalment is
/// spending. Nothing dated earlier is rewritten or re-imported differently.
/// The web's `CARD_RULES_FROM`.
final DateTime cardRulesFrom = DateTime(2026, 10, 20);

/// Whether a row dated [date] is under the card accounting rules.
bool underCardRules(DateTime date) =>
    !DateTime(date.year, date.month, date.day).isBefore(cardRulesFrom);

enum BillPaymentStatus { full, partial, advance }

extension BillPaymentStatusLabel on BillPaymentStatus {
  String get label => switch (this) {
        BillPaymentStatus.full => 'Paid in full',
        BillPaymentStatus.partial => 'Partially paid',
        BillPaymentStatus.advance => 'Advance payment',
      };
}

const String possibleDuplicateLabel = 'Possible duplicate';

/// Where a card-side payment's money came from: no tracked account.
const String untrackedPaymentSource = 'Cash / not tracked';

/// Whether a bill payment was drawn from an account or recorded on the card alone.
enum BillPaymentSource { bank, card }

/// One bill payment, for the record: it lowered the card outstanding (and,
/// from an account, the bank balance) and is never spending.
class CardBillPaymentRow {
  const CardBillPaymentRow({
    required this.id,
    required this.source,
    required this.entryId,
    required this.date,
    required this.amount,
    required this.cardId,
    required this.cardLabel,
    required this.accountId,
    required this.accountLabel,
    required this.status,
    required this.duplicateOfId,
  });

  /// The card entry's key (`account:…` or `card:…`).
  final String id;
  final BillPaymentSource source;

  /// The row's id in its own table (account_transactions or
  /// credit_card_transactions).
  final String entryId;
  final DateTime date;
  final double amount;
  final String cardId;
  final String cardLabel;
  final String? accountId;
  final String accountLabel;
  final BillPaymentStatus status;

  /// The other record of the same payment: a bank-side and a card-side one
  /// for the same card and amount within [paymentDuplicateDays].
  final String? duplicateOfId;

  bool get possibleDuplicate => duplicateOfId != null;
}

/// Every bill payment in [from]–[to] (inclusive; null for no bound), newest
/// first — informational only. The web's `cardBillPayments`.
///
/// status — against the latest statement generated before the payment: the
/// card's payments from that statement's date up to and including this one
/// covering the statement's amount is full, less is partial; with nothing due
/// on that statement (or none yet) it is an advance.
List<CardBillPaymentRow> cardBillPayments({
  required Iterable<CardEntry> entries,
  required Iterable<CreditCard> cards,
  required Iterable<BankAccount> accounts,
  DateTime? from,
  DateTime? to,
}) {
  final List<CardEntry> all = entries.toList();
  final List<BankAccount> accountList = accounts.toList();
  final List<CardBillPaymentRow> rows = <CardBillPaymentRow>[];
  for (final CreditCard card in cards) {
    final List<CardEntry> own =
        orderEntries(all.where((CardEntry e) => e.cardId == card.id));
    final List<CardEntry> payments =
        own.where((CardEntry e) => e.kind == CardEntryKind.payment).toList();
    for (final CardEntry payment in payments) {
      if (from != null && payment.date.isBefore(from)) continue;
      if (to != null && payment.date.isAfter(to)) continue;
      // The statement it pays: the cycle before the one the payment falls in.
      final BillingCycle cycle = cardCycleContaining(
          card, _addDays(cardCycleContaining(card, payment.date).start, -1));
      final double bill = outstandingOf(
        card.openingOutstanding,
        own.where((CardEntry e) => !e.billingDate.isAfter(cycle.end)),
      );
      BillPaymentStatus status = BillPaymentStatus.advance;
      if (toCents(bill) > 0) {
        final int index = own.indexOf(payment);
        int paidSoFar = 0;
        for (final CardEntry e in own.take(index + 1)) {
          if (e.kind == CardEntryKind.payment && e.date.isAfter(cycle.end)) {
            paidSoFar += toCents(e.amount);
          }
        }
        status = paidSoFar >= toCents(bill)
            ? BillPaymentStatus.full
            : BillPaymentStatus.partial;
      }
      CardEntry? other;
      for (final CardEntry p in payments) {
        if (p.key != payment.key &&
            p.source != payment.source &&
            toCents(p.amount) == toCents(payment.amount) &&
            _daysBetween(p.date, payment.date).abs() <= paymentDuplicateDays) {
          other = p;
          break;
        }
      }
      BankAccount? account;
      for (final BankAccount a in accountList) {
        if (a.id == payment.accountId) account = a;
      }
      final bool fromBank = payment.source == CardEntrySource.account;
      rows.add(CardBillPaymentRow(
        id: payment.key,
        source: fromBank ? BillPaymentSource.bank : BillPaymentSource.card,
        entryId: payment.id,
        date: payment.date,
        amount: payment.amount,
        cardId: card.id,
        cardLabel: card.displayLabel,
        accountId: payment.accountId,
        accountLabel: fromBank
            ? (account?.displayLabel ?? 'Bank account')
            : untrackedPaymentSource,
        status: status,
        duplicateOfId: other?.key,
      ));
    }
  }
  rows.sort((CardBillPaymentRow a, CardBillPaymentRow b) {
    final int byDate = b.date.compareTo(a.date);
    return byDate != 0 ? byDate : b.id.compareTo(a.id);
  });
  return rows;
}

/// The total of [rows] — what went to the cards, never part of spending.
double billPaymentsTotal(Iterable<CardBillPaymentRow> rows) =>
    _fromCents(rows.fold<int>(0, (int s, CardBillPaymentRow r) => s + toCents(r.amount)));

// ---------------------------------------------------------------------------
// Bank SMS
// ---------------------------------------------------------------------------

/// Wording that says a debit pays a credit-card bill — the bank's own
/// narration ("CC PAYMENT", "credit card bill"), an alert ("paid towards your
/// credit card") or a third-party bill rail (CRED, BillDesk, BBPS, PayZapp…).
/// Such a debit is never spending: the card purchases already are. Ported
/// from the web's `BILL_PAYMENT_WORDING`.
const String _cardWords = r'(credit ?cards?|cc)';
final RegExp _billPaymentWording = RegExp(
  <String>[
    '\\b$_cardWords\\b[^.]*\\b(payments?|pymt|pmt|bill|bills|dues?|repayment|pay)\\b',
    r'\bcard ?bills?\b',
    r'\bcc ?bill\b',
    '\\btowards\\b[^.]*\\b$_cardWords\\b',
    // Third-party bill rails: always a card bill when they say so, or by name for CRED.
    r'\bcred(\s?club)?\b',
    r'\bcred\.club\b',
    '\\b(billdesk|bbps|bharat ?bill ?pay|payzapp|amazon ?pay|phonepe|paytm|mobikwik|gpay|google ?pay)\\b[^.]*\\b$_cardWords\\b',
    '\\b$_cardWords\\b[^.]*\\b(billdesk|bbps|bharat ?bill ?pay)\\b',
  ].join('|'),
  caseSensitive: false,
);

/// Credits and rewards that mention the card but pay nothing.
final RegExp _notABill = RegExp(
  r'\b(cash ?back|reward|refund|reversal|reversed|surcharge waiver|emi conversion)\b',
  caseSensitive: false,
);

/// A bank narration, alert or note that reads like paying a card bill rather
/// than spending. Such a debit is not an expense — the card purchases already
/// are — so imports record it as the card's bill payment and forms warn.
bool looksLikeCardBillPayment(String text) =>
    !_notABill.hasMatch(text) && _billPaymentWording.hasMatch(text);

const List<(String, String)> _billRails = <(String, String)>[
  (r'\bcred(\s?club|\.club)?\b', 'CRED'),
  (r'\bbilldesk\b', 'BillDesk'),
  (r'\b(bbps|bharat ?bill ?pay)\b', 'BBPS'),
  (r'\bpayzapp\b', 'PayZapp'),
  (r'\bamazon ?pay\b', 'Amazon Pay'),
  (r'\bphonepe\b', 'PhonePe'),
  (r'\bpaytm\b', 'Paytm'),
  (r'\bmobikwik\b', 'MobiKwik'),
  (r'\b(gpay|google ?pay)\b', 'Google Pay'),
];

/// The third-party service a card bill was paid through ("CRED"), or null
/// for the bank's own.
String? cardBillRail(String text) {
  for (final (String pattern, String name) in _billRails) {
    if (RegExp(pattern, caseSensitive: false).hasMatch(text)) return name;
  }
  return null;
}

/// A category whose name says it is for card bills ("Credit card bill",
/// "Card payment").
bool isCardBillCategoryName(String? name) => RegExp(
      r'\b(credit ?card|card)\b.*\b(bill|payment|dues?|repayment)\b|\bcc ?bill\b',
      caseSensitive: false,
    ).hasMatch(name ?? '');

String? _lastDigits(String? raw) {
  final String digits = (raw ?? '').replaceAll(RegExp(r'\D'), '');
  return digits.length < 4 ? null : digits.substring(digits.length - 4);
}

/// The card a spend alert is about. Only digits identify a card: the one
/// active card ending in them, when the message says "credit card" or no
/// bank account ends in the same digits. Never guesses between candidates.
CreditCard? matchSmsCard({
  required String text,
  required String? last4,
  required Iterable<CreditCard> cards,
  required Iterable<BankAccount> accounts,
}) {
  if (last4 == null) return null;
  final List<CreditCard> hits = cards
      .where((CreditCard c) => c.isActive && _lastDigits(c.last4) == last4)
      .toList();
  if (hits.length != 1) return null;
  final bool saysCreditCard =
      RegExp(r'\bcredit\s*card\b', caseSensitive: false).hasMatch(text);
  final bool bankHasDigits = accounts
      .any((BankAccount a) => a.isActive && _lastDigits(a.last4) == last4);
  return saysCreditCard || !bankHasDigits ? hits.first : null;
}

/// One line on the bill: what is due and when, or that it is paid.
String dueSummaryText(
  CardSummary summary,
  String Function(double) money,
  String Function(DateTime) dayMonth,
) {
  final StatementDue due = summary.lastStatement;
  return switch (due.status) {
    DueStatus.due => '${money(due.remaining)} due ${dayMonth(due.cycle.dueDate)}',
    DueStatus.overdue =>
      '${money(due.remaining)} was due ${dayMonth(due.cycle.dueDate)}',
    DueStatus.paid => '${dayMonth(due.cycle.end)} statement paid',
    DueStatus.nothingDue =>
      'No bill due · next statement ${dayMonth(summary.currentCycle.end)}',
  };
}
