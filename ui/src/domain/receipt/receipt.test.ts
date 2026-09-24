/**
 * Parity tests: ported from `mobile/test/receipt_parser_test.dart`.
 */
import { describe, expect, it } from 'vitest';

import { fromParts } from '@/lib/dates';

import type { ExpenseCategory } from '../models';

import { parseReceiptLines, parseReceiptText } from './parser';
import { fieldsToVerify, hasUsableTotal } from './result';
import { describeReceipt, suggestCategory } from './suggester';

const lines = (block: string) =>
  block
    .trim()
    .split('\n')
    .map((line) => line.trim());

const parse = (block: string) => parseReceiptLines(lines(block));

describe('total', () => {
  it('reads a labelled total', () => {
    const result = parse(`
      GREEN LEAF SUPERMARKET
      Rice 5kg          450.00
      Milk 1L            62.00
      Subtotal          512.00
      CGST 2.5%          12.80
      SGST 2.5%          12.80
      TOTAL             537.60`);
    expect(result.total.value).toBe(537.6);
    expect(result.total.confidence).toBe('high');
  });

  it('prefers grand total over the running total above it', () => {
    expect(parse(`Total 900.00\nDiscount 50.00\nGrand Total 850.00`).total.value).toBe(850);
  });

  it('never mistakes a subtotal for the total', () => {
    expect(parse(`Sub Total 1200.00\nTotal Savings 150.00\nAmount Payable 1050.00`).total.value).toBe(1050);
  });

  it('never mistakes a tax total for the total', () => {
    expect(parse(`Total Tax 90.00\nTotal 1090.00`).total.value).toBe(1090);
  });

  it('takes the amount from the line below a bare label', () => {
    const result = parse(`Coffee 180.00\nAMOUNT DUE\n212.40`);
    expect(result.total.value).toBe(212.4);
    expect(result.total.confidence).toBe('high');
  });

  it('handles Indian and western digit grouping', () => {
    expect(parse(`Laptop\nGrand Total    1,23,456.78`).total.value).toBe(123456.78);
    expect(parse(`TOTAL   $1,234.56`).total.value).toBe(1234.56);
  });

  it('falls back to the largest amount, marked as a guess', () => {
    const result = parse(`CORNER STORE\nBread 45.00\nButter 220.00\nJam 98.50`);
    expect(result.total.value).toBe(220);
    expect(result.total.confidence).toBe('medium');
  });

  it('a phone number is not an amount', () => {
    expect(parse(`SPICE HOUSE\nPh: 9876543210\nTOTAL   340.00`).total.value).toBe(340);
  });

  it('a date is not an amount', () => {
    expect(parse(`SOME SHOP\nDate 12.05.2024\nItem             75.00`).total.value).toBe(75);
  });

  it('an unreadable receipt yields no total', () => {
    const result = parse(`~~~~~\n?????`);
    expect(result.total.value).toBeNull();
    expect(hasUsableTotal(result)).toBe(false);
  });
});

describe('date', () => {
  const dateOf = (line: string) => parseReceiptLines([line]).date;

  it('reads the formats receipts print', () => {
    expect(dateOf('Date: 14/03/2024').value).toBe('2024-03-14');
    expect(dateOf('2024-03-14 19:42').value).toBe('2024-03-14');
    expect(dateOf('03/28/2024').value).toBe('2024-03-28');
    expect(dateOf('05-06-24').value).toBe('2024-06-05');
    expect(dateOf('12 Mar 2024').value).toBe('2024-03-12');
    expect(dateOf('Mar 12, 2024').value).toBe('2024-03-12');
  });

  it('rejects impossible days rather than rolling them over', () => {
    expect(dateOf('32/01/2024').value).toBeNull();
    expect(dateOf('31/04/2024').value).toBeNull();
  });

  it('flags an implausible date instead of dropping it', () => {
    const date = dateOf(`Date 10/10/${new Date().getFullYear() + 1}`);
    expect(date.value).not.toBeNull();
    expect(date.confidence).toBe('low');
  });

  it("today's date reads as confident", () => {
    const now = new Date();
    const date = dateOf(`${now.getDate()}/${now.getMonth() + 1}/${now.getFullYear()}`);
    expect(date.value).toBe(fromParts(now.getFullYear(), now.getMonth() + 1, now.getDate()));
    expect(date.confidence).toBe('high');
  });
});

describe('merchant', () => {
  it('reads a shouting header and title-cases it', () => {
    const result = parse(`SPAR HYPERMARKET\n12 MG Road, Bengaluru 560001\nGSTIN 29ABCDE1234F1Z5\nTOTAL 812.00`);
    expect(result.merchant.value).toBe('Spar Hypermarket');
    expect(result.merchant.confidence).toBe('high');
  });

  it('leaves a mixed-case name exactly as printed', () => {
    expect(parse(`The Daily Grind Cafe\nTotal 310.00`).merchant.value).toBe('The Daily Grind Cafe');
  });

  it('skips invoice and tax metadata', () => {
    expect(parse(`TAX INVOICE\nGSTIN: 29AABCU9603R1ZJ\nBLUE DART LOGISTICS\nTotal 500.00`).merchant.value).toBe(
      'Blue Dart Logistics',
    );
  });

  it('skips a line that is mostly digits', () => {
    expect(parse(`4829 1100 2831\nCITY PHARMACY\nTotal 240.00`).merchant.value).toBe('City Pharmacy');
  });

  it('reports nothing rather than guessing from an amount-only receipt', () => {
    const result = parse(`123.00\n456.00`);
    expect(result.merchant.value).toBeNull();
    expect(result.merchant.confidence).toBe('none');
  });
});

describe('line items', () => {
  it('reads items and their amounts', () => {
    const result = parse(`THE DAILY GRIND\nFlat White             180.00\nAlmond Croissant       150.00\nTotal 330.00`);
    expect(result.lineItems).toHaveLength(2);
    expect(result.lineItems[0]).toMatchObject({ description: 'Flat White', amount: 180 });
    expect(result.lineItems[1]?.description).toBe('Almond Croissant');
  });

  it('reads a quantity prefix', () => {
    const result = parse(`CAFE\n2 x Flat White         360.00\nTotal                  360.00`);
    expect(result.lineItems).toHaveLength(1);
    expect(result.lineItems[0]).toMatchObject({ quantity: 2, description: 'Flat White' });
  });

  it('excludes summary rows from the items', () => {
    const result = parse(
      `SHOP\nNotebook 60.00\nSubtotal 60.00\nCGST 5.40\nTotal 65.40\nCash 100.00\nChange 34.60`,
    );
    expect(result.lineItems.map((i) => i.description)).toEqual(['Notebook']);
  });

  it('strips a dot leader between the name and the price', () => {
    expect(parse(`DINER\nSoup of the day ....... 120.00`).lineItems[0]?.description).toBe('Soup of the day');
  });
});

describe('whole receipts', () => {
  it('an Indian supermarket bill', () => {
    const result = parse(`
      GREEN LEAF SUPERMARKET
      No 42, 5th Cross, Indiranagar
      GSTIN: 29AABCU9603R1ZJ
      Bill No: 2024/0931
      Date: 14/03/2024  Time: 19:42
      ------------------------------
      Basmati Rice 5kg        450.00
      Amul Butter 500g        265.00
      Tata Salt 1kg            28.00
      ------------------------------
      Sub Total               743.00
      CGST 2.5%                18.58
      SGST 2.5%                18.58
      GRAND TOTAL             780.16
      Paid by UPI
      Thank you, visit again`);
    expect(result.total).toEqual({ value: 780.16, confidence: 'high' });
    expect(result.merchant.value).toBe('Green Leaf Supermarket');
    expect(result.date.value).toBe('2024-03-14');
    expect(result.lineItems).toHaveLength(3);
    expect(fieldsToVerify(result)).toEqual([]);
  });

  it('a fuel receipt with no item lines', () => {
    const result = parse(`
      BHARAT PETROLEUM
      Outer Ring Road
      Date 02/09/2026
      Diesel              32.50 L
      Rate                 89.60
      Amount Payable     2912.00`);
    expect(result.total.value).toBe(2912);
    expect(result.merchant.value).toBe('Bharat Petroleum');
    expect(result.date.value).toBe('2026-09-02');
  });

  it('blank lines are ignored and parseText accepts one blob', () => {
    expect(parseReceiptLines(['   ', 'SHOP NAME', '', 'Total 10.00']).rawLines).toHaveLength(2);
    const blob = parseReceiptText('CITY CAFE\nTotal 250.00\n');
    expect(blob.total.value).toBe(250);
    expect(blob.merchant.value).toBe('City Cafe');
  });
});

describe('suggestions', () => {
  const categories: ExpenseCategory[] = ['Food', 'Transport', 'Shopping'].map((name) => ({
    id: name.toLowerCase(),
    userId: 'u1',
    name,
    icon: 'category',
    color: '#78909C',
    isDefault: true,
    createdAt: null,
  }));

  it('suggests one of the user’s categories with its reason', () => {
    const suggestion = suggestCategory(parse(`GREEN LEAF SUPERMARKET\nTotal 10.00`), categories);
    expect(suggestion?.value.name).toBe('Food');
    expect(suggestion?.reason).toContain('supermarket');
  });

  it('describes the first items', () => {
    expect(describeReceipt(parse(`CAFE\nFlat White 180.00\nCroissant 150.00\nTotal 330.00`))).toBe(
      'Flat White, Croissant',
    );
  });
});
