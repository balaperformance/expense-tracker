/**
 * HDFC Bank — savings / current account statements.
 *
 * Layout (the NetBanking Excel download; the PDF prints the same table):
 *
 *   HDFC BANK Ltd.            Page No .: 1            Statement of accounts
 *   ********************************************************************
 *   Date | Narration | Chq./Ref.No. | Value Dt | Withdrawal Amt. | Deposit Amt. | Closing Balance
 *   ******** | ********* | ************ | ******** | *************** | ************ | ***************
 *   dd/mm/yy | UPI-…     | 0000…        | dd/mm/yy |          999.00 |              |       99,999.00
 *
 *   Withdrawal Amt. → debit, Deposit Amt. → credit, Closing Balance → balance.
 *   Amounts may be plain numbers without decimals (the Excel file stores them
 *   as numbers). In the PDF, a long narration wraps onto following lines —
 *   across a page break too — the column headings are printed on the first
 *   page only (later pages repeat just the customer/account block), and a
 *   "STATEMENT SUMMARY" block after the table gives the opening and closing
 *   balances.
 *
 * Narration codes, mapped to bank-neutral channels:
 *   UPI-<payee>-<vpa@handle>-<IFSC>-<UPI ref>-<remark>   upi (payee = counterparty)
 *   NWD- / ATW- / EAW- <card>-<terminal>-<place>          atm (non-HDFC / HDFC ATM cash)
 *   POS <card no> <merchant>                              card
 *   EMI <loan no> … / DPI <loan no> …                     loan
 *   NEFT DR- / NEFT CR- / RTGS … <IFSC>-<name>-…          neft / rtgs
 *   IMPS-<ref>-<name>-<bank>-<a/c>-<remark>               imps
 *   ACH D- / ACH C- <company>-<ref>                       ach (NACH mandates)
 *   CC <card> AUTOPAY SI-TAD                              cardBill
 *   CREDIT INTEREST CAPITALISED                           interest
 *   … CHGS / CHARGES / MARKUP / FEE                       charges
 *   REV-UPI / UPI-REV / UPIRET …                          reversal
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
import { parseStatementAmount, parseStatementDate } from '../parsing';

const ID = 'hdfc-bank';

type Role = 'date' | 'narration' | 'reference' | 'valueDate' | 'withdrawal' | 'deposit' | 'balance';
type Column = { role: Role; left: number; right: number };

const HEADINGS: ReadonlyArray<readonly [Role, RegExp]> = [
  ['date', /^date$/],
  ['narration', /^narration$/],
  ['reference', /^chq\.?\s*\/\s*ref\.?\s*no\.?$/],
  ['valueDate', /^value\s*dt\.?$/],
  ['withdrawal', /^withdrawal\s*amt\.?$/],
  ['deposit', /^deposit\s*amt\.?$/],
  ['balance', /^closing\s*balance$/],
];
const REQUIRED: readonly Role[] = ['date', 'narration', 'withdrawal', 'deposit', 'balance'];

const RULER = /^\*+$/;
const SUMMARY = /statement\s+summary/i;
const BANK_NAME = /\bhdfc\s*bank\b/i;
const IFSC_HDFC = /\bHDFC0[A-Z0-9]{6}\b/;
const ACCOUNT = /\bA(?:ccount|\/C)\s*No\.?\s*:?\s*(\d[\d\s]{5,})/i;
const PERIOD = /\bFrom\s*:?\s*(\d{2}\/\d{2}\/\d{2,4})\s*To\s*:?\s*(\d{2}\/\d{2}\/\d{2,4})/i;
const IFSC = /^[A-Z]{4}0[A-Z0-9]{6}$/;

const normalise = (text: string) => text.toLowerCase().replace(/\s+/g, ' ').trim();

function headerColumns(line: TextLine): Column[] | null {
  const columns: Column[] = [];
  for (const cell of line.cells) {
    const text = normalise(cell.text);
    const role = HEADINGS.find(([, pattern]) => pattern.test(text))?.[0];
    if (role && !columns.some((c) => c.role === role)) columns.push({ role, left: cell.x, right: cell.x + cell.width });
  }
  return REQUIRED.every((r) => columns.some((c) => c.role === r)) ? columns : null;
}

/**
 * The column a cell belongs to: most horizontal overlap, else the nearest
 * aligned edge — but the Date column only ever holds a date. The PDF centres
 * "Narration" over a wide column, so a short first narration fragment
 * ("UPI-A…") sits nearer the Date heading than its own; it goes to the
 * next-best column (Narration) instead of turning the date into
 * "01/09/26 UPI-A" and losing the row.
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
  if (best?.role === 'date' && next && parseStatementDate(cell.text, true) == null) return next.role;
  return best?.role ?? 'narration';
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

/** How far left of the narration column a wrapped line may start (PDF points; spreadsheet columns are 100 apart). */
const EDGE_TOLERANCE = 4;

// ---------------------------------------------------------------------------
// Narration codes
// ---------------------------------------------------------------------------

export type HdfcNarration = { channel: TransactionChannel | null; counterparty: string | null };

/** A usable name: trimmed, and never a bare reference number. */
const clean = (value: string | undefined) => {
  const text = value?.replace(/\s+/g, ' ').trim();
  return text && !/^[\d\s]+$/.test(text) ? text : null;
};

/**
 * UPI-<payee>-<vpa@handle>-<IFSC>-<ref>-<remark>. The payee may contain
 * hyphens ("A-ONE TRADERS"), and so may the VPA: apps add a numeric suffix
 * ("name183-2@okaxis"), which splits into "…-NAME183-2@OKAXIS-…". A 1–3 digit
 * fragment before the "@" is such a suffix, so the space-free segment before
 * it is the start of the VPA, not part of the name. The narration itself is
 * kept whole; only the payee is trimmed.
 */
function upiPayee(parts: readonly string[]): string | null {
  const at = parts.findIndex((p, i) => i > 0 && p.includes('@'));
  if (at < 0) return clean(parts[1]);
  let vpaStart = at;
  const local = parts[at]?.split('@')[0]?.trim() ?? '';
  if (/^\d{1,3}$/.test(local) && vpaStart - 1 > 1 && !/\s/.test(parts[vpaStart - 1]?.trim() ?? '')) vpaStart -= 1;
  // No name before the VPA: better no payee than the handle.
  return vpaStart > 1 ? clean(parts.slice(1, vpaStart).join('-')) : null;
}

/** NEFT/RTGS: <code>-<IFSC>-<name>-…; the name follows the IFSC. */
function afterIfsc(parts: readonly string[]): string | null {
  const at = parts.findIndex((p) => IFSC.test(p.trim()));
  return clean(at >= 0 ? parts[at + 1] : parts[1]);
}

/** Maps HDFC's narration codes to a channel and, where the narration names one, the payee or payer. */
export function interpretHdfcNarration(narration: string): HdfcNarration {
  const text = narration.replace(/\s+/g, ' ').trim();
  const upper = text.toUpperCase();
  const parts = text.split('-');

  if (/^(REV|RVSL)[\s-]*UPI|^UPI[\s-]*(REV|RET)|^UPIRET/.test(upper)) {
    return { channel: 'reversal', counterparty: upiPayee(text.replace(/^(REV|RVSL)[\s-]*/i, '').split('-')) };
  }
  if (upper.startsWith('UPI-')) return { channel: 'upi', counterparty: upiPayee(parts) };
  if (/\b(CHGS|CHARGES|CHRG|MARKUP|ANNUAL FEE|SMS ALERT)\b/.test(upper)) return { channel: 'charges', counterparty: null };
  if (/^(NWD|ATW|EAW)[\s-]/.test(upper)) return { channel: 'atm', counterparty: null };
  if (/^POS\s/.test(upper)) {
    const merchant = text.replace(/^POS\s+(REF\s+)?[0-9X*]{8,}\s*/i, '').replace(/[\s-]*POS DEBIT$/i, '');
    return { channel: 'card', counterparty: clean(merchant) };
  }
  if (/^(EMI|DPI)\s+\d/.test(upper)) return { channel: 'loan', counterparty: null };
  if (/^NEFT\b/.test(upper)) return { channel: 'neft', counterparty: afterIfsc(parts) };
  if (/^RTGS\b/.test(upper)) return { channel: 'rtgs', counterparty: afterIfsc(parts) };
  if (upper.startsWith('IMPS-')) return { channel: 'imps', counterparty: clean(/^\d+$/.test(parts[1]?.trim() ?? '') ? parts[2] : parts[1]) };
  if (/^ACH\s*[DC]\s*-/.test(upper)) return { channel: 'ach', counterparty: clean(text.replace(/^ACH\s*[DC]\s*-\s*/i, '').split('-')[0]) };
  if (/\bAUTOPAY\b.*\bSI-TAD\b|^CC\s*\d{4}|\bCREDIT CARD\b/.test(upper)) return { channel: 'cardBill', counterparty: null };
  if (/CREDIT INTEREST CAPITALISED|^INT\.?\s?PD\b|\bINTEREST PAID\b/.test(upper)) return { channel: 'interest', counterparty: null };
  if (/^(CHQ|CLG|INWARD CLG|OUTWARD CLG)\b/.test(upper)) return { channel: 'cheque', counterparty: null };
  if (/^(CASH DEP|BY CASH|CASH DEPOSIT|CDM)\b/.test(upper)) return { channel: 'cash', counterparty: null };
  if (/^(FT\s*-\s*(DR|CR)|FUNDS TRANSFER|TPT-)/.test(upper)) return { channel: 'internal', counterparty: null };
  return { channel: null, counterparty: null };
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

function firstLines(doc: ExtractedDocument, count = 40): string {
  return doc.lines
    .slice(0, count)
    .map((l) => l.text)
    .join('\n');
}

export const hdfcParser: StatementParser = {
  id: ID,
  label: 'HDFC Bank',
  detect(doc) {
    // HDFC's column set *and* HDFC named in the statement's own header area. Headings
    // alone are not proof, and narrations don't count: any bank's statement can show a
    // payment to an HDFC account ("…-HDFC0001234-…").
    const headerAt = doc.lines.findIndex((line) => headerColumns(line));
    if (headerAt < 0) return 0;
    const summaryAt = doc.lines.findIndex((line) => SUMMARY.test(line.text));
    const own = [...doc.lines.slice(0, headerAt), ...(summaryAt >= 0 ? doc.lines.slice(summaryAt) : [])];
    return own.some((line) => BANK_NAME.test(line.text) || IFSC_HDFC.test(line.text)) ? 0.95 : 0;
  },
  parse(doc): ParsedStatement {
    const rows: RawStatementRow[] = [];
    const warnings: StatementWarning[] = [];
    let columns: Column[] | null = null;
    let last: RawStatementRow | null = null;
    // Where the narration column starts, learnt from dated rows — wrapped lines start there too.
    let narrationLeft = Infinity;
    // A non-table line since `last` (page footer, next page's header block) and the page `last` was last extended on.
    let interrupted = false;
    let lastPage = 0;
    let inSummary = false;
    let openingBalance: number | null = null;
    let closingBalance: number | null = null;

    doc.lines.forEach((line, index) => {
      if (inSummary) {
        // "Opening Balance  Dr Count  Cr Count  Debits  Credits  Closing Bal", then the figures.
        const figures = line.cells.map((c) => parseStatementAmount(c.text)).filter((a) => a != null);
        if (openingBalance == null && figures.length >= 4 && !/[a-z]/i.test(line.text)) {
          openingBalance = figures[0]?.value ?? null;
          closingBalance = figures[figures.length - 1]?.value ?? null;
        }
        return;
      }
      if (SUMMARY.test(line.text)) {
        inSummary = true;
        last = null;
        return;
      }
      const header = headerColumns(line);
      if (header) {
        // Printed once, or again on later pages; either way it starts a fresh table.
        columns = header;
        last = null;
        return;
      }
      const active: Column[] | null = columns;
      if (!active || line.cells.every((c) => RULER.test(c.text))) return;

      const { text: cells, left } = cellsByRole(line, active);
      const dateText = cells.date?.trim() ?? '';
      if (!parseStatementDate(dateText, true)) {
        const money = (v: string | undefined) => parseStatementAmount(v) != null;
        if (money(cells.balance) && (money(cells.withdrawal) || money(cells.deposit))) {
          // Shaped like a transaction but undated: say so rather than lose it silently.
          warnings.push({ lineIndex: index, code: 'skippedLine', message: `A line with amounts had no date: "${line.text.slice(0, 80)}"` });
          last = null;
          return;
        }
        // A wrapped narration (with any reference overflow) continues the row above: narration
        // text, starting inside the narration column, and nothing outside narration/reference.
        // The PDF wraps a row across a page break too, with the page footer and the next
        // page's header block in between ("Page No .: 2" sits under Chq./Ref.No., hence
        // narration being required).
        const wrapped =
          cells.narration != null &&
          !money(cells.withdrawal) &&
          !money(cells.deposit) &&
          !money(cells.balance) &&
          Object.keys(cells).every((role) => role === 'narration' || role === 'reference') &&
          line.cells.every((c) => c.x >= narrationLeft - EDGE_TOLERANCE);
        if (last && wrapped && (!interrupted || line.page > lastPage)) {
          if (cells.narration) last.description = `${last.description}${cells.narration}`;
          if (cells.reference) last.reference = `${last.reference ?? ''}${cells.reference}`;
          interrupted = false;
          lastPage = line.page;
        } else if (last) {
          interrupted = true;
        }
        return;
      }

      const withdrawal = cells.withdrawal?.trim() || null;
      const deposit = cells.deposit?.trim() || null;
      if (!withdrawal && !deposit) {
        warnings.push({ lineIndex: index, code: 'skippedLine', message: `A dated line had no amount: "${line.text.slice(0, 80)}"` });
        last = null;
        return;
      }
      const row: RawStatementRow = {
        lineIndex: index,
        dateText,
        description: cells.narration?.trim() ?? '',
        debitText: withdrawal,
        creditText: deposit,
        balanceText: cells.balance?.trim() || null,
        reference: cells.reference?.trim() || null,
      };
      rows.push(row);
      last = row;
      interrupted = false;
      lastPage = line.page;
      if (left.narration != null) narrationLeft = Math.min(narrationLeft, left.narration);
    });

    // Narration codes are read once the (possibly wrapped) narration is complete.
    for (const row of rows) Object.assign(row, interpretHdfcNarration(row.description));

    if (!rows.length) warnings.push({ lineIndex: null, code: 'noTransactions', message: 'No transactions were found under the HDFC header.' });

    const top = firstLines(doc, 60);
    const digits = ACCOUNT.exec(top)?.[1]?.replace(/\D/g, '') ?? '';
    const period = PERIOD.exec(top);
    const from = period?.[1] ? parseStatementDate(period[1], true) : null;
    const to = period?.[2] ? parseStatementDate(period[2], true) : null;

    return {
      parserId: ID,
      bankName: 'HDFC Bank',
      accountLast4: digits.length >= 4 ? digits.slice(-4) : null,
      period: from && to && from <= to ? { from, to } : null,
      // HDFC prints dd/mm/yy throughout.
      dayFirst: true,
      openingBalance,
      closingBalance,
      rows,
      warnings,
    };
  },
};
