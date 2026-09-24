/**
 * Values to open the Add Expense form with, already filled in.
 * Port of `models/expense_prefill.dart` + `services/receipt/receipt_prefill.dart`.
 *
 * The scanner never writes an expense: it produces one of these, the normal
 * form opens on it, and the user saves through the same path as a typed one.
 */
import type { ExpenseCategory, PaymentMethod } from './models';
import { hasUsableTotal, type ReceiptResult } from './receipt/result';
import { describeReceipt, suggestCategory, suggestPaymentMethod } from './receipt/suggester';

export type ExpensePrefill = {
  amount?: number | null;
  merchant?: string | null;
  date?: string | null;
  description?: string | null;
  notes?: string | null;
  categoryId?: string | null;
  paymentMethodId?: string | null;
  source: 'manual' | 'receiptScan';
};

export function receiptPrefill(
  result: ReceiptResult,
  categories: readonly ExpenseCategory[],
  paymentMethods: readonly PaymentMethod[],
): { prefill: ExpensePrefill; categoryReason: string | null } {
  const category = suggestCategory(result, categories);
  const payment = suggestPaymentMethod(result, paymentMethods);
  return {
    prefill: {
      // Only a positive amount is worth carrying over; a zero read is a misread.
      amount: hasUsableTotal(result) ? result.total.value : null,
      merchant: result.merchant.value,
      date: result.date.value,
      description: describeReceipt(result),
      categoryId: category?.value.id ?? null,
      paymentMethodId: payment?.value.id ?? null,
      source: 'receiptScan',
    },
    categoryReason: category?.reason ?? null,
  };
}
