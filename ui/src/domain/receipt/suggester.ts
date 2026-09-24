/**
 * Keyword suggestions for a receipt or a payee. Port of
 * `services/receipt/receipt_suggester.dart`. A suggestion only ever picks one
 * of the user's own categories / payment methods, matched by name.
 */
import type { ExpenseCategory, PaymentMethod } from '../models';

import type { ReceiptResult } from './result';

export type Suggestion<T> = { value: T; reason: string };

const CATEGORY_KEYWORDS: ReadonlyArray<readonly [string, readonly string[]]> = [
  [
    'Food',
    [
      'restaurant', 'cafe', 'coffee', 'pizza', 'burger', 'kitchen', 'bakery',
      'bakers', 'dhaba', 'biryani', 'foods', 'eatery', 'diner', 'bistro',
      'juice', 'tea ', 'chai', 'swiggy', 'zomato', 'grocery', 'supermarket',
      'hypermarket', 'mart', 'provision', 'bar & grill', 'canteen',
    ],
  ],
  [
    'Transport',
    [
      'fuel', 'petrol', 'diesel', 'petroleum', 'filling station', 'gas ',
      'uber', 'ola ', 'rapido', 'cab', 'taxi', 'metro', 'parking', 'toll',
      'transport', 'travels', 'bus ',
    ],
  ],
  [
    'Shopping',
    [
      'store', 'retail', 'fashion', 'apparel', 'clothing', 'lifestyle',
      'trends', 'boutique', 'footwear', 'electronics', 'amazon', 'flipkart',
      'myntra', 'department', 'shoppe', 'shopping',
    ],
  ],
  [
    'Bills',
    [
      'electricity', 'power', 'water board', 'broadband', 'telecom',
      'recharge', 'postpaid', 'prepaid', 'airtel', 'jio', 'vodafone',
      'internet', 'utility', 'gas bill', 'insurance', 'premium',
    ],
  ],
  [
    'Entertainment',
    [
      'cinema', 'cinemas', 'multiplex', 'pvr', 'inox', 'theatre', 'theater',
      'movie', 'netflix', 'spotify', 'prime video', 'gaming', 'bowling',
      'amusement',
    ],
  ],
  [
    'Health',
    [
      'pharmacy', 'pharma', 'medical', 'medicos', 'chemist', 'hospital',
      'clinic', 'diagnostic', 'laboratory', 'labs', 'dental', 'apollo',
      'wellness', 'optical',
    ],
  ],
  [
    'Travel',
    [
      'airlines', 'airways', 'indigo', 'hotel', 'resort', 'lodge', 'inn ',
      'makemytrip', 'goibibo', 'irctc', 'railway', 'booking', 'tourism',
    ],
  ],
  [
    'Education',
    [
      'school', 'college', 'university', 'institute', 'academy', 'tuition',
      'books', 'stationery', 'stationers', 'coaching', 'course',
    ],
  ],
];

const PAYMENT_KEYWORDS: ReadonlyArray<readonly [string, readonly string[]]> = [
  ['UPI', ['upi', 'gpay', 'google pay', 'phonepe', 'paytm', 'bhim']],
  ['Credit Card', ['credit card', 'creditcard', 'visa credit']],
  ['Debit Card', ['debit card', 'debitcard', 'visa debit', 'rupay']],
  ['Net Banking', ['net banking', 'netbanking', 'imps', 'neft']],
  ['Wallet', ['wallet', 'paytm wallet']],
  ['Cash', ['cash tendered', 'cash paid', 'by cash', 'cash:']],
];

const firstHit = (haystack: string, keywords: readonly string[]) => keywords.find((k) => haystack.includes(k));

const byName = <T extends { name: string }>(all: readonly T[], name: string) =>
  all.find((item) => item.name.toLowerCase() === name.toLowerCase());

export function suggestCategoryForText(
  text: string,
  available: readonly ExpenseCategory[],
): Suggestion<ExpenseCategory> | null {
  if (!available.length) return null;
  const haystack = text.toLowerCase();
  if (!haystack.trim()) return null;
  for (const [name, keywords] of CATEGORY_KEYWORDS) {
    const hit = firstHit(haystack, keywords);
    if (hit == null) continue;
    const category = byName(available, name);
    if (!category) continue;
    return { value: category, reason: `matched '${hit.trim()}'` };
  }
  return null;
}

function receiptHaystack(result: ReceiptResult): string {
  const parts: string[] = [];
  if (result.merchant.value != null) parts.push(result.merchant.value);
  for (const item of result.lineItems) parts.push(item.description);
  return `${parts.join(' ')} `.toLowerCase();
}

export function suggestCategory(
  result: ReceiptResult,
  available: readonly ExpenseCategory[],
): Suggestion<ExpenseCategory> | null {
  return suggestCategoryForText(receiptHaystack(result), available);
}

export function suggestPaymentMethod(
  result: ReceiptResult,
  available: readonly PaymentMethod[],
): Suggestion<PaymentMethod> | null {
  if (!available.length) return null;
  const haystack = result.rawLines.join(' ').toLowerCase();
  if (!haystack) return null;
  for (const [name, keywords] of PAYMENT_KEYWORDS) {
    const hit = firstHit(haystack, keywords);
    if (hit == null) continue;
    const method = byName(available, name);
    if (!method) continue;
    return { value: method, reason: `matched '${hit.trim()}'` };
  }
  return null;
}

/** "Latte, 2 x Croissant +3 more" from the first line items. */
export function describeReceipt(result: ReceiptResult): string | null {
  if (!result.lineItems.length) return null;
  const names = result.lineItems.slice(0, 3).map((item) =>
    item.quantity == null || item.quantity === 1 ? item.description : `${item.quantity} x ${item.description}`,
  );
  const joined = names.join(', ');
  return result.lineItems.length > names.length ? `${joined} +${result.lineItems.length - names.length} more` : joined;
}
