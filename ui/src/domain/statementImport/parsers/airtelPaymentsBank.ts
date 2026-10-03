/**
 * Airtel Payments Bank — savings account statements (PDF).
 *
 * Layout (measured from a real statement):
 *
 *   Account Statement / account, IFSC, "Statement Period: dd-mm-yyyy - dd-mm-yyyy" …
 *   Date | Transaction ID | Particulars | Debit | Credit | Balance
 *   dd-mm-yyyy | AB0000… | PAYMENT … VIA UPI TO … | 99.00 | - | 9999.00
 *              |         | …(wrapped every 26 characters, mid-word)…
 *   …
 *   ₹9999.00          ₹9999.00          ₹99999.00      ₹99999.00
 *   Opening Balance   Closing Balance   Total Credit   Total Debit
 *
 *   Date → transaction date, Transaction ID → reference, Particulars → the
 *   narration, kept exactly as printed; Debit → debit, Credit → credit
 *   ("-" when empty), Balance → the running balance after the row. Rows run
 *   oldest first. Each page repeats the account line and the headings and ends
 *   with an "Airtel Payments Bank Ltd." footer. Particulars are cut into
 *   fixed-width pieces regardless of words, with no space kept at either end of
 *   a piece (see joinPieces). After the last row a summary gives the
 *   opening and closing balances and the credit / debit totals, values above
 *   their labels.
 *
 * Particulars, mapped to bank-neutral channels — only what these statements
 * actually print:
 *   PAYMENT … VIA UPI TO …        upi (debit)
 *   PAYMENT RECEIVED VIA UPI …    upi (credit)
 *   ACCOUNT … CHARGE              charges
 * UPI Particulars name the other side only by UPI ID, never by name, so no
 * payee is taken from them (a handle is not a name).
 */
import type {
  ExtractedDocument,
  ParsedStatement,
  RawStatementRow,
  StatementWarning,
  TextCell,
  TextLine,
  TransactionChannel,
} from '../model';
import type { StatementParser } from '../parser';
import { parseStatementAmount, parseStatementDate, toCents } from '../parsing';

const ID = 'airtel-payments-bank';

type Role = 'date' | 'reference' | 'particulars' | 'debit' | 'credit' | 'balance';
type Column = { role: Role; left: number; right: number };

const HEADINGS: ReadonlyArray<readonly [Role, RegExp]> = [
  ['date', /^date$/],
  ['reference', /^transaction id$/],
  ['particulars', /^particulars$/],
  ['debit', /^debit$/],
  ['credit', /^credit$/],
  ['balance', /^balance$/],
];
const ROLES: readonly Role[] = ['date', 'reference', 'particulars', 'debit', 'credit', 'balance'];

type SummaryField = 'opening' | 'closing' | 'totalCredit' | 'totalDebit';
const SUMMARY_LABELS: ReadonlyArray<readonly [SummaryField, RegExp]> = [
  ['opening', /^opening balance$/],
  ['closing', /^closing balance$/],
  ['totalCredit', /^total credit$/],
  ['totalDebit', /^total debit$/],
];

/** The statement's own identity, never a narration: the bank's name or its IFSC prefix. */
const BANK_NAME = /\bairtel\s+payments\s+bank\b/i;
const IFSC_AIRTEL = /\bAIRP0[A-Z0-9]{6}\b/;
const DATE_TEXT = String.raw`\d{1,2}-\d{1,2}-\d{4}`;
const PERIOD = new RegExp(String.raw`\bstatement\s+period\s*:?\s*(${DATE_TEXT})\s*-\s*(${DATE_TEXT})`, 'i');
const ACCOUNT = /\baccount\s+number\s*:?\s*([X*\d][X*\d\s-]{5,})/i;

const normalise = (text: string) => text.toLowerCase().replace(/[.:]+$/, '').replace(/\s+/g, ' ').trim();

function headerColumns(line: TextLine): Column[] | null {
  const columns: Column[] = [];
  for (const cell of line.cells) {
    const text = normalise(cell.text);
    const role = HEADINGS.find(([, pattern]) => pattern.test(text))?.[0];
    if (role && !columns.some((c) => c.role === role)) columns.push({ role, left: cell.x, right: cell.x + cell.width });
  }
  return ROLES.every((r) => columns.some((c) => c.role === r)) ? columns : null;
}

const isDate = (text: string | undefined) => parseStatementDate(text?.trim() ?? '', true) != null;

/**
 * The column a cell belongs to: most horizontal overlap, else the nearest
 * aligned edge — but the Date column only ever holds a date.
 */
function columnOf(cell: TextCell, columns: readonly Column[]): Role {
  const right = cell.x + cell.width;
  const ranked = columns
    .map((column) => ({
      role: column.role,
      overlap: Math.max(0, Math.min(right, column.right) - Math.max(cell.x, column.left)),
      distance: Math.min(Math.abs(cell.x - column.left), Math.abs(right - column.right)),
    }))
    .sort((a, b) => b.overlap - a.overlap || a.distance - b.distance);
  const [best, next] = ranked;
  if (best?.role === 'date' && next && !isDate(cell.text)) return next.role;
  return best?.role ?? 'particulars';
}

function cellsByRole(line: TextLine, columns: readonly Column[]): { text: Partial<Record<Role, string>>; left: Partial<Record<Role, number>> } {
  const text: Partial<Record<Role, string>> = {};
  const left: Partial<Record<Role, number>> = {};
  for (const cell of line.cells) {
    const role = columnOf(cell, columns);
    text[role] = text[role] ? `${text[role]} ${cell.text}` : cell.text;
    left[role] = Math.min(left[role] ?? Infinity, cell.x);
  }
  return { text, left };
}

/** How far left of its column a wrapped line's text may start (PDF points). */
const EDGE_TOLERANCE = 4;

/**
 * Rebuilds a Particulars from its line pieces. Airtel cuts the text every N
 * characters, spaces included, and the PDF text keeps no space at either end
 * of a piece. A piece shorter than the full width therefore ended in a space,
 * and that boundary gets one back; a full-width piece ran straight on. A space
 * that fell at the very start of a piece is not in the PDF at all, so there the
 * words stay joined, exactly as the PDF text has them.
 */
function joinPieces(pieces: readonly string[], fullWidth: number): string {
  return pieces.reduce((text, piece, i) => (i === 0 ? piece : `${text}${(pieces[i - 1]?.length ?? 0) < fullWidth ? ' ' : ''}${piece}`), '');
}

// ---------------------------------------------------------------------------
// Particulars
// ---------------------------------------------------------------------------

export type AirtelParticulars = { channel: TransactionChannel | null; counterparty: string | null };

/** Maps the Particulars text to a channel. The payee stays null: Airtel names the other side only by UPI ID. */
export function interpretAirtelParticulars(particulars: string): AirtelParticulars {
  const text = particulars.replace(/\s+/g, ' ').trim();
  if (/\bVIA UPI\b/i.test(text)) return { channel: 'upi', counterparty: null };
  if (/\bCHARGES?\b/i.test(text)) return { channel: 'charges', counterparty: null };
  return { channel: null, counterparty: null };
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

type Summary = Partial<Record<SummaryField, number>>;

/** The summary after the last row: a line of labels with their values on the line above. */
function readSummary(doc: ExtractedDocument): { summary: Summary; lines: Set<number> } | null {
  const labelsAt = doc.lines.findIndex((line) => {
    const labels = line.cells.map((c) => normalise(c.text));
    return SUMMARY_LABELS.every(([, pattern]) => labels.some((l) => pattern.test(l)));
  });
  const labels = doc.lines[labelsAt];
  const values = doc.lines[labelsAt - 1];
  if (!labels || !values || values.page !== labels.page) return null;
  const figures = values.cells.filter((c) => parseStatementAmount(c.text) != null);
  if (figures.length < SUMMARY_LABELS.length) return null;

  const summary: Summary = {};
  for (const cell of labels.cells) {
    const field = SUMMARY_LABELS.find(([, pattern]) => pattern.test(normalise(cell.text)))?.[0];
    if (!field) continue;
    const centre = cell.x + cell.width / 2;
    const nearest = [...figures].sort((a, b) => Math.abs(a.x + a.width / 2 - centre) - Math.abs(b.x + b.width / 2 - centre))[0];
    const value = parseStatementAmount(nearest?.text)?.value;
    if (value != null) summary[field] = value;
  }
  return { summary, lines: new Set([labelsAt - 1, labelsAt]) };
}

type Table = {
  rows: RawStatementRow[];
  warnings: StatementWarning[];
  summary: Summary;
  /** Lines outside the transaction table: each page's block above its headings, and everything after the last row. */
  ownLines: TextLine[];
};

function readTable(doc: ExtractedDocument): Table | null {
  const headerAt = new Map<number, number>();
  doc.lines.forEach((line, index) => {
    if (!headerAt.has(line.page) && headerColumns(line)) headerAt.set(line.page, index);
  });
  if (!headerAt.size) return null;
  const summary = readSummary(doc);

  const rows: RawStatementRow[] = [];
  const pieces = new Map<RawStatementRow, string[]>();
  const warnings: StatementWarning[] = [];
  let columns: Column[] | null = null;
  let last: RawStatementRow | null = null;
  // Where Particulars and Transaction ID text starts, learnt from dated rows — wrapped lines start there too.
  const textLeft: Partial<Record<Role, number>> = {};
  // A non-table line since `last` (footer, next page's header block) and the page `last` was last extended on.
  let interrupted = false;
  let lastPage = 0;
  let lastTableLine = -1;
  const money = (v: string | undefined) => parseStatementAmount(v) != null;

  doc.lines.forEach((line, index) => {
    if (summary?.lines.has(index)) {
      last = null;
      return;
    }
    const header = headerColumns(line);
    if (header) {
      // Repeated on every page; a row may still continue below it.
      columns = header;
      interrupted = true;
      return;
    }
    const active: Column[] | null = columns;
    if (!active) return;

    const { text: cells, left } = cellsByRole(line, active);
    const dateText = cells.date?.trim() ?? '';

    if (!isDate(dateText)) {
      if (money(cells.balance) && (money(cells.debit) || money(cells.credit))) {
        warnings.push({ lineIndex: index, code: 'skippedLine', message: `A line with amounts had no date: "${line.text.slice(0, 80)}"` });
        last = null;
        lastTableLine = index;
        return;
      }
      // A wrapped Particulars / Transaction ID continues the row above: nothing but those two
      // columns, no figures, each piece starting inside its column — so the account line and
      // footer repeated on every page (both at the left margin) are never taken for a wrap.
      const wrapped =
        (cells.particulars != null || cells.reference != null) &&
        !money(cells.debit) &&
        !money(cells.credit) &&
        !money(cells.balance) &&
        Object.keys(cells).every((role) => role === 'particulars' || role === 'reference') &&
        (['particulars', 'reference'] as const).every((role) => cells[role] == null || (left[role] ?? 0) >= (textLeft[role] ?? Infinity) - EDGE_TOLERANCE);
      if (last && wrapped && (!interrupted || line.page > lastPage)) {
        if (cells.particulars) pieces.get(last)?.push(cells.particulars.trim());
        if (cells.reference) last.reference = `${last.reference ?? ''}${cells.reference.replace(/\s+/g, '')}`;
        interrupted = false;
        lastPage = line.page;
        lastTableLine = index;
      } else if (last) {
        interrupted = true;
      }
      return;
    }

    // An empty Debit / Credit is printed as "-".
    const figure = (v: string | undefined) => (money(v) ? (v?.trim() ?? null) : null);
    const debit = figure(cells.debit);
    const credit = figure(cells.credit);
    if (!debit && !credit) {
      warnings.push({ lineIndex: index, code: 'skippedLine', message: `A dated line had no amount: "${line.text.slice(0, 80)}"` });
      last = null;
      lastTableLine = index;
      return;
    }
    const row: RawStatementRow = {
      lineIndex: index,
      dateText,
      description: '',
      debitText: debit,
      creditText: credit,
      balanceText: cells.balance?.trim() || null,
      reference: cells.reference?.replace(/\s+/g, '') || null,
    };
    rows.push(row);
    pieces.set(row, cells.particulars ? [cells.particulars.trim()] : []);
    last = row;
    interrupted = false;
    lastPage = line.page;
    lastTableLine = index;
    for (const role of ['particulars', 'reference'] as const) {
      const at = left[role];
      if (at != null) textLeft[role] = Math.min(textLeft[role] ?? Infinity, at);
    }
  });

  // Particulars are rebuilt once every piece is known — the full piece width is the longest piece that wrapped.
  const fullWidth = Math.max(0, ...[...pieces.values()].flatMap((p) => p.slice(0, -1).map((piece) => piece.length)));
  for (const row of rows) row.description = joinPieces(pieces.get(row) ?? [], fullWidth);

  const ownLines = doc.lines.filter((line, index) => {
    const pageHeader = headerAt.get(line.page);
    return (pageHeader != null && index < pageHeader) || index > lastTableLine;
  });
  return { rows, warnings, summary: summary?.summary ?? {}, ownLines };
}

/** The statement's own totals against the rows read — a mismatch means a row was missed or misread. */
function totalsWarning(rows: readonly RawStatementRow[], summary: Summary): StatementWarning | null {
  const sum = (pick: (r: RawStatementRow) => string | null | undefined) => rows.reduce((total, r) => total + toCents(parseStatementAmount(pick(r))?.value ?? 0), 0);
  const credits = sum((r) => r.creditText);
  const debits = sum((r) => r.debitText);
  const creditOff = summary.totalCredit != null && toCents(summary.totalCredit) !== credits;
  const debitOff = summary.totalDebit != null && toCents(summary.totalDebit) !== debits;
  return creditOff || debitOff
    ? { lineIndex: null, code: 'balanceMismatch', message: 'The statement’s credit/debit totals differ from the rows read — a row may be missing.' }
    : null;
}

export const airtelPaymentsBankParser: StatementParser = {
  id: ID,
  label: 'Airtel Payments Bank',
  detect(doc) {
    // Airtel's column set *and* Airtel named outside the transaction table. A narration
    // mentioning Airtel (a recharge, a payment to an Airtel account) is never proof.
    const table = readTable(doc);
    if (!table) return 0;
    return table.ownLines.some((line) => BANK_NAME.test(line.text) || IFSC_AIRTEL.test(line.text)) ? 0.95 : 0;
  },
  parse(doc): ParsedStatement {
    const table = readTable(doc);
    const rows = table?.rows ?? [];
    const warnings = table?.warnings ?? [];
    const summary = table?.summary ?? {};

    for (const row of rows) Object.assign(row, interpretAirtelParticulars(row.description));

    if (!rows.length) warnings.push({ lineIndex: null, code: 'noTransactions', message: 'No transactions were found under the Airtel Payments Bank header.' });
    const totals = rows.length ? totalsWarning(rows, summary) : null;
    if (totals) warnings.push(totals);

    const own = (table?.ownLines ?? []).map((l) => l.text).join('\n');
    const digits = ACCOUNT.exec(own)?.[1]?.replace(/\D/g, '') ?? '';
    const period = PERIOD.exec(own);
    const from = period?.[1] ? parseStatementDate(period[1], true) : null;
    const to = period?.[2] ? parseStatementDate(period[2], true) : null;

    return {
      parserId: ID,
      bankName: 'Airtel Payments Bank',
      accountLast4: digits.length >= 4 ? digits.slice(-4) : null,
      period: from && to && from <= to ? { from, to } : null,
      // Airtel prints dd-mm-yyyy.
      dayFirst: true,
      openingBalance: summary.opening ?? null,
      closingBalance: summary.closing ?? null,
      rows,
      warnings,
    };
  },
};
