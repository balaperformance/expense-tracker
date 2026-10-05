import '../core/utils/date_utils.dart';
import '../core/utils/formatters.dart';
import 'bank_account.dart';
import 'credit_card.dart';
import 'ledger_entry.dart';
import 'money_transfer.dart';
import 'receivable.dart';

/// What a recorded bank movement is recorded as — the "Record as" choice of
/// the account statement's edit sheet — held the way that sheet holds it.
///
/// The JSON body sent to `apply_bank_treatment` is NOT built here: this
/// builds the web domain's `TreatmentRequest` and the statement engine (the
/// web app's own `treatmentPayload`, ui/src/domain/treatment.ts) turns it
/// into the body, so both apps send exactly the same thing. What is mirrored
/// here is only what the form needs synchronously: the opening choice of a
/// saved movement, what is still missing, and the wording.

/// The kinds, by the engine's names.
class TreatmentKind {
  const TreatmentKind._();

  static const String expense = 'expense';
  static const String income = 'income';
  static const String refund = 'refund';
  static const String transfer = 'transfer';
  static const String loan = 'loan';
  static const String reimbursement = 'reimbursement';
}

const Map<String, String> treatmentLabels = <String, String>{
  TreatmentKind.expense: 'Expense',
  TreatmentKind.income: 'Income',
  TreatmentKind.refund: 'Refund',
  TreatmentKind.transfer: 'Transfer',
  TreatmentKind.loan: 'Loan',
  TreatmentKind.reimbursement: 'Reimbursement',
};

/// Only until the engine answers `kindsFor` (the web's `availableKinds`),
/// which decides: money out can't be income, money in can't be an expense,
/// and loans and reimbursements need migration 005.
List<String> fallbackKinds({required bool debit, required bool treatments}) =>
    (debit
            ? const <String>[TreatmentKind.expense, TreatmentKind.transfer, TreatmentKind.loan]
            : const <String>[
                TreatmentKind.income,
                TreatmentKind.refund,
                TreatmentKind.transfer,
                TreatmentKind.loan,
                TreatmentKind.reimbursement,
              ])
        .where((String k) =>
            treatments || (k != TreatmentKind.loan && k != TreatmentKind.reimbursement))
        .toList();

/// One line under "Record as" for the treatments that are neither income
/// nor spending.
String? treatmentHint(String kind, {required bool debit}) => switch (kind) {
      TreatmentKind.refund => 'Balance only — not counted as income',
      TreatmentKind.transfer => 'Your own money moving — not income or spending',
      TreatmentKind.loan =>
        debit ? 'Owed back to you — not spending' : 'Repays a loan — not income',
      TreatmentKind.reimbursement => 'Pays back a purchase — not income',
      _ => null,
    };

/// Where a transfer went (money out) or came from (money in).
class TransferTarget {
  const TransferTarget.account(String this.accountId)
      : type = 'account',
        cardId = null;

  /// Money out only: paying the card's bill.
  const TransferTarget.card(String this.cardId)
      : type = 'card',
        accountId = null;

  /// Cash, or an account not tracked here: the balance moves and nothing else.
  const TransferTarget.cash()
      : type = 'cash',
        accountId = null,
        cardId = null;

  final String type;
  final String? accountId;
  final String? cardId;

  bool get isAccount => type == 'account';
  bool get isCard => type == 'card';
  bool get isCash => type == 'cash';

  Map<String, Object?> toJson() => <String, Object?>{
        'type': type,
        if (accountId != null) 'accountId': accountId,
        if (cardId != null) 'cardId': cardId,
      };

  @override
  bool operator ==(Object other) =>
      other is TransferTarget &&
      other.type == type &&
      other.accountId == accountId &&
      other.cardId == cardId;

  @override
  int get hashCode => Object.hash(type, accountId, cardId);
}

/// What a repayment or reimbursement pays back.
class SettlementTarget {
  /// A loan or a paid-for purchase already recorded.
  const SettlementTarget.claim(String this.receivableId, ReceivableKind this.kind)
      : expenseId = null;

  /// A purchase not yet marked as paid for someone — marked now, for the
  /// person paying back.
  const SettlementTarget.expense(String this.expenseId)
      : receivableId = null,
        kind = null;

  final String? receivableId;
  final String? expenseId;

  /// Null for a purchase not yet marked.
  final ReceivableKind? kind;

  bool get isExpense => expenseId != null;

  String get key => receivableId != null ? 'claim:$receivableId' : 'expense:$expenseId';

  @override
  bool operator ==(Object other) => other is SettlementTarget && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

/// The editable treatment of one movement.
class TreatmentState {
  const TreatmentState({
    required this.kind,
    this.categoryId,
    this.target,
    this.person = '',
    this.dueDate,
    this.note = '',
    this.reimbursable = false,
    this.settles,
  });

  final String kind;
  final String? categoryId;
  final TransferTarget? target;

  /// Who was lent to, who was paid for, or who is paying back.
  final String person;
  final DateTime? dueDate;
  final String note;

  /// An expense paid on someone else's behalf: it is owed back and is not
  /// your spending.
  final bool reimbursable;
  final SettlementTarget? settles;
}

enum TreatmentProblem {
  category,
  transferTarget,
  loanPerson,
  loan,
  settles,
  settlePerson,
  paidForPerson,
}

/// The first thing missing before the treatment can be saved, or null — the
/// web's `treatmentProblem`.
TreatmentProblem? treatmentProblem(TreatmentState state, {required bool debit}) {
  final String person = state.person.trim();
  final SettlementTarget? settles = state.settles;
  switch (state.kind) {
    case TreatmentKind.expense:
      if (state.categoryId == null) return TreatmentProblem.category;
      return state.reimbursable && person.isEmpty ? TreatmentProblem.paidForPerson : null;
    case TreatmentKind.transfer:
      return state.target == null ? TreatmentProblem.transferTarget : null;
    case TreatmentKind.loan:
      if (debit) return person.isEmpty ? TreatmentProblem.loanPerson : null;
      return settles != null && !settles.isExpense && settles.kind == ReceivableKind.loan
          ? null
          : TreatmentProblem.loan;
    case TreatmentKind.reimbursement:
      if (settles == null || (!settles.isExpense && settles.kind != ReceivableKind.reimbursable)) {
        return TreatmentProblem.settles;
      }
      return settles.isExpense && person.isEmpty ? TreatmentProblem.settlePerson : null;
    default:
      return null;
  }
}

String treatmentProblemMessage(TreatmentProblem problem, {required bool debit}) =>
    switch (problem) {
      TreatmentProblem.category => 'Choose a category for this expense.',
      TreatmentProblem.transferTarget =>
        debit ? 'Choose where the money went.' : 'Choose where the money came from.',
      TreatmentProblem.loanPerson => 'Add who you lent the money to.',
      TreatmentProblem.loan => 'Choose the loan this repays.',
      TreatmentProblem.settles => 'Choose the purchase this pays back.',
      TreatmentProblem.settlePerson => 'Add who is paying you back.',
      TreatmentProblem.paidForPerson => 'Add who you paid for.',
    };

/// How a movement relates to a claim: the money that went out ([isSource]:
/// money lent, a purchase paid for someone), or a repayment of it.
class EntryClaim {
  const EntryClaim({required this.summary, required this.isSource});

  final ClaimSummary summary;
  final bool isSource;

  Receivable get receivable => summary.receivable;
}

/// The claim [entry] belongs to, from the user's claims — what the web fills
/// in on each movement as it reads the statement.
EntryClaim? claimOfEntry(LedgerEntry entry, List<ClaimSummary> claims) {
  final String? receivableId = entry.receivableId;
  if (receivableId != null) {
    for (final ClaimSummary c in claims) {
      if (c.receivable.id == receivableId) return EntryClaim(summary: c, isSource: false);
    }
  }
  for (final ClaimSummary c in claims) {
    if (c.receivable.ledgerEntryId != null && c.receivable.ledgerEntryId == entry.id) {
      return EntryClaim(summary: c, isSource: true);
    }
  }
  final String? expenseId = entry.expenseId;
  if (expenseId != null) {
    for (final ClaimSummary c in claims) {
      if (c.receivable.expenseId == expenseId) return EntryClaim(summary: c, isSource: true);
    }
  }
  return null;
}

/// The "Record as" choice and details of a movement already saved — what its
/// edit sheet opens with (the web's `treatmentOfEntry`).
TreatmentState initialTreatment(LedgerEntry entry, EntryClaim? claim) {
  if (entry.expenseId != null) {
    final bool paidFor =
        claim != null && claim.isSource && claim.receivable.kind == ReceivableKind.reimbursable;
    return TreatmentState(
      kind: TreatmentKind.expense,
      categoryId: entry.categoryId,
      reimbursable: paidFor,
      person: paidFor ? claim.receivable.person : '',
    );
  }
  if (entry.incomeId != null) return const TreatmentState(kind: TreatmentKind.income);
  if (entry.transferGroupId != null) {
    return TreatmentState(
      kind: TreatmentKind.transfer,
      target: entry.counterpartyAccountId != null
          ? TransferTarget.account(entry.counterpartyAccountId!)
          : null,
    );
  }
  if (entry.creditCardId != null) {
    return TreatmentState(
      kind: TreatmentKind.transfer,
      target: TransferTarget.card(entry.creditCardId!),
    );
  }
  if (claim != null && claim.isSource && claim.receivable.kind == ReceivableKind.loan) {
    return TreatmentState(kind: TreatmentKind.loan, person: claim.receivable.person);
  }
  final String? receivableId = entry.receivableId;
  if (receivableId != null) {
    final ReceivableKind kind = claim?.receivable.kind ?? ReceivableKind.reimbursable;
    return TreatmentState(
      kind: kind == ReceivableKind.loan ? TreatmentKind.loan : TreatmentKind.reimbursement,
      person: claim?.receivable.person ?? '',
      settles: SettlementTarget.claim(receivableId, kind),
    );
  }
  // A plain movement: money out with no other record went to cash or an
  // untracked account.
  return entry.isDebit
      ? const TreatmentState(kind: TreatmentKind.transfer, target: TransferTarget.cash())
      : const TreatmentState(kind: TreatmentKind.refund);
}

/// Whether [entry] is one leg of a transfer with one of the user's accounts.
bool isAccountTransfer(LedgerEntry entry) =>
    entry.transferGroupId != null && entry.counterpartyAccountId != null;

/// Whether this edit keeps [entry]'s transfer: still a transfer, to the same
/// account.
bool keepsTransfer(LedgerEntry entry, TreatmentState state) =>
    state.kind == TreatmentKind.transfer &&
    isAccountTransfer(entry) &&
    state.target == initialTreatment(entry, null).target;

/// The account a transfer moves to (or from) that it did not before — the
/// one whose rows may already hold the other side. Null otherwise.
String? newTransferAccountId(LedgerEntry entry, TreatmentState state) {
  final TransferTarget? target = state.target;
  if (state.kind != TreatmentKind.transfer || target == null || !target.isAccount) return null;
  return keepsTransfer(entry, state) ? null : target.accountId;
}

/// Whether the movement's own claim stops: money lent recorded as something
/// else, or a paid-for purchase no longer paid for anyone.
bool stopsOwnClaim(EntryClaim? own, TreatmentState state) {
  if (own == null || !own.isSource) return false;
  return own.receivable.kind == ReceivableKind.loan
      ? state.kind != TreatmentKind.loan
      : state.kind != TreatmentKind.expense || !state.reimbursable;
}

/// The web domain's `TreatmentRequest` for this edit, exactly as the web's
/// edit sheet builds it — the engine's `treatmentPayload` turns it into the
/// body of `apply_bank_treatment`. [matchEntryId]: the other account's row
/// chosen as the other leg of a new transfer (null adds one).
Map<String, Object?> buildTreatmentRequest({
  required LedgerEntry entry,
  required BankAccount account,
  required TreatmentState state,
  required double amount,
  required DateTime date,
  required String description,
  String source = '',
  bool keepCounterpart = false,
  String? matchEntryId,
  EntryClaim? claim,
}) {
  final bool debit = entry.isDebit;
  final EntryClaim? own = claim != null && claim.isSource ? claim : null;
  final Map<String, Object?> request = <String, Object?>{
    'kind': state.kind,
    'direction': entry.direction.wire,
    'amount': amount,
    'date': AppDateUtils.toDateString(date),
    'description': description,
    'keepPreviousCounterpart':
        isAccountTransfer(entry) && !keepsTransfer(entry, state) && keepCounterpart,
  };
  switch (state.kind) {
    case TreatmentKind.expense:
      request['categoryId'] = state.categoryId;
      // A movement that becomes an expense keeps its text as the expense's
      // description.
      if (entry.expenseId == null) request['expenseDescription'] = description;
      request['reimbursablePerson'] = state.reimbursable ? state.person.trim() : null;
      if (state.reimbursable && own != null) {
        final DateTime? due = own.receivable.dueDate;
        request['dueDate'] = due == null ? null : AppDateUtils.toDateString(due);
        request['note'] = own.receivable.note;
      }
    case TreatmentKind.income:
      request['source'] = source;
      if (entry.incomeId == null) request['incomeDescription'] = description;
    case TreatmentKind.transfer:
      request['transferTarget'] = state.target?.toJson();
      if (newTransferAccountId(entry, state) != null) {
        request['matchEntryId'] = matchEntryId;
        request['counterpartDescription'] = transferDescription(
          note: null,
          isOutgoing: !debit,
          counterpartyLabel: account.nickname,
        );
      }
    case TreatmentKind.loan when debit:
      request['person'] = state.person;
      request['dueDate'] =
          state.dueDate == null ? null : AppDateUtils.toDateString(state.dueDate!);
      request['note'] = state.note;
    default:
      final SettlementTarget? settles = state.settles;
      request['settles'] = settles == null
          ? null
          : settles.isExpense
              ? <String, Object?>{'expenseId': settles.expenseId, 'person': state.person.trim()}
              : <String, Object?>{'receivableId': settles.receivableId};
  }
  return request;
}

// ---------------------------------------------------------------------------
// What a repayment or reimbursement can pay back (ui/src/components/finance/
// settleOptions.ts)
// ---------------------------------------------------------------------------

class SettleOption {
  const SettleOption({
    required this.target,
    required this.label,
    required this.principal,
    required this.received,
    this.person,
  });

  final SettlementTarget target;
  final String label;

  /// The person it is with, when known (a purchase not yet paid for anyone
  /// has none).
  final String? person;

  /// What went out.
  final double principal;

  /// What has come back already, not counting this movement.
  final double received;

  String get key => target.key;
}

int _cents(double value) => (value * 100).round();

/// Open claims of [kind], plus the one [current] points at even if settled.
/// [excludeEntryId] is the movement being edited — its own earlier amount is
/// not counted as already received.
List<SettleOption> claimOptions({
  required List<ClaimSummary> claims,
  required ReceivableKind kind,
  required SettlementTarget? current,
  required String? excludeEntryId,
  required String currency,
}) {
  final String? currentId = current?.receivableId;
  return claims
      .where((ClaimSummary c) =>
          c.receivable.kind == kind &&
          c.source != null &&
          (c.status.isOpen || c.receivable.id == currentId))
      .map((ClaimSummary c) {
    final int counted = c.repayments
        .where((ClaimRepayment r) => r.entryId != excludeEntryId)
        .fold<int>(0, (int sum, ClaimRepayment r) => sum + _cents(r.amount));
    final double received = counted / 100;
    final double left = (_cents(c.principal) - counted) / 100;
    final ClaimSource source = c.source!;
    final String day = Formatters.dayMonth(source.date);
    final String what =
        kind == ReceivableKind.loan ? 'lent $day' : '${source.title} · $day';
    return SettleOption(
      target: SettlementTarget.claim(c.receivable.id, kind),
      label: '${c.receivable.person} · ${Formatters.currency(left, currencyCode: currency)} '
          'left of ${Formatters.currency(c.principal, currencyCode: currency)} · $what',
      person: c.receivable.person,
      principal: c.principal,
      received: received,
    );
  }).toList();
}

/// Purchases not yet marked as paid for anyone — choosing one marks it. Card
/// purchases first.
List<SettleOption> purchaseOptions({
  required List<ClaimPurchase> purchases,
  required List<ClaimSummary> claims,
  required List<CreditCard> cards,
  required String currency,
}) {
  final Set<String> claimed = claims
      .map((ClaimSummary c) => c.receivable.expenseId)
      .whereType<String>()
      .toSet();
  final List<ClaimPurchase> open =
      purchases.where((ClaimPurchase p) => !claimed.contains(p.id)).toList();
  // A stable sort: card purchases first, otherwise newest first as read.
  final List<ClaimPurchase> sorted = <ClaimPurchase>[
    ...open.where((ClaimPurchase p) => p.creditCardId != null),
    ...open.where((ClaimPurchase p) => p.creditCardId == null),
  ];
  return sorted.map((ClaimPurchase p) {
    CreditCard? card;
    for (final CreditCard c in cards) {
      if (c.id == p.creditCardId) card = c;
    }
    return SettleOption(
      target: SettlementTarget.expense(p.id),
      label: '${Formatters.dayMonth(p.date)} · ${p.title} · '
          '${Formatters.currency(p.amount, currencyCode: currency)}'
          '${card != null ? ' · ${card.displayLabel}' : ''}',
      principal: p.amount,
      received: 0,
    );
  }).toList();
}

/// A purchase a reimbursement can pay back, when it is not yet marked as
/// paid for anyone.
class ClaimPurchase {
  const ClaimPurchase({
    required this.id,
    required this.amount,
    required this.date,
    required this.title,
    this.creditCardId,
  });

  final String id;
  final double amount;
  final DateTime date;

  /// Merchant, else description, else category — the web's `expenseTitle`.
  final String title;
  final String? creditCardId;
}

/// Options for [person] first, so the right loan or purchase is near the top.
List<SettleOption> byPersonFirst(List<SettleOption> options, String person) {
  final String key = personKey(person);
  if (key.isEmpty) return List<SettleOption>.of(options);
  return <SettleOption>[
    ...options.where((SettleOption o) => personKey(o.person) == key),
    ...options.where((SettleOption o) => personKey(o.person) != key),
  ];
}

/// What is left on [option] after [amount] more comes back: 0 settles it,
/// below zero is overpaid.
double leftAfter(SettleOption option, double amount) =>
    (_cents(option.principal) - _cents(option.received) - _cents(amount)) / 100;
