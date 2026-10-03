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
  final DateTime? createdAt;

  /// The purchase's own expense row, so it can be opened and edited there.
  final Expense? expense;

  bool get isCharge => direction == LedgerDirection.debit;

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

int _cents(double value) => (value * 100).round();
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
  int total = _cents(openingOutstanding);
  for (final CardEntry e in entries) {
    total += _cents(e.outstandingDelta);
  }
  return _fromCents(total);
}

double _sum(Iterable<CardEntry> entries) {
  int total = 0;
  for (final CardEntry e in entries) {
    total += _cents(e.amount);
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

/// Walks every entry oldest-first from the opening outstanding, so a period's
/// opening figure includes all earlier history. [from]/[to] bound the rows
/// shown (inclusive); the filter is applied after the walk so it never
/// corrupts the running figure, and the totals describe the rows shown.
CardStatement buildCardStatement({
  required double openingOutstanding,
  required Iterable<CardEntry> entries,
  DateTime? from,
  DateTime? to,
  CardStatementFilter filter = CardStatementFilter.all,
}) {
  int running = _cents(openingOutstanding);
  int opening = running;
  final List<CardStatementRow> rows = <CardStatementRow>[];
  for (final CardEntry entry in orderEntries(entries)) {
    if (to != null && entry.date.isAfter(to)) break;
    running += _cents(entry.outstandingDelta);
    if (from != null && entry.date.isBefore(from)) {
      opening = running;
      continue;
    }
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
      !e.date.isBefore(currentCycle.start) &&
      !e.date.isAfter(currentCycle.end)));

  final BillingCycle cycle =
      cardCycleContaining(card, _addDays(currentCycle.start, -1));
  final double balance = outstandingOf(
    card.openingOutstanding,
    own.where((CardEntry e) => !e.date.isAfter(cycle.end)),
  );
  final double credited = _sum(
      own.where((CardEntry e) => !e.isCharge && e.date.isAfter(cycle.end)));
  final double remaining = balance > 0
      ? _fromCents(_cents(balance) - _cents(credited)).clamp(0, double.infinity)
      : 0;

  final DueStatus status;
  if (_cents(balance) <= 0) {
    status = DueStatus.nothingDue;
  } else if (_cents(remaining) <= 0) {
    status = DueStatus.paid;
  } else {
    status = day.isAfter(cycle.dueDate) ? DueStatus.overdue : DueStatus.due;
  }

  return CardSummary(
    outstanding: outstanding,
    available: limit > 0
        ? _fromCents(_cents(limit) - _cents(outstanding))
            .clamp(0, double.infinity)
        : 0,
    overLimit: limit > 0
        ? _fromCents(_cents(outstanding) - _cents(limit))
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
      _cents(amount) > _cents(availableBalance)) {
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
bool isLinkableDebit(LedgerEntry entry) =>
    entry.isDebit &&
    entry.expenseId == null &&
    entry.incomeId == null &&
    entry.transferGroupId == null &&
    entry.creditCardId == null;

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
  final int wanted = _cents(amount);
  final List<LedgerEntry> hits = entries
      .where((LedgerEntry e) =>
          isLinkableDebit(e) &&
          _cents(e.amount) == wanted &&
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
  final int wanted = _cents(amount);
  return entries
      .where((LedgerEntry e) =>
          e.isDebit &&
          e.expenseId != null &&
          _cents(e.amount) == wanted &&
          _daysBetween(e.txnDate, date).abs() <= nearbyDays)
      .toList();
}

// ---------------------------------------------------------------------------
// Bank SMS
// ---------------------------------------------------------------------------

final RegExp _billPaymentWording = RegExp(
  r'\b(credit ?card|cc)\b[^.]*\b(payment|pymt|bill|dues?|repayment)\b'
  r'|\bcard ?bill\b'
  r'|\btowards\b[^.]*\b(credit ?card|cc)\b',
  caseSensitive: false,
);

/// A bank alert that reads like paying a card bill rather than spending.
/// Such a debit is not an expense — the card purchases already are.
bool looksLikeCardBillPayment(String text) => _billPaymentWording.hasMatch(text);

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
