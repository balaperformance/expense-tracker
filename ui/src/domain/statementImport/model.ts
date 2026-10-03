/**
 * Bank statement import — the bank-independent data model.
 *
 * The pipeline, every stage a pure function of the one before it:
 *
 *   PDF bytes ──(TextExtractor)──▶ ExtractedDocument     positioned text lines
 *             ──(StatementParser)─▶ ParsedStatement       one bank's rows, in its own words
 *             ──(normalizeStatement)▶ NormalizedTransaction[]   one common shape
 *             ──(classify, markDuplicates)▶ review ──▶ ImportPlan ──▶ Supabase
 *
 * Only the extractor touches a browser API and only the importer touches the
 * database, so everything in this folder can be ported to Dart as-is.
 */
import type { IsoDate } from '@/lib/dates';

import type { TransferTarget } from '../treatment';

export type TransactionType = 'debit' | 'credit';

/**
 * What a movement means, which decides where it is stored (see treatment.ts):
 *   expense       → expenses (+ its ledger debit)
 *   income        → income   (+ its ledger credit)
 *   refund        → ledger credit only — money back is not earnings
 *   transfer      → own-account moves (both legs), card bills, cash — never spending
 *   loan          → money out: lent, owed back — not spending;
 *                   money in: a loan repaid — not income
 *   reimbursement → money in that pays back a purchase made for someone — not income
 */
export type TransactionKind = 'expense' | 'income' | 'refund' | 'transfer' | 'loan' | 'reimbursement';

/**
 * How the money moved, in bank-neutral terms. A bank parser that understands
 * its bank's narration codes (HDFC's "NWD-", "ATW-", "EMI …") maps them to a
 * channel; classification then works from the channel, never the bank's codes.
 */
export type TransactionChannel =
  | 'upi'
  | 'card'
  | 'atm'
  | 'neft'
  | 'imps'
  | 'rtgs'
  | 'ach'
  | 'cheque'
  | 'cash'
  | 'loan'
  | 'charges'
  | 'interest'
  | 'reversal'
  | 'cardBill'
  | 'internal';

// ---------------------------------------------------------------------------
// Extraction
// ---------------------------------------------------------------------------

/** One run of text on a line, with its horizontal position in PDF points. */
export type TextCell = { text: string; x: number; width: number };

/** One visual line of a page, cells left to right. */
export type TextLine = { page: number; y: number; cells: TextCell[]; text: string };

export type ExtractionSource = 'pdf-text' | 'spreadsheet' | 'ocr';

export type ExtractedDocument = {
  pageCount: number;
  lines: TextLine[];
  source: ExtractionSource;
};

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

/**
 * A statement row exactly as the bank printed it. Parsers only locate and
 * split text; turning it into dates, amounts and directions is shared work.
 */
export type RawStatementRow = {
  /** Index into ExtractedDocument.lines, for tracing a row back to the page. */
  lineIndex: number;
  dateText: string;
  description: string;
  /** Separate withdrawal / deposit columns … */
  debitText?: string | null;
  creditText?: string | null;
  /** … or one amount column, possibly signed or marked Dr / Cr. */
  amountText?: string | null;
  balanceText?: string | null;
  reference?: string | null;
  /** Set when the layout itself states the direction (e.g. a "Dr/Cr" column). */
  directionHint?: TransactionType | null;
  /** The payee / payer named in the narration, when the parser can pick it out. */
  counterparty?: string | null;
  channel?: TransactionChannel | null;
  /** Time of day as printed, when the statement has one ("10:59 AM"). */
  timeText?: string | null;
  /** What the statement calls a note on the row — for the expense's Notes. Null: none printed. */
  notes?: string | null;
  /** The statement's own tags on the row, without the "#". */
  tags?: readonly string[];
  /** The other side's UPI ID, when printed. */
  upiId?: string | null;
  /**
   * The account the row says paid or received the money, as printed ("HDFC Bank - 59").
   * Set by statements that cover several accounts (see ParsedStatement.accountPerRow).
   */
  sourceAccount?: string | null;
  /** An account the narration names as the other side ("Self transfer to HDFC Bank - 59"). */
  counterpartyAccount?: string | null;
};

export type StatementWarningCode =
  | 'unparseableDate'
  | 'unparseableAmount'
  | 'unknownDirection'
  | 'balanceMismatch'
  | 'skippedLine'
  | 'noTransactions';

export type StatementWarning = { lineIndex: number | null; code: StatementWarningCode; message: string };

export type StatementPeriod = { from: IsoDate; to: IsoDate };

export type ParsedStatement = {
  parserId: string;
  bankName: string | null;
  /** Last digits of the account number, when the statement prints them. */
  accountLast4: string | null;
  period: StatementPeriod | null;
  /**
   * Whether numeric dates are day-first. A bank parser knows this for its bank;
   * null lets the normaliser decide from the dates themselves.
   */
  dayFirst: boolean | null;
  openingBalance: number | null;
  closingBalance: number | null;
  rows: RawStatementRow[];
  warnings: StatementWarning[];
  /**
   * The statement covers several of the user's accounts (a payment app's UPI
   * statement) and names each row's own in sourceAccount: rows are matched to
   * those accounts, never all put in the account chosen for the upload.
   */
  accountPerRow?: boolean;
};

// ---------------------------------------------------------------------------
// The common transaction
// ---------------------------------------------------------------------------

export type CategorySource = 'rule' | 'fallback' | 'user' | 'assistant' | 'none';

/** Why an incoming row is (probably) already recorded. */
export type DuplicateMatch =
  /** The same row in an earlier statement of this session — overlapping periods. */
  | { type: 'overlap'; ofId: string }
  /**
   * Already in the ledger: same account, date, amount and direction — or the
   * same reference (a UPI reference number), whatever the date.
   */
  | { type: 'existing'; strength: 'exact' | 'likely'; existingLabel: string; sameReference?: boolean; existingDate?: IsoDate }
  /** An entry within a couple of days with the same amount — advisory only. */
  | { type: 'nearby'; existingLabel: string; existingDate: IsoDate };

export type NormalizedTransaction = {
  /** Stable within a session: `${sourceStatementId}:${row}`. */
  id: string;
  transactionDate: IsoDate;
  /** Cleaned for display and storage. */
  description: string;
  /** Exactly as printed, kept for matching and for the user to check against. */
  rawDescription: string;
  /** Always positive; transactionType carries the direction. */
  amount: number;
  transactionType: TransactionType;
  /** The running balance printed after this row, if any. */
  balance: number | null;
  kind: TransactionKind;
  /** A category *name* for expenses, a source label for income — resolved to the user's own later. */
  category: string | null;
  categorySource: CategorySource;
  categoryReason: string | null;
  bankAccountId: string;
  sourceStatementId: string;
  reference: string | null;
  /** Payee / payer from the narration (stored as the expense's merchant); null when unknown. */
  counterparty: string | null;
  channel: TransactionChannel | null;
  /** The user's credit card this debit pays, when recognised; written as that card's bill payment. */
  creditCardId?: string | null;
  /** For a transfer: the other side, when the narration says (your account's digits, a card, an ATM). */
  transferTarget?: TransferTarget | null;
  /** "HH:mm", when the statement printed a time. */
  transactionTime?: string | null;
  /** The statement's note on the row (undefined: the statement has no notes at all). */
  notes?: string | null;
  /** The statement's own tags on the row. */
  tags?: readonly string[];
  upiId?: string | null;
  /** The account the statement names for this row, as printed (multi-account statements only). */
  sourceAccount?: string | null;
  /**
   * How bankAccountId was decided on a multi-account statement: 'matched' to
   * the printed account, 'unmatched' (bankAccountId is '' until the user
   * chooses) or 'chosen' by the user in review.
   */
  accountStatus?: 'matched' | 'unmatched' | 'chosen';
  /** An account the narration names as the other side, as printed. */
  counterpartyAccount?: string | null;
  /** 0–1: how sure the reader is about date, amount and direction. */
  confidence: number;
  /** Plain-language reasons the confidence is below 1. */
  issues: string[];
  /** Deterministic identity — see duplicates.ts. */
  fingerprint: string;
  duplicate: DuplicateMatch | null;
};

/** A movement already stored for the account, as the duplicate check sees it. */
export type ExistingMovement = {
  accountId: string;
  date: IsoDate;
  amount: number;
  direction: TransactionType;
  description: string | null;
  /** Set when the recorded debit is a credit-card bill payment. */
  creditCardId?: string | null;
  /** The reference the movement was recorded with (migration 007), if any. */
  reference?: string | null;
  /** The other side's UPI ID it was recorded with — set for rows from a UPI statement. */
  upiId?: string | null;
};

/** What a statement printed about a movement beyond its figures — kept on its ledger row (migration 007). */
export type MovementDetails = {
  reference: string | null;
  upiId: string | null;
  /** "HH:mm". */
  time: string | null;
};

export type StatementPeriodKind = 'weekly' | 'fortnightly' | 'monthly' | 'custom';

/** How confident a row must be before it is pre-selected for import. */
export const AUTO_SELECT_CONFIDENCE = 0.6;
