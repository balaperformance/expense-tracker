/**
 * The bank-agnostic fallback parser. It makes no assumption about any one
 * bank: it finds the table header by the column names statements commonly
 * use (Date / Narration / Withdrawal / Deposit / Balance and their synonyms)
 * and reads each dated line underneath by where its figures sit under those
 * headings. With no recognisable header it still reads dated lines, taking the
 * last figure as the balance and the one before it as the amount.
 *
 * Bank-specific parsers replace this for statements they recognise.
 */
import type { ExtractedDocument, ParsedStatement, RawStatementRow, StatementWarning, TextCell, TextLine } from '../model';
import type { StatementParser } from '../parser';
import { inferDayFirst, looksLikeMoney, parseStatementAmount, parseStatementDate } from '../parsing';

type Role = 'date' | 'description' | 'debit' | 'credit' | 'amount' | 'balance' | 'reference' | 'type';
type MoneyRole = 'debit' | 'credit' | 'amount' | 'balance';
type Column = { role: Role; left: number; right: number };

/** Checked in this order: "Withdrawal Amt" is a debit, not an amount; "Closing Balance" a balance. */
const HEADER_WORDS: ReadonlyArray<readonly [Role, RegExp]> = [
  ['balance', /\b(balance|bal)\b/],
  ['debit', /\b(debit|debits|withdrawal|withdrawals|withdrawn|paid out|money out|dr amount)\b/],
  ['credit', /\b(credit|credits|deposit|deposits|paid in|money in|cr amount)\b/],
  ['type', /^(dr ?\/ ?cr|cr ?\/ ?dr|type|txn type)$/],
  ['reference', /\b(ref|reference|chq|cheque|instrument|utr)\b/],
  ['date', /\b(date|dt)\b/],
  ['description', /\b(description|narration|particulars|details|remarks|transaction details)\b/],
  ['amount', /\b(amount|amt)\b/],
];

const MONEY_ROLES: readonly MoneyRole[] = ['debit', 'credit', 'amount', 'balance'];
const BOILERPLATE = /\bpage\s+\d+(\s*(of|\/)\s*\d+)?\b|^(total|grand total|sub ?total)\b|\bcarried forward\b|\bbrought forward\b/i;
const OPENING = /\bopening\s+balance\b|\bbalance\s+b\/?f\b|\bbrought\s+forward\b/i;
const CLOSING = /\bclosing\s+balance\b|\bbalance\s+c\/?f\b|\bcarried\s+forward\b/i;
const LEADING_DATE =
  /^(\d{1,2}[/.-]\d{1,2}[/.-]\d{2,4}|\d{4}[/.-]\d{1,2}[/.-]\d{1,2}|\d{1,2}[\s-]?[a-z]{3,9}[\s,-]*\d{2,4})\b\s*/i;
const DATE_SOURCE = String.raw`\d{1,2}[/.-]\d{1,2}[/.-]\d{2,4}|\d{4}-\d{2}-\d{2}|\d{1,2}[\s-]?[A-Za-z]{3,9}[\s,-]*\d{2,4}`;
const PERIOD = new RegExp(
  String.raw`(?:from|period|statement period|for the period)[^0-9a-z]{0,12}(${DATE_SOURCE})\s*(?:to|till|until|-|–)[\s:.]*(${DATE_SOURCE})`,
  'i',
);
const ACCOUNT = /\b(?:account|a\/c|acct)\.?\s*(?:no|number|#)?\.?\s*:?\s*([x*•\d][x*•\d\s-]{3,})/i;
const MAX_CONTINUATION = 3;
const ID = 'generic-table';

const lower = (text: string) => text.toLowerCase().replace(/[.:]/g, ' ').replace(/\s+/g, ' ').trim();

function roleOf(text: string): Role | null {
  const value = lower(text);
  if (!value || value.length > 40) return null;
  for (const [role, pattern] of HEADER_WORDS) if (pattern.test(value)) return role;
  return null;
}

/** A header line names a date column, a money column and at least one more. */
function headerColumns(line: TextLine): Column[] | null {
  const columns: Column[] = [];
  for (const cell of line.cells) {
    const role = roleOf(cell.text);
    if (!role) continue;
    // A second date column is the value date — the first one is the transaction date.
    if (role === 'date' && columns.some((c) => c.role === 'date')) continue;
    columns.push({ role, left: cell.x, right: cell.x + cell.width });
  }
  const roles = new Set(columns.map((c) => c.role));
  const hasMoney = MONEY_ROLES.some((r) => roles.has(r) && r !== 'balance');
  return roles.has('date') && hasMoney && roles.size >= 3 ? columns : null;
}

/** The money column a figure sits under: most horizontal overlap, else the nearest right edge. */
function moneyRoleFor(cell: TextCell, columns: readonly Column[]): MoneyRole | null {
  const candidates = columns.filter((c): c is Column & { role: MoneyRole } => (MONEY_ROLES as readonly Role[]).includes(c.role));
  if (!candidates.length) return null;
  const right = cell.x + cell.width;
  let best: { role: MoneyRole; overlap: number; distance: number } | null = null;
  for (const column of candidates) {
    const overlap = Math.max(0, Math.min(right, column.right) - Math.max(cell.x, column.left));
    const distance = Math.min(Math.abs(right - column.right), Math.abs(cell.x + cell.width / 2 - (column.left + column.right) / 2));
    if (!best || overlap > best.overlap || (overlap === best.overlap && distance < best.distance)) {
      best = { role: column.role, overlap, distance };
    }
  }
  return best?.role ?? null;
}

function overlaps(cell: TextCell, column: Column | undefined): boolean {
  if (!column) return false;
  return Math.min(cell.x + cell.width, column.right + 4) - Math.max(cell.x, column.left - 4) > 0;
}

/** The date a line starts with, and the cells it used — split cells ("05", "Sep", "2026") and glued text included. */
function leadingDate(cells: readonly TextCell[]): { dateText: string; rest: TextCell[] } | null {
  for (let take = 1; take <= Math.min(3, cells.length); take += 1) {
    const text = cells.slice(0, take).map((c) => c.text).join(' ');
    if (parseStatementDate(text, true) || parseStatementDate(text, false)) {
      return { dateText: text, rest: cells.slice(take) };
    }
  }
  const [first, ...others] = cells;
  if (!first) return null;
  const glued = LEADING_DATE.exec(first.text);
  if (glued?.[1] && (parseStatementDate(glued[1], true) || parseStatementDate(glued[1], false))) {
    const remainder = first.text.slice(glued[0].length).trim();
    const shift = first.width * (glued[0].length / Math.max(first.text.length, 1));
    return {
      dateText: glued[1],
      rest: remainder ? [{ text: remainder, x: first.x + shift, width: first.width - shift }, ...others] : others,
    };
  }
  return null;
}

function isDate(text: string): boolean {
  return parseStatementDate(text, true) != null || parseStatementDate(text, false) != null;
}

function firstMoney(line: TextLine): number | null {
  const cell = line.cells.find((c) => looksLikeMoney(c.text));
  return cell ? (parseStatementAmount(cell.text)?.value ?? null) : null;
}

export const genericTableParser: StatementParser = {
  id: ID,
  label: 'Generic statement layout',
  // Only ever the fallback: it never claims a document over a bank parser.
  detect: () => 0,
  parse(doc: ExtractedDocument): ParsedStatement {
    const rows: RawStatementRow[] = [];
    const warnings: StatementWarning[] = [];
    let columns: Column[] | null = null;
    let sawHeader = false;
    let openingBalance: number | null = null;
    let closingBalance: number | null = null;
    let last: RawStatementRow | null = null;
    let continuation = 0;
    let accountLast4: string | null = null;

    doc.lines.forEach((line, index) => {
      const header = headerColumns(line);
      if (header) {
        columns = header;
        sawHeader = true;
        last = null;
        return;
      }

      if (!sawHeader && accountLast4 == null) {
        const digits = ACCOUNT.exec(line.text)?.[1]?.replace(/[^0-9]/g, '') ?? '';
        if (digits.length >= 4) accountLast4 = digits.slice(-4);
      }

      const dated = leadingDate(line.cells);
      if (!dated) {
        if (OPENING.test(line.text)) openingBalance ??= firstMoney(line);
        else if (CLOSING.test(line.text)) closingBalance = firstMoney(line) ?? closingBalance;
        // Wrapped narration: a line with no date and no figures right under a row.
        const boilerplate = BOILERPLATE.test(line.text) || OPENING.test(line.text) || CLOSING.test(line.text);
        const hasMoney = line.cells.some((c) => looksLikeMoney(c.text));
        if (last && !boilerplate && !hasMoney && continuation < MAX_CONTINUATION) {
          last.description = `${last.description} ${line.text}`.trim();
          continuation += 1;
        } else {
          last = null;
        }
        return;
      }

      // A value-date column right after the transaction date is not narration.
      let rest = dated.rest;
      if (rest[0] && isDate(rest[0].text)) rest = rest.slice(1);

      const money = rest.filter((c) => looksLikeMoney(c.text));
      if (!money.length) {
        if (OPENING.test(line.text) || CLOSING.test(line.text)) return;
        if (sawHeader || rows.length) {
          warnings.push({ lineIndex: index, code: 'skippedLine', message: `A dated line had no amount: "${line.text.slice(0, 80)}"` });
        }
        last = null;
        return;
      }
      if (OPENING.test(line.text)) {
        openingBalance ??= parseStatementAmount(money[money.length - 1]?.text)?.value ?? null;
        return;
      }

      const active: Column[] | null = columns;
      const row: RawStatementRow = { lineIndex: index, dateText: dated.dateText, description: '' };
      const referenceColumn = active?.find((c) => c.role === 'reference');
      const typeColumn = active?.find((c) => c.role === 'type');
      const words: string[] = [];

      for (const cell of rest) {
        if (money.includes(cell)) continue;
        if (overlaps(cell, typeColumn) && /^(dr|cr)\.?$/i.test(cell.text)) {
          row.directionHint = cell.text.toLowerCase().startsWith('cr') ? 'credit' : 'debit';
        } else if (overlaps(cell, referenceColumn)) {
          row.reference = row.reference ? `${row.reference} ${cell.text}` : cell.text;
        } else {
          words.push(cell.text);
        }
      }
      row.description = words.join(' ');

      if (active) {
        for (const cell of money) {
          const role = moneyRoleFor(cell, active);
          if (role === 'debit') row.debitText = cell.text;
          else if (role === 'credit') row.creditText = cell.text;
          else if (role === 'balance') row.balanceText = cell.text;
          else row.amountText = cell.text;
        }
      } else if (money.length >= 2) {
        row.amountText = money[money.length - 2]?.text ?? null;
        row.balanceText = money[money.length - 1]?.text ?? null;
      } else {
        row.amountText = money[0]?.text ?? null;
      }

      rows.push(row);
      last = row;
      continuation = 0;
    });

    const periodMatch = PERIOD.exec(doc.lines.map((l) => l.text).join('\n'));
    // Header dates count as evidence too: "To 30/09/2026" settles the order for every row.
    const detected = inferDayFirst([...rows.map((r) => r.dateText), periodMatch?.[1] ?? '', periodMatch?.[2] ?? '']);
    const dayFirst = detected ?? true;
    const from = periodMatch?.[1] ? parseStatementDate(periodMatch[1], dayFirst) : null;
    const to = periodMatch?.[2] ? parseStatementDate(periodMatch[2], dayFirst) : null;

    if (!rows.length) {
      warnings.push({ lineIndex: null, code: 'noTransactions', message: 'No dated transaction lines were found.' });
    }

    return {
      parserId: ID,
      bankName: null,
      accountLast4,
      period: from && to && from <= to ? { from, to } : null,
      dayFirst: detected,
      openingBalance,
      closingBalance,
      rows,
      warnings,
    };
  },
};
