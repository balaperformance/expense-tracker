/// Row of `public.bank_accounts`.
///
/// [openingBalance] is the only stored money figure. The live balance is
/// always derived from the ledger, never written back here, so the ledger
/// stays the single source of truth for movement.
class BankAccount {
  const BankAccount({
    required this.id,
    required this.userId,
    required this.bankName,
    required this.nickname,
    this.last4,
    this.openingBalance = 0,
    this.isActive = true,
    this.createdAt,
  });

  final String id;
  final String userId;
  final String bankName;
  final String nickname;
  final String? last4;
  final double openingBalance;
  final bool isActive;
  final DateTime? createdAt;

  /// "HDFC •••• 4821" — what the picker and statement header show.
  String get displayLabel {
    final String? digits = last4?.trim();
    if (digits == null || digits.isEmpty) return nickname;
    return '$nickname •••• $digits';
  }

  String get initial =>
      bankName.trim().isEmpty ? '?' : bankName.trim()[0].toUpperCase();

  factory BankAccount.fromMap(Map<String, dynamic> map) {
    return BankAccount(
      id: map['id'] as String,
      userId: map['user_id'] as String,
      bankName: (map['bank_name'] as String?) ?? 'Bank',
      nickname: (map['nickname'] as String?) ?? 'Account',
      last4: map['last4'] as String?,
      openingBalance: (map['opening_balance'] as num?)?.toDouble() ?? 0,
      isActive: (map['is_active'] as bool?) ?? true,
      createdAt: map['created_at'] == null
          ? null
          : DateTime.parse(map['created_at'] as String),
    );
  }

  Map<String, dynamic> toInsertMap() => <String, dynamic>{
        'user_id': userId,
        'bank_name': bankName.trim(),
        'nickname': nickname.trim(),
        'last4': _blankToNull(last4),
        'opening_balance': openingBalance,
        'is_active': isActive,
      };

  Map<String, dynamic> toUpdateMap() => <String, dynamic>{
        'bank_name': bankName.trim(),
        'nickname': nickname.trim(),
        'last4': _blankToNull(last4),
        'opening_balance': openingBalance,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };

  static String? _blankToNull(String? value) {
    final String? trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  BankAccount copyWith({
    String? bankName,
    String? nickname,
    String? last4,
    double? openingBalance,
  }) {
    return BankAccount(
      id: id,
      userId: userId,
      bankName: bankName ?? this.bankName,
      nickname: nickname ?? this.nickname,
      last4: last4 ?? this.last4,
      openingBalance: openingBalance ?? this.openingBalance,
      isActive: isActive,
      createdAt: createdAt,
    );
  }
}

/// An account plus its derived balance.
class BankAccountBalance {
  const BankAccountBalance({
    required this.account,
    required this.totalCredits,
    required this.totalDebits,
  });

  final BankAccount account;
  final double totalCredits;
  final double totalDebits;

  /// Opening balance plus every movement ever recorded.
  double get currentBalance =>
      account.openingBalance + totalCredits - totalDebits;

  bool get isOverdrawn => currentBalance < 0;
}
