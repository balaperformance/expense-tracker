/// Seed data created for a user the first time they sign in.
///
/// Seeding is idempotent: the repository compares against existing rows by
/// name (case-insensitive) and only inserts what is genuinely missing, so a
/// database trigger that already seeds defaults will not produce duplicates.
library;

class DefaultCategory {
  const DefaultCategory(this.name, this.icon, this.color);

  final String name;
  final String icon;
  final String color;
}

class DefaultData {
  const DefaultData._();

  static const List<DefaultCategory> categories = <DefaultCategory>[
    DefaultCategory('Food', 'restaurant', '#FF7043'),
    DefaultCategory('Transport', 'directions_bus', '#42A5F5'),
    DefaultCategory('Shopping', 'shopping_bag', '#AB47BC'),
    DefaultCategory('Bills', 'receipt_long', '#26A69A'),
    DefaultCategory('Entertainment', 'movie', '#EC407A'),
    DefaultCategory('Health', 'favorite', '#EF5350'),
    DefaultCategory('Travel', 'flight', '#29B6F6'),
    DefaultCategory('Education', 'school', '#7E57C2'),
    DefaultCategory('Other', 'category', '#78909C'),
  ];

  static const List<String> paymentMethods = <String>[
    'Cash',
    'Credit Card',
    'Debit Card',
    'UPI',
    'Net Banking',
    'Wallet',
  ];

  /// Icon names persisted in `categories.icon`, mapped to Material icons by
  /// [categoryIconFor] in the presentation layer.
  static const String fallbackIcon = 'category';
  static const String fallbackColor = '#78909C';
}
