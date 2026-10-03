/**
 * Text extraction — the only part of the statement reader that needs a
 * browser. Everything runs on this device: the PDF is never uploaded and
 * never sent to an AI service.
 *
 *   pdfTextExtractor   text-based PDFs (what banks email), via PDF.js
 *   xlsxExtractor      Excel downloads (xlsx.ts)
 *   OCR_EXTRACTOR      scanned / image-only PDFs — reserved, see below
 */
import workerUrl from 'pdfjs-dist/build/pdf.worker.min.mjs?url';

import { groupFragments, type TextFragment } from '@/domain/statementImport/layout';
import type { ExtractedDocument, TextLine } from '@/domain/statementImport/model';

export type ExtractOptions = {
  password?: string;
  onPage?: (page: number, pageCount: number) => void;
};

export type TextExtractor = {
  id: string;
  extract: (data: Uint8Array, options: ExtractOptions) => Promise<ExtractedDocument>;
};

export type StatementReadErrorCode =
  | 'passwordRequired'
  | 'passwordIncorrect'
  | 'notPdf'
  | 'unsupportedFormat'
  | 'scanned'
  | 'tooLarge'
  | 'failed';

export class StatementReadError extends Error {
  override readonly name = 'StatementReadError';
  constructor(
    readonly code: StatementReadErrorCode,
    message: string,
  ) {
    super(message);
  }
}

/** Statements run to a few pages; anything far bigger is not one. */
export const MAX_STATEMENT_BYTES = 20 * 1024 * 1024;
export const MAX_STATEMENT_PAGES = 200;

type PdfJs = typeof import('pdfjs-dist');

let pdfjs: Promise<PdfJs> | null = null;

/** Loaded only when a statement is opened, so it never weighs on app start-up. */
function loadPdfJs(): Promise<PdfJs> {
  pdfjs ??= import('pdfjs-dist').then((lib) => {
    lib.GlobalWorkerOptions.workerSrc = workerUrl;
    return lib;
  });
  return pdfjs;
}

function readError(lib: PdfJs, error: unknown): StatementReadError {
  if (error instanceof lib.PasswordException) {
    return error.code === lib.PasswordResponses.INCORRECT_PASSWORD
      ? new StatementReadError('passwordIncorrect', 'That password did not open the statement.')
      : new StatementReadError('passwordRequired', 'This statement is password protected.');
  }
  if (error instanceof lib.InvalidPDFException) {
    return new StatementReadError('notPdf', 'That file is not a readable PDF.');
  }
  return new StatementReadError('failed', 'The statement could not be read.');
}

export const pdfTextExtractor: TextExtractor = {
  id: 'pdf-text',
  async extract(data, { password, onPage }) {
    const lib = await loadPdfJs();
    const task = lib.getDocument({
      data,
      password,
      // Text only: no fonts, images or WebAssembly decoders are needed to read words and positions.
      disableFontFace: true,
      useSystemFonts: false,
      useWasm: false,
      enableXfa: false,
      isOffscreenCanvasSupported: false,
    });
    let pdf;
    try {
      pdf = await task.promise;
    } catch (error) {
      await task.destroy();
      throw readError(lib, error);
    }
    try {
      if (pdf.numPages > MAX_STATEMENT_PAGES) {
        throw new StatementReadError('tooLarge', `That PDF has ${String(pdf.numPages)} pages — too many for one statement.`);
      }
      const lines: TextLine[] = [];
      for (let number = 1; number <= pdf.numPages; number += 1) {
        const page = await pdf.getPage(number);
        const content = await page.getTextContent();
        const fragments: TextFragment[] = [];
        for (const item of content.items) {
          if (!('str' in item) || !item.str) continue;
          const [a = 0, b = 0, c = 0, d = 0, x = 0, y = 0] = item.transform as number[];
          fragments.push({ text: item.str, x, y, width: item.width || Math.hypot(a, b) * item.str.length * 0.5, height: item.height || Math.hypot(c, d) });
        }
        lines.push(...groupFragments(fragments, number));
        page.cleanup();
        onPage?.(number, pdf.numPages);
      }
      return { pageCount: pdf.numPages, lines, source: 'pdf-text' };
    } catch (error) {
      throw error instanceof StatementReadError ? error : readError(lib, error);
    } finally {
      // Tears down the document and its worker port.
      await task.destroy();
    }
  },
};

/**
 * Scanned statements: reserved for an OCR extractor that renders each page
 * with PDF.js and reads it with the on-device Tesseract engine the receipt
 * scanner already uses, producing the same ExtractedDocument (source 'ocr').
 * Not built yet — bank statements are almost always text PDFs, and the real
 * samples will show whether it is needed.
 */
export const OCR_EXTRACTOR: TextExtractor | null = null;

/** Too little text to be a text-layer statement: most likely a scan. */
export function looksScanned(doc: ExtractedDocument): boolean {
  const characters = doc.lines.reduce((sum, line) => sum + line.text.replace(/\s/g, '').length, 0);
  return characters < 40 * Math.max(1, doc.pageCount) * 0.25;
}
