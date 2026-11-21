/// Row of `public.payment_methods`.
///
/// The table only stores a name, so the icon shown in the UI is derived from
/// that name rather than persisted.
class PaymentMethod {
  const PaymentMethod({
    required this.id,
    required this.userId,
    required this.name,
    this.createdAt,
  });

  final String id;
  final String userId;
  final String name;
  final DateTime? createdAt;

  factory PaymentMethod.fromMap(Map<String, dynamic> map) {
    return PaymentMethod(
      id: map['id'] as String,
      userId: map['user_id'] as String,
      name: (map['name'] as String?) ?? 'Unknown',
      createdAt: map['created_at'] == null
          ? null
          : DateTime.parse(map['created_at'] as String),
    );
  }

  Map<String, dynamic> toInsertMap() => <String, dynamic>{
        'user_id': userId,
        'name': name.trim(),
      };
}

/// The user's "Credit Card" payment method — the one a purchase paid with a
/// card is filed under — or null when they have none by that name. Names are
/// compared ignoring case and extra spaces. The web app's `creditCardMethod`.
PaymentMethod? creditCardMethod(Iterable<PaymentMethod> methods) {
  for (final PaymentMethod method in methods) {
    if (method.name.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase() ==
        'credit card') {
      return method;
    }
  }
  return null;
}
