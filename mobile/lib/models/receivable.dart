import '../core/utils/date_utils.dart';

/// Money owed to the user (migration 005, shared with the web app): money
/// lent, and purchases paid on someone else's behalf.
///
/// Nothing about what is owed is stored. A claim names its source — the lent
/// debit or the purchase — and repayments are ledger credits that name the
/// claim, so
///
///   outstanding = source amount − every repayment received
///
/// is recalculated from the rows themselves after any edit or deletion. A
/// port of the web app's `domain/receivables.ts`; every figure is in whole
/// cents so thousands of repayments cannot drift.
enum ReceivableKind { loan, reimbursable }

/// Row of `public.receivables`.
class Receivable {
  const Receivable({
    required this.id,
    required this.userId,
    required this.kind,
    required this.person,
    this.ledgerEntryId,
    this.expenseId,
    this.dueDate,
    this.note,
    this.createdAt,
  });

  final String id;
  final String userId;
  final ReceivableKind kind;
  final String person;

  /// Money lent: the debit that paid it.
  final String? ledgerEntryId;

  /// Paid on someone's behalf: the purchase.
  final String? expenseId;

  final DateTime? dueDate;
  final String? note;

  /// As stored (an ISO timestamp); only ever compared, never shown.
  final String? createdAt;

  factory Receivable.fromMap(Map<String, dynamic> map) {
    final String? due = map['due_date'] as String?;
    final String person = ((map['person'] as String?) ?? '').trim();
    return Receivable(
      id: map['id'] as String,
      userId: map['user_id'] as String,
      kind: map['kind'] == 'reimbursable'
          ? ReceivableKind.reimbursable
          : ReceivableKind.loan,
      person: person.isEmpty ? 'Someone' : person,
      ledgerEntryId: map['ledger_entry_id'] as String?,
      expenseId: map['expense_id'] as String?,
      dueDate: due == null || due.isEmpty ? null : AppDateUtils.parseDate(due),
      note: map['note'] as String?,
      createdAt: map['created_at'] as String?,
    );
  }

  /// "Loan to Arun" / "Paid for Arun".
  String get title =>
      kind == ReceivableKind.loan ? 'Loan to $person' : 'Paid for $person';
}

/// The money that went out for a claim, read from its own row.
class ClaimSource {
  const ClaimSource({
    required this.date,
    required this.amount,
    required this.title,
    this.accountId,
    this.cardId,
    this.ledgerEntryId,
    this.expenseId,
  });

  final DateTime date;
  final double amount;
  final String title;

  /// The bank account it left, for a lent debit or a bank-funded purchase.
  final String? accountId;

  /// The card it was charged to, for a card purchase.
  final String? cardId;

  /// The bank movement behind it, when there is one.
  final String? ledgerEntryId;
  final String? expenseId;
}

/// A ledger credit received against a claim.
class ClaimRepayment {
  const ClaimRepayment({
    required this.entryId,
    required this.receivableId,
    required this.accountId,
    required this.amount,
    required this.date,
    this.description,
  });

  final String entryId;
  final String receivableId;
  final String accountId;
  final double amount;
  final DateTime date;
  final String? description;
}

enum ClaimStatus {
  open('Not repaid yet'),
  partial('Partly repaid'),
  settled('Settled'),
  overpaid('Overpaid');

  const ClaimStatus(this.label);

  final String label;

  /// Still owed, in full or in part.
  bool get isOpen => this == ClaimStatus.open || this == ClaimStatus.partial;
}

/// One claim: what went out, what came back and what is left.
class ClaimSummary {
  const ClaimSummary({
    required this.receivable,
    required this.source,
    required this.principal,
    required this.received,
    required this.outstanding,
    required this.status,
    required this.repayments,
    required this.overdue,
  });

  final Receivable receivable;

  /// Null only if the source row could not be read; the claim then counts
  /// nothing.
  final ClaimSource? source;
  final double principal;
  final double received;

  /// Below zero when more came back than went out.
  final double outstanding;
  final ClaimStatus status;

  /// Oldest first.
  final List<ClaimRepayment> repayments;
  final bool overdue;
}

int _cents(double value) => (value * 100).round();

ClaimStatus claimStatus(double principal, double received) {
  final int left = _cents(principal) - _cents(received);
  if (left > 0) return _cents(received) > 0 ? ClaimStatus.partial : ClaimStatus.open;
  return left == 0 ? ClaimStatus.settled : ClaimStatus.overpaid;
}

/// One summary per claim. Open claims first, then newest.
List<ClaimSummary> summariseClaims({
  required List<Receivable> receivables,
  required Map<String, ClaimSource> sources,
  required List<ClaimRepayment> repayments,
  required DateTime today,
}) {
  final Map<String, List<ClaimRepayment>> byClaim =
      <String, List<ClaimRepayment>>{};
  for (final ClaimRepayment repayment in repayments) {
    (byClaim[repayment.receivableId] ??= <ClaimRepayment>[]).add(repayment);
  }
  final List<ClaimSummary> summaries = receivables.map((Receivable r) {
    final ClaimSource? source = sources[r.id];
    final List<ClaimRepayment> received =
        List<ClaimRepayment>.of(byClaim[r.id] ?? const <ClaimRepayment>[])
          ..sort((ClaimRepayment a, ClaimRepayment b) => a.date.compareTo(b.date));
    final double principal = source?.amount ?? 0;
    final double receivedTotal = received.fold<int>(
            0, (int sum, ClaimRepayment p) => sum + _cents(p.amount)) /
        100;
    final ClaimStatus status = claimStatus(principal, receivedTotal);
    final DateTime? due = r.dueDate;
    return ClaimSummary(
      receivable: r,
      source: source,
      principal: principal,
      received: receivedTotal,
      outstanding: (_cents(principal) - _cents(receivedTotal)) / 100,
      status: status,
      repayments: received,
      overdue: status.isOpen && due != null && due.isBefore(today),
    );
  }).toList();
  summaries.sort((ClaimSummary a, ClaimSummary b) {
    final int open = (b.status.isOpen ? 1 : 0) - (a.status.isOpen ? 1 : 0);
    if (open != 0) return open;
    final DateTime? aDate = a.source?.date;
    final DateTime? bDate = b.source?.date;
    if (aDate == null || bDate == null) {
      return aDate == null ? (bDate == null ? 0 : 1) : -1;
    }
    return bDate.compareTo(aDate);
  });
  return summaries;
}

/// The same person however it was typed: "arun " and "Arun" are one.
String personKey(String? name) =>
    (name ?? '').trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

/// Everyone the user has a claim with, spelled as they last wrote it, most
/// recent first.
List<String> knownPeople(List<ClaimSummary> claims) {
  final Map<String, ({String name, String date})> seen =
      <String, ({String name, String date})>{};
  for (final ClaimSummary claim in claims) {
    final String key = personKey(claim.receivable.person);
    final DateTime? sourceDate = claim.source?.date;
    final String date = sourceDate != null
        ? AppDateUtils.toDateString(sourceDate)
        : (claim.receivable.createdAt ?? '');
    final ({String name, String date})? known = seen[key];
    if (known == null || date.compareTo(known.date) > 0) {
      seen[key] = (name: claim.receivable.person, date: date);
    }
  }
  final List<({String name, String date})> people = seen.values.toList()
    ..sort((({String name, String date}) a, ({String name, String date}) b) =>
        b.date.compareTo(a.date));
  return people.map((({String name, String date}) p) => p.name).toList();
}

/// Claims grouped by person.
class PersonBalance {
  PersonBalance({required this.person});

  String person;
  double outstanding = 0;

  /// How many of the claims are still open.
  int open = 0;
  final List<ClaimSummary> claims = <ClaimSummary>[];
}

final RegExp _capital = RegExp(r'^\p{Lu}', unicode: true);

/// "arun" and "Arun" are one person; the capitalised spelling is the one shown.
String _preferredSpelling(String current, String other) =>
    !_capital.hasMatch(current.trim()) && _capital.hasMatch(other.trim())
        ? other.trim()
        : current.trim();

/// Claims grouped by person, those owing the most first.
List<PersonBalance> balancesByPerson(List<ClaimSummary> claims) {
  final Map<String, PersonBalance> groups = <String, PersonBalance>{};
  for (final ClaimSummary claim in claims) {
    final String key = personKey(claim.receivable.person);
    final PersonBalance group = groups[key] ??=
        PersonBalance(person: claim.receivable.person.trim());
    group.person = _preferredSpelling(group.person, claim.receivable.person);
    group.claims.add(claim);
    if (claim.status.isOpen) {
      group.outstanding =
          (_cents(group.outstanding) + _cents(claim.outstanding)) / 100;
      group.open += 1;
    }
  }
  return groups.values.toList()
    ..sort((PersonBalance a, PersonBalance b) {
      final int byOwed = b.outstanding.compareTo(a.outstanding);
      return byOwed != 0 ? byOwed : a.person.compareTo(b.person);
    });
}

/// Total still owed across open claims.
double totalOutstanding(List<ClaimSummary> claims) =>
    claims
        .where((ClaimSummary c) => c.status.isOpen)
        .fold<int>(0, (int sum, ClaimSummary c) => sum + _cents(c.outstanding)) /
    100;

/// "Due in 3 days", "Due today", "Overdue by 1 day"; null when there is no
/// due date or nothing is owed.
String? dueText(ClaimSummary claim, DateTime today) {
  final DateTime? due = claim.receivable.dueDate;
  if (due == null || !claim.status.isOpen) return null;
  // Whole calendar days, counted in UTC so a daylight-saving change cannot
  // make one day 23 hours long.
  final int days = DateTime.utc(due.year, due.month, due.day)
      .difference(DateTime.utc(today.year, today.month, today.day))
      .inDays;
  if (days < 0) return 'Overdue by ${-days} ${days == -1 ? 'day' : 'days'}';
  if (days == 0) return 'Due today';
  return 'Due in $days ${days == 1 ? 'day' : 'days'}';
}

/// Who a purchase was paid for, as the expense form saves it.
class PaidForDraft {
  const PaidForDraft({required this.person, this.dueDate, this.note});

  final String person;
  final DateTime? dueDate;
  final String? note;
}

/// What saving an expense does to its claim: mark it as paid for someone
/// ([draft] set), unmark it ([clears]), or leave it as it is ([keeps]).
class PaidForChange {
  const PaidForChange.keep()
      : keeps = true,
        draft = null;
  const PaidForChange.clear()
      : keeps = false,
        draft = null;
  const PaidForChange.mark(PaidForDraft this.draft) : keeps = false;

  final bool keeps;
  final PaidForDraft? draft;

  bool get clears => !keeps && draft == null;
}

/// The change the expense form asks for — as the web form decides it: marked,
/// unmarked, or (when it never was and still is not) left alone.
///
/// [known]: the purchase's claim was read (or the expense is new), so the
/// toggle shows the truth. When it is not known nothing is changed, so a
/// failed read can never unmark a purchase. [claim]'s due date and note are
/// kept, since the form does not edit them.
PaidForChange paidForChange({
  required bool known,
  required bool paidFor,
  required String person,
  Receivable? claim,
}) {
  if (!known) return const PaidForChange.keep();
  if (paidFor) {
    return PaidForChange.mark(PaidForDraft(
      person: person.trim(),
      dueDate: claim?.dueDate,
      note: claim?.note,
    ));
  }
  return claim != null
      ? const PaidForChange.clear()
      : const PaidForChange.keep();
}
