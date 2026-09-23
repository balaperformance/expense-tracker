import '../core/constants/default_data.dart';

/// Row of `public.categories`.
///
/// Named `ExpenseCategory` rather than `Category` to avoid colliding with
/// `dart:html`/Flutter symbols and to keep call sites unambiguous.
class ExpenseCategory {
  const ExpenseCategory({
    required this.id,
    required this.userId,
    required this.name,
    this.icon = DefaultData.fallbackIcon,
    this.color = DefaultData.fallbackColor,
    this.isDefault = false,
    this.createdAt,
  });

  final String id;
  final String userId;
  final String name;
  final String icon;
  final String color;
  final bool isDefault;
  final DateTime? createdAt;

  factory ExpenseCategory.fromMap(Map<String, dynamic> map) {
    return ExpenseCategory(
      id: map['id'] as String,
      userId: map['user_id'] as String,
      name: (map['name'] as String?) ?? 'Untitled',
      icon: (map['icon'] as String?) ?? DefaultData.fallbackIcon,
      color: (map['color'] as String?) ?? DefaultData.fallbackColor,
      isDefault: (map['is_default'] as bool?) ?? false,
      createdAt: map['created_at'] == null
          ? null
          : DateTime.parse(map['created_at'] as String),
    );
  }

  /// Insert/update payload. `user_id` is included so the RLS
  /// `auth.uid() = user_id` check passes.
  Map<String, dynamic> toInsertMap() => <String, dynamic>{
        'user_id': userId,
        'name': name.trim(),
        'icon': icon,
        'color': color,
        'is_default': isDefault,
      };

  Map<String, dynamic> toUpdateMap() => <String, dynamic>{
        'name': name.trim(),
        'icon': icon,
        'color': color,
      };

  ExpenseCategory copyWith({String? name, String? icon, String? color}) {
    return ExpenseCategory(
      id: id,
      userId: userId,
      name: name ?? this.name,
      icon: icon ?? this.icon,
      color: color ?? this.color,
      isDefault: isDefault,
      createdAt: createdAt,
    );
  }
}
