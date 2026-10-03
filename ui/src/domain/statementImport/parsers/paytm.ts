/**
 * Paytm — UPI statement (PDF): "Paytm Statement for <period>".
 *
 * Layout (measured from a real statement):
 *
 *   <name> / <masked mobile>, <email>
 *   Paytm Statement for     Total Money Paid       Total Money Received
 *   2 SEP'26 - 1 OCT'26     - Rs.918.07            + Rs.0
 *                           7 Payments made        0 Payment received
 *   Note: Self transfer payments are not included in the total money paid …
 *   Accounts                       Payment made        Payment received
 *   Airtel Payments Bank - 14      Rs.719.07           Rs.0
 *                                  (6 Payments)        (0 Payment)
 *   Passbook Payments History
 *   Date & Time | Transaction Details             | Notes & Tags   | Your Account | Amount
 *   30 Sep      | Paid to Bharti Airtel Limited   | Note: Airtel   | Airtel       | - Rs.229.07
 *   10:59 AM    |                                 | Broadband Bill | Payments     |
 *               | UPI ID: airtel1paytm@hdfcbank   | Payment        | Bank - 14    |
 *               | UPI Ref No: 315827550212        | Tag:           |              |
 *               |                                 | # Bill Payments|              |
 *
 * Every column of a payment wraps onto the lines below its first line, each on
 * its own, so a payment is the block of lines from one dated line to the next —
 * never one line. The headings repeat on every page and a "Page n of m" footer
 * ends each one. Dates carry no year: it comes from the statement period, and
 * payments are listed newest first.
 *
 *   Amount        "- Rs.229.07" money out, "+ Rs.500" money in — the sign is the direction
 *   Your Account  the account that paid or received, by bank and last digits.
 *                 One statement covers several accounts, so each row names its
 *                 own (sourceAccount) and the pipeline matches it to the user's.
 *   Details       "Paid to <payee>" / "Received from <payer>" / "Automatic
 *                 payment for <merchant>", then "UPI ID: <vpa>" and "UPI Ref
 *                 No: <number>" — the UPI reference is the payment's unique id.
 *   Notes & Tags  "Note: <text>" and "Tag:" followed by "# <tag>".
 *
 * The summary at the top (totals, and per account) is read only to check the
 * rows: Paytm leaves self transfers out of its totals, so they are left out
 * of the check too.
 */
import { parsePrintedAccount } from '../accountMatch';
import type { ExtractedDocument, ParsedStatement, RawStatementRow, StatementPeriod, StatementWarning, TextLine } from '../model';
import type { StatementParser } from '../parser';
import { parseStatementDate, toCents } from '../parsing';

const ID = 'paytm-upi';

type Column = 'date' | 'details' | 'notes' | 'account' | 'amount';
type Lefts = Record<Exclude<Column, 'date'>, number>;

const HEADINGS: ReadonlyArray<readonly [Exclude<Column, 'date'>, RegExp]> = [
  ['details', /^transaction details$/],
  ['notes', /^notes\s*&\s*tags$/],
  ['account', /^your account$/],
  ['amount', /^amount$/],
];

const norm = (text: string) => text.toLowerCase().replace(/\s+/g, ' ').trim();

function headingLefts(line: TextLine): Lefts | null {
  const lefts: Partial<Lefts> = {};
  for (const cell of line.cells) {
    const column = HEADINGS.find(([, pattern]) => pattern.test(norm(cell.text)))?.[0];
    if (column && lefts[column] == null) lefts[column] = cell.x;
  }
  const { details, notes, account, amount } = lefts;
  return details != null && notes != null && account != null && amount != null ? { details, notes, account, amount } : null;
}

/** How far left of its heading a column's text may start, in PDF points ("Your Account" values start right of it). */
const SLACK = 8;
/** Lines this close below the heading row are the rest of the headings ("Date &" / "Time"). */
const HEADING_BAND = 10;

function columnOf(x: number, lefts: Lefts): Column {
  if (x >= lefts.amount - SLACK) return 'amount';
  if (x >= lefts.account - SLACK) return 'account';
  if (x >= lefts.notes - SLACK) return 'notes';
  if (x >= lefts.details - SLACK) return 'details';
  return 'date';
}

const FOOTER = /^page\s+\d+\s+of\s+\d+$/i;
const DATE_CELL = /^(\d{1,2})\s*([a-z]{3,9})\.?(?:\s*['’]?\s*(\d{2}|\d{4}))?$/i;
const TIME_CELL = /^\d{1,2}[:.]\d{2}(?:[:.]\d{2})?\s*(?:[ap]\.?\s*m\.?)?$/i;
const AMOUNT = /^([+\-−–])?\s*(?:₹|rs\.?|inr)\s*([\d,]+(?:\.\d{1,2})?)$/i;
const UPI_ID = /^upi\s*id\s*:?\s*(.*)$/i;
const UPI_REF = /^upi\s*ref(?:erence)?\.?\s*(?:no\.?|number|id)?\s*:?\s*(.*)$/i;
const NOTE = /^note\s*:\s*(.*)$/i;
const TAG_LABEL = /^tags?\s*:\s*(.*)$/i;
const SELF = /\bself\b/i;
/** "Paid to X", "Received from X", "Automatic payment for X": the other side's name. */
const PAYEE: readonly RegExp[] = [
  /^(?:paid|sent|transferred|money sent|money transferred|payment|self transfer)\s+to\s+(.+)$/i,
  /^(?:received|money received|payment received|refund(?: received)?|cashback(?: received)?|self transfer)\s+from\s+(.+)$/i,
  /^(?:automatic payment|auto ?pay(?:ment)?|mandate payment|subscription(?: payment)?)\s+(?:for|to)\s+(.+)$/i,
  /^(?:recharge|bill payment)\s+(?:for|of|to)\s+(.+)$/i,
];
/** Emoji variation selectors, keycap marks and zero-width characters that cling to a printed "#". */
const INVISIBLE = /[\p{Variation_Selector}\p{Cf}\p{Me}]/gu;

// ---------------------------------------------------------------------------
// Statement period and summary
// ---------------------------------------------------------------------------

const PERIOD = /^(\d{1,2}\s*[a-z]{3,9}\s*['’]?\s*\d{2,4})\s*[-–—]\s*(\d{1,2}\s*[a-z]{3,9}\s*['’]?\s*\d{2,4})$/i;

/** "2 SEP'26" → 2026-09-02. */
const periodDate = (text: string) => parseStatementDate(text.replace(/['’]/g, ' ').replace(/([a-z])(\d)/gi, '$1 $2'), true);

function readPeriod(lines: readonly TextLine[]): StatementPeriod | null {
  for (const line of lines) {
    for (const cell of line.cells) {
      const m = PERIOD.exec(cell.text.trim());
      if (!m) continue;
      const from = periodDate(m[1] ?? '');
      const to = periodDate(m[2] ?? '');
      if (from && to && from <= to) return { from, to };
    }
  }
  return null;
}

type Totals = { count: number | null; amount: number | null };
export type PaytmSummary = {
  paid: Totals;
  received: Totals;
  /** Per account, as the summary names them ("Airtel Payments Bank - 14"). */
  accounts: { label: string; paid: Totals; received: Totals }[];
};

const COUNT = /^\(?\s*(\d+)\s+payments?(?:\s+(?:made|received))?\s*\)?$/i;
const moneyValue = (text: string) => {
  const m = AMOUNT.exec(text.trim());
  return m ? Number((m[2] ?? '').replace(/,/g, '')) : null;
};
const centre = (cell: { x: number; width: number }) => cell.x + cell.width / 2;

/** The figures above the table: what Paytm says was paid and received, overall and per account. */
function readSummary(lines: readonly TextLine[]): PaytmSummary {
  const summary: PaytmSummary = { paid: { count: null, amount: null }, received: { count: null, amount: null }, accounts: [] };
  const totalsAt = lines.findIndex((l) => l.cells.some((c) => /^total money paid$/i.test(c.text.trim())));
  const totalsLine = lines[totalsAt];
  if (totalsLine) {
    const labels: { key: 'paid' | 'received'; at: number }[] = [];
    for (const cell of totalsLine.cells) {
      if (/^total money paid$/i.test(cell.text.trim())) labels.push({ key: 'paid', at: centre(cell) });
      else if (/^total money received$/i.test(cell.text.trim())) labels.push({ key: 'received', at: centre(cell) });
    }
    const nearest = (x: number) => [...labels].sort((a, b) => Math.abs(a.at - x) - Math.abs(b.at - x))[0]?.key;
    for (const line of lines.slice(totalsAt + 1, totalsAt + 3)) {
      for (const cell of line.cells) {
        const key = nearest(centre(cell));
        if (!key) continue;
        const amount = moneyValue(cell.text);
        const count = COUNT.exec(cell.text.trim());
        if (amount != null && cell.x > (totalsLine.cells[0]?.x ?? 0) + 60) summary[key].amount = amount;
        else if (count) summary[key].count = Number(count[1]);
      }
    }
  }

  const accountsAt = lines.findIndex(
    (l) => l.cells.some((c) => /^payments?\s+made$/i.test(c.text.trim())) && l.cells.some((c) => /^payments?\s+received$/i.test(c.text.trim())),
  );
  const accountsLine = lines[accountsAt];
  if (accountsLine) {
    const made = accountsLine.cells.find((c) => /^payments?\s+made$/i.test(c.text.trim()));
    const received = accountsLine.cells.find((c) => /^payments?\s+received$/i.test(c.text.trim()));
    if (made && received) {
      const side = (cell: { x: number; width: number }) => (Math.abs(centre(cell) - centre(made)) <= Math.abs(centre(cell) - centre(received)) ? 'paid' : 'received');
      let current: PaytmSummary['accounts'][number] | null = null;
      for (const line of lines.slice(accountsAt + 1)) {
        if (/passbook payments history/i.test(line.text) || headingLefts(line)) break;
        for (const cell of line.cells) {
          const text = cell.text.trim();
          if (cell.x < made.x - 40 && parsePrintedAccount(text)) {
            current = { label: text, paid: { count: null, amount: null }, received: { count: null, amount: null } };
            summary.accounts.push(current);
            continue;
          }
          if (!current) continue;
          const amount = moneyValue(text);
          const count = COUNT.exec(text);
          if (amount != null) current[side(cell)].amount = amount;
          else if (count) current[side(cell)].count = Number(count[1]);
        }
      }
    }
  }
  return summary;
}

// ---------------------------------------------------------------------------
// Payments
// ---------------------------------------------------------------------------

type Block = { lineIndex: number; cells: Record<Column, string[]> };

const emptyCells = (): Record<Column, string[]> => ({ date: [], details: [], notes: [], account: [], amount: [] });

/** Each page's table lines, cut into one block per payment. */
function readBlocks(doc: ExtractedDocument): { blocks: Block[]; firstTableLine: number; warnings: StatementWarning[] } {
  const blocks: Block[] = [];
  const warnings: StatementWarning[] = [];
  let firstTableLine = -1;
  const pages = [...new Set(doc.lines.map((l) => l.page))];
  for (const page of pages) {
    const onPage = doc.lines.map((line, index) => ({ line, index })).filter((e) => e.line.page === page);
    const heading = onPage.find((e) => headingLefts(e.line));
    if (!heading) continue;
    const lefts = headingLefts(heading.line);
    if (!lefts) continue;
    if (firstTableLine < 0) firstTableLine = heading.index;
    const footer = onPage.find((e) => e.index > heading.index && FOOTER.test(e.line.text.trim()));
    let openedOnPage = false;
    for (const { line, index } of onPage) {
      if (index <= heading.index || line.y >= heading.line.y - HEADING_BAND) continue;
      if (footer && line.y <= footer.line.y) continue;
      const cells = emptyCells();
      for (const cell of line.cells) cells[columnOf(cell.x, lefts)].push(cell.text.trim());
      const dated = cells.date.some((t) => DATE_CELL.test(t));
      if (dated) {
        blocks.push({ lineIndex: index, cells });
        openedOnPage = true;
        continue;
      }
      // Before the page's first payment: the rest of the headings, or the end of the last page's payment.
      const last = blocks[blocks.length - 1];
      if (!openedOnPage && cells.date.some((t) => /^(date|time|date\s*&\s*time|date\s*&)$/i.test(t))) continue;
      if (!last) {
        if (cells.amount.some((t) => AMOUNT.test(t))) {
          warnings.push({ lineIndex: index, code: 'skippedLine', message: `A line with an amount had no date: "${line.text.slice(0, 80)}"` });
        }
        continue;
      }
      for (const column of Object.keys(cells) as Column[]) last.cells[column].push(...cells[column]);
    }
  }
  return { blocks, firstTableLine, warnings };
}

const MONTH_NAMES = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/**
 * The year of each "30 Sep": the one that puts it inside the statement period
 * and keeps the newest-first order. A printed year always wins.
 */
function datesWithYears(blocks: readonly Block[], period: StatementPeriod | null): (string | null)[] {
  let upper = period?.to ?? null;
  return blocks.map((block) => {
    const m = DATE_CELL.exec(block.cells.date.find((t) => DATE_CELL.test(t)) ?? '');
    const day = Number(m?.[1]);
    const month = (m?.[2] ?? '').slice(0, 3).toLowerCase();
    const monthIndex = MONTH_NAMES.findIndex((name) => name.toLowerCase() === month);
    if (!m || monthIndex < 0) return null;
    const label = `${String(day)} ${MONTH_NAMES[monthIndex] ?? ''}`;
    if (m[3]) return parseStatementDate(`${label} ${m[3]}`, true) ? `${label} ${m[3]}` : null;
    if (!period) return null;
    const first = Number(period.from.slice(0, 4));
    const last = Number(period.to.slice(0, 4));
    const candidates: { text: string; iso: string }[] = [];
    for (let year = last; year >= first; year -= 1) {
      const iso = parseStatementDate(`${label} ${String(year)}`, true);
      if (iso) candidates.push({ text: `${label} ${String(year)}`, iso });
    }
    const inPeriod = candidates.filter((c) => c.iso >= period.from && c.iso <= period.to);
    const chosen = inPeriod.find((c) => upper == null || c.iso <= upper) ?? inPeriod[0] ?? candidates[0];
    if (chosen) upper = chosen.iso;
    return chosen?.text ?? null;
  });
}

const joined = (parts: readonly string[]) => parts.join(' ').replace(/\s+/g, ' ').trim();

function cleanTag(raw: string): string {
  return raw.replace(INVISIBLE, '').replace(/\s+/g, ' ').trim();
}

/** "Note: …" (wrapped over several lines) and the tags under "Tag:". */
function notesAndTags(lines: readonly string[]): { note: string | null; tags: string[] } {
  const note: string[] = [];
  const tagText: string[] = [];
  let mode: 'note' | 'tag' | null = null;
  for (const text of lines) {
    const isNote = NOTE.exec(text);
    const isTag = TAG_LABEL.exec(text);
    if (isTag) {
      mode = 'tag';
      if (isTag[1]) tagText.push(isTag[1]);
    } else if (isNote) {
      mode = 'note';
      if (isNote[1]) note.push(isNote[1]);
    } else if (mode === 'note') {
      note.push(text);
    } else if (mode === 'tag' || text.replace(INVISIBLE, '').trim().startsWith('#')) {
      mode = 'tag';
      tagText.push(text);
    } else {
      note.push(text);
    }
  }
  const tags = joined(tagText)
    .split('#')
    .map(cleanTag)
    .filter(Boolean);
  return { note: joined(note) || null, tags: [...new Map(tags.map((t) => [t.toLowerCase(), t])).values()] };
}

/** The payment's title, UPI ID and UPI reference from the Transaction Details column. */
function details(lines: readonly string[]): { title: string; upiId: string | null; reference: string | null } {
  const title: string[] = [];
  let upiId: string | null = null;
  let reference: string | null = null;
  for (const text of lines) {
    const id = UPI_ID.exec(text);
    const ref = UPI_REF.exec(text);
    if (ref) {
      reference = /[a-z0-9]+/i.exec(ref[1] ?? '')?.[0] ?? null;
    } else if (id) {
      // A UPI ID has no spaces: the token with "@" (the PDF text adds stray words after it).
      const tokens = (id[1] ?? '').trim().split(/\s+/).filter(Boolean);
      upiId = tokens.find((t) => t.includes('@')) ?? tokens[0] ?? null;
    } else if (upiId == null && reference == null) {
      title.push(text);
    } else if (upiId != null && reference == null && !upiId.includes('@')) {
      // The rest of a UPI ID too long for one line.
      upiId += text.replace(/\s+/g, '');
    }
  }
  return { title: joined(title), upiId, reference };
}

function payeeOf(title: string): string | null {
  for (const pattern of PAYEE) {
    const m = pattern.exec(title);
    if (m?.[1]?.trim()) return m[1].trim();
  }
  return null;
}

export type PaytmStatement = {
  rows: RawStatementRow[];
  period: StatementPeriod | null;
  summary: PaytmSummary;
  warnings: StatementWarning[];
};

/** The rows, the period and the printed summary — exported for tests and the totals check. */
export function readPaytmStatement(doc: ExtractedDocument): PaytmStatement {
  const { blocks, firstTableLine, warnings } = readBlocks(doc);
  const top = firstTableLine >= 0 ? doc.lines.slice(0, firstTableLine) : doc.lines;
  const period = readPeriod(top);
  const summary = readSummary(top);
  const dates = datesWithYears(blocks, period);
  const rows: RawStatementRow[] = [];

  blocks.forEach((block, i) => {
    const dateText = dates[i];
    const firstLine = doc.lines[block.lineIndex]?.text.slice(0, 80) ?? '';
    if (!dateText) {
      warnings.push({
        lineIndex: block.lineIndex,
        code: 'unparseableDate',
        message: period ? `Unreadable date on "${firstLine}"` : `The statement period was not found, so the year of "${firstLine}" is unknown`,
      });
      return;
    }
    const amountText = block.cells.amount.find((t) => AMOUNT.test(t)) ?? null;
    const sign = amountText ? AMOUNT.exec(amountText)?.[1] : undefined;
    const { title, upiId, reference } = details(block.cells.details);
    const { note, tags } = notesAndTags(block.cells.notes);
    const counterparty = payeeOf(title);
    rows.push({
      lineIndex: block.lineIndex,
      dateText,
      timeText: block.cells.date.find((t) => TIME_CELL.test(t)) ?? null,
      description: title,
      amountText,
      // The sign is the direction; without one it stays unknown rather than guessed.
      directionHint: sign === '+' ? 'credit' : sign ? 'debit' : null,
      reference,
      counterparty,
      channel: 'upi',
      notes: note,
      tags,
      upiId,
      sourceAccount: joined(block.cells.account) || null,
      // "Self transfer to HDFC Bank - 59": the other side is an account, not a person.
      counterpartyAccount: counterparty && parsePrintedAccount(counterparty) ? counterparty : null,
    });
  });

  warnings.push(...totalsWarnings(rows, summary));
  return { rows, period, summary, warnings };
}

// ---------------------------------------------------------------------------
// Totals check
// ---------------------------------------------------------------------------

const accountKey = (label: string) => norm(label).replace(/\s*[-–—]\s*/g, ' - ');
const rupees = (cents: number) => `Rs.${(cents / 100).toFixed(2).replace(/\.00$/, '')}`;

/** What the rows add up to, in the summary's terms. Self transfers are left out, as Paytm leaves them out. */
export function paytmRowTotals(rows: readonly RawStatementRow[]): { paid: { count: number; cents: number }; received: { count: number; cents: number }; byAccount: Map<string, { paid: { count: number; cents: number }; received: { count: number; cents: number } }> } {
  const totals = { paid: { count: 0, cents: 0 }, received: { count: 0, cents: 0 }, byAccount: new Map<string, { paid: { count: number; cents: number }; received: { count: number; cents: number } }>() };
  for (const row of rows) {
    if (SELF.test(row.description)) continue;
    const value = moneyValue(row.amountText ?? '');
    if (value == null || !row.directionHint) continue;
    const side = row.directionHint === 'credit' ? 'received' : 'paid';
    totals[side].count += 1;
    totals[side].cents += toCents(value);
    const key = accountKey(row.sourceAccount ?? '');
    const account = totals.byAccount.get(key) ?? { paid: { count: 0, cents: 0 }, received: { count: 0, cents: 0 } };
    account[side].count += 1;
    account[side].cents += toCents(value);
    totals.byAccount.set(key, account);
  }
  return totals;
}

/** The summary's figures against the rows read — a difference means a payment was missed or misread. */
function totalsWarnings(rows: readonly RawStatementRow[], summary: PaytmSummary): StatementWarning[] {
  const read = paytmRowTotals(rows);
  const problems: string[] = [];
  const compare = (what: string, printed: Totals, actual: { count: number; cents: number }) => {
    const countOff = printed.count != null && printed.count !== actual.count;
    const amountOff = printed.amount != null && toCents(printed.amount) !== actual.cents;
    if (countOff || amountOff) {
      problems.push(
        `${what}: the statement says ${printed.count != null ? `${String(printed.count)} for ` : ''}${printed.amount != null ? rupees(toCents(printed.amount)) : 'an amount'}, ` +
          `the rows read add up to ${String(actual.count)} for ${rupees(actual.cents)}`,
      );
    }
  };
  compare('Paid', summary.paid, read.paid);
  compare('Received', summary.received, read.received);
  for (const account of summary.accounts) {
    const actual = read.byAccount.get(accountKey(account.label)) ?? { paid: { count: 0, cents: 0 }, received: { count: 0, cents: 0 } };
    compare(`Paid from ${account.label}`, account.paid, actual.paid);
    compare(`Received in ${account.label}`, account.received, actual.received);
  }
  return problems.map((message) => ({
    lineIndex: null,
    code: 'balanceMismatch' as const,
    message: `${message} — a payment may be missing or misread.`,
  }));
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

export const paytmParser: StatementParser = {
  id: ID,
  label: 'Paytm UPI statement',
  detect(doc) {
    // Paytm's own column set *and* Paytm named above it on the same page. A bank
    // statement that merely shows payments to "…@paytm" never has both.
    const at = doc.lines.findIndex((line) => headingLefts(line));
    const heading = doc.lines[at];
    if (!heading) return 0;
    const above = doc.lines.slice(0, at).filter((line) => line.page === heading.page);
    return above.some((line) => /\bpaytm\b/i.test(line.text)) ? 0.97 : 0;
  },
  parse(doc): ParsedStatement {
    const { rows, period, warnings } = readPaytmStatement(doc);
    if (!rows.length) warnings.push({ lineIndex: null, code: 'noTransactions', message: 'No payments were found under the Paytm Passbook Payments History.' });
    return {
      parserId: ID,
      bankName: 'Paytm',
      accountLast4: null,
      period,
      dayFirst: true,
      openingBalance: null,
      closingBalance: null,
      rows,
      warnings,
      accountPerRow: true,
    };
  },
};
