/**
 * StatementReader: a statement file (PDF or .xlsx) in, a processed statement out.
 *
 *   file → (detect type) → TextExtractor → processStatement → ProcessedStatement
 *
 * Nothing leaves the device and nothing is written.
 */
import type { BankAccount, CreditCard, ExpenseCategory } from '@/domain/models';
import { processStatement, type ProcessedStatement } from '@/domain/statementImport/pipeline';

import { looksScanned, MAX_STATEMENT_BYTES, OCR_EXTRACTOR, pdfTextExtractor, StatementReadError } from './extractors';
import { xlsxExtractor } from './xlsx';

export type ReadStage = 'opening' | 'extracting' | 'parsing';
export type ReadProgress = { stage: ReadStage; page?: number; pageCount?: number };

/**
 * A statement's identity: the SHA-256 of its bytes. The same file added twice
 * in one session is recognised as such.
 */
export async function statementIdOf(bytes: ArrayBuffer): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return [...new Uint8Array(digest)]
    .slice(0, 12)
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

type FileKind = 'pdf' | 'xlsx' | 'legacyOffice' | 'unknown';

/** Decided by the bytes, not the file name. */
function kindOf(bytes: ArrayBuffer): FileKind {
  const head = new Uint8Array(bytes.slice(0, 1024));
  if (head[0] === 0x50 && head[1] === 0x4b && head[2] === 0x03 && head[3] === 0x04) return 'xlsx';
  // OLE compound file: an old .xls, or any password-protected Office file.
  if (head[0] === 0xd0 && head[1] === 0xcf && head[2] === 0x11 && head[3] === 0xe0) return 'legacyOffice';
  // "%PDF" may follow a little leading junk, which readers tolerate.
  for (let i = 0; i < head.length - 3; i += 1) {
    if (head[i] === 0x25 && head[i + 1] === 0x50 && head[i + 2] === 0x44 && head[i + 3] === 0x46) return 'pdf';
  }
  return 'unknown';
}

export async function readStatementFile({
  file,
  password,
  account,
  accounts,
  categories,
  cards = [],
  onProgress,
}: {
  file: File;
  password?: string;
  account: BankAccount;
  accounts: readonly BankAccount[];
  categories: readonly ExpenseCategory[];
  /** The user's credit cards, so a bill paid to one is recognised and linked, not imported as spending. */
  cards?: readonly CreditCard[];
  onProgress?: (progress: ReadProgress) => void;
}): Promise<ProcessedStatement> {
  onProgress?.({ stage: 'opening' });
  if (file.size > MAX_STATEMENT_BYTES) {
    throw new StatementReadError('tooLarge', 'That file is larger than 20 MB — too big for one statement.');
  }
  const bytes = await file.arrayBuffer();
  const kind = kindOf(bytes);
  if (kind === 'legacyOffice') {
    throw new StatementReadError(
      'unsupportedFormat',
      'This is an older .xls file or a password-protected spreadsheet. Open it in Excel and save it as .xlsx without a password, or download the statement as a PDF.',
    );
  }
  if (kind === 'unknown') {
    throw new StatementReadError('notPdf', 'That file is not a PDF or an Excel (.xlsx) statement.');
  }
  const statementId = await statementIdOf(bytes);

  const onPage = (page: number, pageCount: number) => onProgress?.({ stage: 'extracting', page, pageCount });
  // PDF.js takes ownership of the buffer it is given; hand it a copy so a retry can reuse the bytes.
  const extractor = kind === 'xlsx' ? xlsxExtractor : pdfTextExtractor;
  let doc = await extractor.extract(new Uint8Array(bytes.slice(0)), { password, onPage });
  if (kind === 'pdf' && looksScanned(doc)) {
    if (!OCR_EXTRACTOR) {
      throw new StatementReadError(
        'scanned',
        'This PDF is a scanned image with no readable text. Download the statement from net banking as a PDF instead.',
      );
    }
    doc = await OCR_EXTRACTOR.extract(new Uint8Array(bytes.slice(0)), { password, onPage });
  }

  onProgress?.({ stage: 'parsing' });
  return processStatement({ doc, statementId, fileName: file.name, account, accounts, categories, cards });
}
