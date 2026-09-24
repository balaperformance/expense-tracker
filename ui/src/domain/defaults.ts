/**
 * Seed data created for a user the first time they sign in, and the icon
 * names stored in `categories.icon`. Port of `core/constants/default_data.dart`
 * and `core/theme/category_icons.dart` (the names, not the glyphs).
 */

export const FALLBACK_CATEGORY_ICON = 'category';

export type DefaultCategory = { name: string; icon: string; color: string };

export const DEFAULT_CATEGORIES: readonly DefaultCategory[] = [
  { name: 'Food', icon: 'restaurant', color: '#FF7043' },
  { name: 'Transport', icon: 'directions_bus', color: '#42A5F5' },
  { name: 'Shopping', icon: 'shopping_bag', color: '#AB47BC' },
  { name: 'Bills', icon: 'receipt_long', color: '#26A69A' },
  { name: 'Entertainment', icon: 'movie', color: '#EC407A' },
  { name: 'Health', icon: 'favorite', color: '#EF5350' },
  { name: 'Travel', icon: 'flight', color: '#29B6F6' },
  { name: 'Education', icon: 'school', color: '#7E57C2' },
  { name: 'Other', icon: 'category', color: '#78909C' },
];

export const DEFAULT_PAYMENT_METHODS: readonly string[] = [
  'Cash',
  'Credit Card',
  'Debit Card',
  'UPI',
  'Net Banking',
  'Wallet',
];

/** Icon names offered in the category editor, in the Flutter order. */
export const CATEGORY_ICON_NAMES = [
  'restaurant',
  'directions_bus',
  'shopping_bag',
  'receipt_long',
  'movie',
  'favorite',
  'flight',
  'school',
  'category',
  'home',
  'pets',
  'fitness_center',
  'local_cafe',
  'local_grocery_store',
  'phone_android',
  'wifi',
  'bolt',
  'water_drop',
  'card_giftcard',
  'savings',
  'work',
  'directions_car',
  'local_gas_station',
  'medical_services',
  'sports_esports',
  'music_note',
  'book',
  'checkroom',
] as const;

export const APP_NAME = 'Expense Tracker';
export const APP_VERSION = '1.0.0';

/** Page size for paginated transaction lists. */
export const PAGE_SIZE = 20;
/** Upper bound when aggregating a single month in memory. */
export const MONTHLY_AGGREGATE_LIMIT = 2000;
/** Upper bound on the rows one export may pull. */
export const EXPORT_ROW_LIMIT = 5000;
