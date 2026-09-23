import '../core/constants/app_constants.dart';

/// Row of `public.profiles`.
///
/// `id` is the auth user id (there is no separate `user_id` column).
/// Theme preference is intentionally not here: the table has no column for it,
/// so it is stored per-device via `PreferencesService`.
class Profile {
  const Profile({
    required this.id,
    this.fullName,
    this.currency = AppConstants.defaultCurrencyCode,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String? fullName;
  final String currency;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  String get displayName {
    final String? name = fullName?.trim();
    return (name == null || name.isEmpty) ? 'there' : name;
  }

  /// First letter for the avatar badge.
  String get initial {
    final String? name = fullName?.trim();
    if (name == null || name.isEmpty) return '?';
    return name.substring(0, 1).toUpperCase();
  }

  factory Profile.fromMap(Map<String, dynamic> map) {
    return Profile(
      id: map['id'] as String,
      fullName: map['full_name'] as String?,
      currency:
          (map['currency'] as String?) ?? AppConstants.defaultCurrencyCode,
      createdAt: map['created_at'] == null
          ? null
          : DateTime.parse(map['created_at'] as String),
      updatedAt: map['updated_at'] == null
          ? null
          : DateTime.parse(map['updated_at'] as String),
    );
  }

  /// Only the writable columns; `created_at` is database-managed.
  Map<String, dynamic> toMap() => <String, dynamic>{
        'id': id,
        'full_name': fullName,
        'currency': currency,
      };

  Profile copyWith({String? fullName, String? currency}) => Profile(
        id: id,
        fullName: fullName ?? this.fullName,
        currency: currency ?? this.currency,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );
}
