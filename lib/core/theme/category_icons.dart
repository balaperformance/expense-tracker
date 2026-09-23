import 'package:flutter/material.dart';

/// Maps the icon name stored in `categories.icon` to a Material icon.
///
/// A const map keeps icon-font tree-shaking working, which building `IconData`
/// from a runtime code point would break.
class CategoryIcons {
  const CategoryIcons._();

  static const Map<String, IconData> _icons = <String, IconData>{
    'restaurant': Icons.restaurant_rounded,
    'directions_bus': Icons.directions_bus_rounded,
    'shopping_bag': Icons.shopping_bag_rounded,
    'receipt_long': Icons.receipt_long_rounded,
    'movie': Icons.movie_rounded,
    'favorite': Icons.favorite_rounded,
    'flight': Icons.flight_rounded,
    'school': Icons.school_rounded,
    'category': Icons.category_rounded,
    'home': Icons.home_rounded,
    'pets': Icons.pets_rounded,
    'fitness_center': Icons.fitness_center_rounded,
    'local_cafe': Icons.local_cafe_rounded,
    'local_grocery_store': Icons.local_grocery_store_rounded,
    'phone_android': Icons.phone_android_rounded,
    'wifi': Icons.wifi_rounded,
    'bolt': Icons.bolt_rounded,
    'water_drop': Icons.water_drop_rounded,
    'card_giftcard': Icons.card_giftcard_rounded,
    'savings': Icons.savings_rounded,
    'work': Icons.work_rounded,
    'directions_car': Icons.directions_car_rounded,
    'local_gas_station': Icons.local_gas_station_rounded,
    'medical_services': Icons.medical_services_rounded,
    'sports_esports': Icons.sports_esports_rounded,
    'music_note': Icons.music_note_rounded,
    'book': Icons.book_rounded,
    'checkroom': Icons.checkroom_rounded,
  };

  /// Icon names offered in the category editor.
  static List<String> get pickable => _icons.keys.toList(growable: false);

  static IconData resolve(String? name) =>
      _icons[name] ?? Icons.category_rounded;
}
