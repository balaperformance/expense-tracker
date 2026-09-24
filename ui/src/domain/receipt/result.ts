/**
 * What a receipt scan read, with a confidence per field.
 * Port of `services/receipt/receipt_result.dart`.
 */
export type ReceiptConfidence = 'high' | 'medium' | 'low' | 'none';

export const CONFIDENCE_LABEL: Record<ReceiptConfidence, string> = {
  high: 'Clear',
  medium: 'Likely',
  low: 'Unsure',
  none: 'Not found',
};

export type ReceiptField<T> = { value: T | null; confidence: ReceiptConfidence };

export const missingField = <T>(): ReceiptField<T> => ({ value: null, confidence: 'none' });

const needsReview = (c: ReceiptConfidence) => c === 'low' || c === 'medium';
const shouldVerify = <T>(field: ReceiptField<T>) => field.value != null && needsReview(field.confidence);

export type ReceiptLineItem = { description: string; amount: number; quantity: number | null };

export type ReceiptResult = {
  merchant: ReceiptField<string>;
  total: ReceiptField<number>;
  date: ReceiptField<string>;
  lineItems: ReceiptLineItem[];
  rawLines: string[];
};

export const UNREADABLE_RECEIPT: ReceiptResult = {
  merchant: missingField(),
  total: missingField(),
  date: missingField(),
  lineItems: [],
  rawLines: [],
};

export const hasUsableTotal = (r: ReceiptResult) => r.total.value != null && r.total.value > 0;

export function fieldsToVerify(r: ReceiptResult): string[] {
  return [
    ...(shouldVerify(r.total) || r.total.value == null ? ['amount'] : []),
    ...(shouldVerify(r.merchant) ? ['merchant'] : []),
    ...(shouldVerify(r.date) ? ['date'] : []),
  ];
}

export type ReceiptScanProblem = 'cancelled' | 'unreadable' | 'engineFailure';

export const RECEIPT_PROBLEM_MESSAGE: Record<ReceiptScanProblem, string> = {
  cancelled: 'Scan cancelled.',
  unreadable: 'Could not read that image. Try again with the whole receipt in frame, flat, and in good light.',
  engineFailure: 'Receipt scanning is unavailable right now. You can still add the expense by hand.',
};
