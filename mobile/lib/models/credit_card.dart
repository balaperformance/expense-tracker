import '../core/utils/date_utils.dart';
import 'ledger_entry.dart';

/// Card networks the form offers. Stored as the lowercase wire value.
enum CardNetwork { visa, mastercard, rupay, amex, diners, discover, jcb, other }

extension CardNetworkLabel on CardNetwork {
  String get wire => name;

  String get label => switch (this) {
        CardNetwork.visa => 'Visa',
        CardNetwork.mastercard => 'Mastercard',
        CardNetwork.rupay => 'RuPay',
        CardNetwork.amex => 'American Express',
        CardNetwork.diners => 'Diners Club',
        CardNetwork.discover => 'Discover',
        CardNetwork.jcb => 'JCB',
        CardNetwork.other => 'Other',
      };

  static CardNetwork? parse(String? value) {
    for (final CardNetwork network in CardNetwork.values) {
      if (network.wire == value) return network;
    }
    return null;
  }
}

/// Row of `public.credit_cards` (migration 004, shared with the web app).
///
/// [creditLimit] and [openingOutstanding] are the only stored money figures.
/// The live outstanding is always derived from the card's movements — see
/// `card_statement.dart` — exactly like a bank balance.
class CreditCard {
  const CreditCard({
    required this.id,
    required this.userId,
    required this.cardName,
    required this.issuer,
    this.network,
    this.last4,
    required this.creditLimit,
    this.openingOutstanding = 0,
    required this.statementDay,
    required this.paymentDueDay,
    this.paymentAccountId,
    this.isActive = true,
    this.notes,
    this.createdAt,
  });

  final String id;
  final String userId;
  final String cardName;
  final String issuer;
  final CardNetwork? network;
  final String? last4;
  final double creditLimit;

  /// What was owed when tracking began (negative for a credit balance).
  final double openingOutstanding;

  /// Day of the month the billing cycle closes (29–31 clamp to month end).
  final int statementDay;

  /// Day of the month the bill is due: the first such day after the statement.
  final int paymentDueDay;

  /// The account the bill is usually paid from. A purchase never debits it.
  final String? paymentAccountId;

  /// An inactive card keeps its history and can still be paid off; it is
  /// only hidden from new purchases.
  final bool isActive;
  final String? notes;
  final DateTime? createdAt;

  /// "Regalia •••• 4821".
  String get displayLabel {
    final String? digits = last4?.trim();
    if (digits == null || digits.isEmpty) return cardName;
    return '$cardName •••• $digits';
  }

  /// "HDFC Bank · Visa •••• 4821".
  String get issuerLine {
    final String? digits = last4?.trim();
    final String tail = <String>[
      if (network != null) network!.label,
      if (digits != null && digits.isNotEmpty) '•••• $digits',
    ].join(' ');
    return tail.isEmpty ? issuer : '$issuer · $tail';
  }

  static int _day(Object? value, int fallback) {
    final int? day = (value as num?)?.toInt();
    return day != null && day >= 1 && day <= 31 ? day : fallback;
  }

  factory CreditCard.fromMap(Map<String, dynamic> map) {
    return CreditCard(
      id: map['id'] as String,
      userId: map['user_id'] as String,
      cardName: (map['card_name'] as String?) ?? 'Card',
      issuer: (map['issuer'] as String?) ?? 'Card issuer',
      network: CardNetworkLabel.parse(map['network'] as String?),
      last4: map['last4'] as String?,
      creditLimit: _num(map['credit_limit']),
      openingOutstanding: _num(map['opening_outstanding']),
      statementDay: _day(map['statement_day'], 1),
      paymentDueDay: _day(map['payment_due_day'], 1),
      paymentAccountId: map['payment_account_id'] as String?,
      isActive: (map['is_active'] as bool?) ?? true,
      notes: map['notes'] as String?,
      createdAt: map['created_at'] == null
          ? null
          : DateTime.parse(map['created_at'] as String),
    );
  }

  /// The columns a save writes. Last four digits are kept only when complete.
  Map<String, dynamic> toWriteMap() {
    final String digits = (last4 ?? '').replaceAll(RegExp(r'\D'), '');
    final String? note = notes?.trim();
    return <String, dynamic>{
      'card_name': cardName.trim(),
      'issuer': issuer.trim(),
      'network': network?.wire,
      'last4': digits.length == 4 ? digits : null,
      'credit_limit': creditLimit,
      'opening_outstanding': openingOutstanding,
      'statement_day': statementDay,
      'payment_due_day': paymentDueDay,
      'payment_account_id': paymentAccountId,
      'notes': (note == null || note.isEmpty) ? null : note,
      'is_active': isActive,
    };
  }

  CreditCard copyWith({bool? isActive}) => CreditCard(
        id: id,
        userId: userId,
        cardName: cardName,
        issuer: issuer,
        network: network,
        last4: last4,
        creditLimit: creditLimit,
        openingOutstanding: openingOutstanding,
        statementDay: statementDay,
        paymentDueDay: paymentDueDay,
        paymentAccountId: paymentAccountId,
        isActive: isActive ?? this.isActive,
        notes: notes,
        createdAt: createdAt,
      );
}

/// Card movements that are neither a purchase (an expense) nor a bill
/// payment from a tracked account (a bank ledger row).
enum CardTransactionKind { refund, cashback, payment, fee, interest, adjustment }

extension CardTransactionKindWire on CardTransactionKind {
  String get wire => name;

  static CardTransactionKind parse(String? value) {
    for (final CardTransactionKind kind in CardTransactionKind.values) {
      if (kind.wire == value) return kind;
    }
    return CardTransactionKind.adjustment;
  }
}

/// Row of `public.credit_card_transactions`.
class CardTransaction {
  const CardTransaction({
    required this.id,
    required this.userId,
    required this.cardId,
    required this.kind,
    required this.direction,
    required this.amount,
    required this.txnDate,
    this.description,
    this.reference,
    this.originalExpenseId,
    this.createdAt,
  });

  final String id;
  final String userId;
  final String cardId;
  final CardTransactionKind kind;

  /// Debit raises the outstanding, credit lowers it.
  final LedgerDirection direction;
  final double amount;
  final DateTime txnDate;
  final String? description;
  final String? reference;

  /// The purchase a refund reverses, when known.
  final String? originalExpenseId;
  final DateTime? createdAt;

  factory CardTransaction.fromMap(Map<String, dynamic> map) {
    return CardTransaction(
      id: map['id'] as String,
      userId: (map['user_id'] as String?) ?? '',
      cardId: map['card_id'] as String,
      kind: CardTransactionKindWire.parse(map['kind'] as String?),
      direction: map['direction'] == 'debit'
          ? LedgerDirection.debit
          : LedgerDirection.credit,
      amount: _num(map['amount']),
      txnDate: AppDateUtils.parseDate(map['txn_date'] as String),
      description: map['description'] as String?,
      reference: map['reference'] as String?,
      originalExpenseId: map['original_expense_id'] as String?,
      createdAt: map['created_at'] == null
          ? null
          : DateTime.parse(map['created_at'] as String),
    );
  }
}

double _num(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
}
