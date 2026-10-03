/**
 * A small, dependency-free .xlsx reader for statement downloads (HDFC
 * NetBanking offers the statement as a spreadsheet). It reads only what a
 * statement needs — the first worksheet's cell text — and turns it into the
 * same ExtractedDocument the PDF reader produces: one line per row, one cell
 * per column, positioned by column so header-driven parsers line up exactly.
 *
 * An .xlsx file is a zip of XML files. The zip directory is parsed here and
 * entries are inflated with the platform's DecompressionStream, so no
 * spreadsheet library is shipped. Runs on the device, like the PDF reader.
 */
import type { ExtractedDocument, TextCell, TextLine } from '@/domain/statementImport/model';

import { StatementReadError, type TextExtractor } from './extractors';

/** Horizontal slot per spreadsheet column; cells are narrower so neighbours never overlap. */
export const XLSX_COLUMN_WIDTH = 100;
const CELL_WIDTH = 90;
const ROW_HEIGHT = 12;
/** Guards against zip bombs: a statement's XML is a few hundred KB at most. */
const MAX_ENTRY_BYTES = 30 * 1024 * 1024;

// ---------------------------------------------------------------------------
// Zip
// ---------------------------------------------------------------------------

type ZipEntry = { name: string; method: number; compressedSize: number; size: number; localOffset: number };

const u16 = (b: Uint8Array, at: number) => (b[at] ?? 0) | ((b[at + 1] ?? 0) << 8);
const u32 = (b: Uint8Array, at: number) => (u16(b, at) | (u16(b, at + 2) << 16)) >>> 0;

function zipEntries(bytes: Uint8Array): Map<string, ZipEntry> {
  // End of central directory: signature 0x06054b50, within the last 64 KB + 22 bytes.
  let eocd = -1;
  for (let i = bytes.length - 22; i >= Math.max(0, bytes.length - 65_557); i -= 1) {
    if (u32(bytes, i) === 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw new StatementReadError('unsupportedFormat', 'That spreadsheet could not be opened.');
  const count = u16(bytes, eocd + 10);
  let at = u32(bytes, eocd + 16);
  const entries = new Map<string, ZipEntry>();
  for (let i = 0; i < count && u32(bytes, at) === 0x02014b50; i += 1) {
    const nameLength = u16(bytes, at + 28);
    const name = new TextDecoder().decode(bytes.subarray(at + 46, at + 46 + nameLength));
    entries.set(name, {
      name,
      method: u16(bytes, at + 10),
      compressedSize: u32(bytes, at + 20),
      size: u32(bytes, at + 24),
      localOffset: u32(bytes, at + 42),
    });
    at += 46 + nameLength + u16(bytes, at + 30) + u16(bytes, at + 32);
  }
  return entries;
}

async function inflate(data: Uint8Array): Promise<Uint8Array> {
  // slice() copies into a plain ArrayBuffer, which Blob requires.
  const stream = new Blob([data.slice()]).stream().pipeThrough(new DecompressionStream('deflate-raw'));
  const reader = stream.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.length;
    if (total > MAX_ENTRY_BYTES) {
      await reader.cancel();
      throw new StatementReadError('tooLarge', 'That spreadsheet is too large to be one statement.');
    }
    chunks.push(value);
  }
  const out = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.length;
  }
  return out;
}

async function readEntry(bytes: Uint8Array, entry: ZipEntry): Promise<string> {
  if (entry.size > MAX_ENTRY_BYTES) throw new StatementReadError('tooLarge', 'That spreadsheet is too large to be one statement.');
  const at = entry.localOffset;
  if (u32(bytes, at) !== 0x04034b50) throw new StatementReadError('unsupportedFormat', 'That spreadsheet is damaged.');
  const start = at + 30 + u16(bytes, at + 26) + u16(bytes, at + 28);
  const data = bytes.subarray(start, start + entry.compressedSize);
  if (entry.method === 0) return new TextDecoder().decode(data);
  if (entry.method === 8) return new TextDecoder().decode(await inflate(data));
  throw new StatementReadError('unsupportedFormat', 'That spreadsheet uses an unsupported compression.');
}

// ---------------------------------------------------------------------------
// Spreadsheet XML
// ---------------------------------------------------------------------------

const ENTITIES: Record<string, string> = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'" };

export function decodeXml(text: string): string {
  return text.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (whole, code: string) => {
    if (code.startsWith('#x') || code.startsWith('#X')) return String.fromCodePoint(parseInt(code.slice(2), 16));
    if (code.startsWith('#')) return String.fromCodePoint(Number(code.slice(1)));
    return ENTITIES[code.toLowerCase()] ?? whole;
  });
}

/** All <t> runs of a string item (rich text included), phonetic hints excluded. */
function textRuns(xml: string): string {
  return [...xml.replace(/<rPh\b[\s\S]*?<\/rPh>/g, '').matchAll(/<t(?:\s[^>]*)?>([\s\S]*?)<\/t>/g)].map((m) => decodeXml(m[1] ?? '')).join('');
}

export function sharedStringsOf(xml: string | null): string[] {
  if (!xml) return [];
  return [...xml.matchAll(/<si>([\s\S]*?)<\/si>/g)].map((m) => textRuns(m[1] ?? ''));
}

const BUILTIN_DATE_FORMATS = new Set([14, 15, 16, 17, 18, 19, 20, 21, 22, 27, 30, 36, 45, 46, 47, 50, 57]);

/** Which cell style indexes are dates, from styles.xml. */
export function dateStylesOf(xml: string | null): Set<number> {
  const dates = new Set<number>();
  if (!xml) return dates;
  const custom = new Map<number, string>();
  for (const m of xml.matchAll(/<numFmt\s[^>]*numFmtId="(\d+)"[^>]*formatCode="([^"]*)"/g)) custom.set(Number(m[1]), decodeXml(m[2] ?? ''));
  const cellXfs = /<cellXfs[^>]*>([\s\S]*?)<\/cellXfs>/.exec(xml)?.[1] ?? '';
  [...cellXfs.matchAll(/<xf\s([^>]*?)\/?>/g)].forEach((m, index) => {
    const id = Number(/numFmtId="(\d+)"/.exec(m[1] ?? '')?.[1] ?? 0);
    const code = custom.get(id);
    // A custom format is a date when, outside quoted text and [colour] blocks, it uses d, m or y.
    const isDate = BUILTIN_DATE_FORMATS.has(id) || (code != null && /[dmy]/i.test(code.replace(/"[^"]*"|\[[^\]]*\]/g, '')));
    if (isDate) dates.add(index);
  });
  return dates;
}

const pad = (n: number) => String(n).padStart(2, '0');

/** Excel serial day → dd/mm/yyyy (1900 date system, or 1904 when the workbook says so). */
export function serialToDate(serial: number, date1904 = false): string {
  const epoch = date1904 ? Date.UTC(1904, 0, 1) : Date.UTC(1899, 11, 30);
  const date = new Date(epoch + Math.round(serial * 86_400_000));
  return `${pad(date.getUTCDate())}/${pad(date.getUTCMonth() + 1)}/${String(date.getUTCFullYear())}`;
}

/** Money is kept as printed would show it: whole numbers stay whole, others get two decimals. */
function numberText(value: number): string {
  if (Number.isInteger(value)) return String(value);
  const cents = value * 100;
  return Math.abs(cents - Math.round(cents)) < 1e-6 ? value.toFixed(2) : String(value);
}

function columnIndex(ref: string): number {
  let index = 0;
  for (const ch of ref.replace(/\d+$/, '')) index = index * 26 + (ch.charCodeAt(0) - 64);
  return index - 1;
}

/** One worksheet's XML → positioned lines. */
export function sheetToLines(
  sheetXml: string,
  shared: readonly string[],
  dateStyles: ReadonlySet<number> = new Set(),
  date1904 = false,
): TextLine[] {
  const lines: TextLine[] = [];
  for (const row of sheetXml.matchAll(/<row\b([^>]*)>([\s\S]*?)<\/row>/g)) {
    const rowNumber = Number(/\br="(\d+)"/.exec(row[1] ?? '')?.[1] ?? lines.length + 1);
    const cells: TextCell[] = [];
    for (const cell of (row[2] ?? '').matchAll(/<c\b([^>]*?)(?:\/>|>([\s\S]*?)<\/c>)/g)) {
      const attrs = cell[1] ?? '';
      const inner = cell[2] ?? '';
      const ref = /\br="([A-Z]+\d*)"/.exec(attrs)?.[1];
      if (!ref) continue;
      const type = /\bt="(\w+)"/.exec(attrs)?.[1] ?? 'n';
      const style = Number(/\bs="(\d+)"/.exec(attrs)?.[1] ?? -1);
      const raw = /<v>([\s\S]*?)<\/v>/.exec(inner)?.[1];
      let text: string | null = null;
      if (type === 's' && raw != null) text = shared[Number(raw)] ?? null;
      else if (type === 'inlineStr') text = textRuns(/<is>([\s\S]*?)<\/is>/.exec(inner)?.[1] ?? '');
      else if (type === 'str' || type === 'e') text = raw != null ? decodeXml(raw) : null;
      else if (type === 'b') text = raw === '1' ? 'TRUE' : 'FALSE';
      else if (raw != null && raw !== '') {
        const value = Number(raw);
        if (Number.isFinite(value)) text = dateStyles.has(style) ? serialToDate(value, date1904) : numberText(value);
      }
      const clean = text?.replace(/\s+/g, ' ').trim();
      if (!clean) continue;
      cells.push({ text: clean, x: columnIndex(ref) * XLSX_COLUMN_WIDTH, width: CELL_WIDTH });
    }
    if (!cells.length) continue;
    cells.sort((a, b) => a.x - b.x);
    lines.push({ page: 1, y: -rowNumber * ROW_HEIGHT, cells, text: cells.map((c) => c.text).join(' ') });
  }
  return lines;
}

/** The first worksheet, in the workbook's own order. */
function firstSheetPath(workbook: string, rels: string | null): string {
  const rid = /<sheet\b[^>]*\br:id="([^"]+)"/.exec(workbook)?.[1];
  const target = rid && rels ? new RegExp(`<Relationship\\b[^>]*Id="${rid}"[^>]*Target="([^"]+)"`).exec(rels)?.[1] : undefined;
  const alt = rid && rels ? new RegExp(`<Relationship\\b[^>]*Target="([^"]+)"[^>]*Id="${rid}"`).exec(rels)?.[1] : undefined;
  const path = target ?? alt ?? 'worksheets/sheet1.xml';
  return path.startsWith('/') ? path.slice(1) : `xl/${path.replace(/^\.\//, '')}`;
}

export async function readXlsx(bytes: Uint8Array): Promise<ExtractedDocument> {
  const entries = zipEntries(bytes);
  const read = async (name: string) => {
    const entry = entries.get(name);
    return entry ? readEntry(bytes, entry) : null;
  };
  const workbook = await read('xl/workbook.xml');
  if (!workbook) throw new StatementReadError('unsupportedFormat', 'That file is not an Excel workbook.');
  const sheetPath = firstSheetPath(workbook, await read('xl/_rels/workbook.xml.rels'));
  const sheet = await read(sheetPath);
  if (!sheet) throw new StatementReadError('unsupportedFormat', 'That workbook has no worksheet.');
  const date1904 = /<workbookPr\b[^>]*date1904="(1|true)"/.test(workbook);
  const lines = sheetToLines(sheet, sharedStringsOf(await read('xl/sharedStrings.xml')), dateStylesOf(await read('xl/styles.xml')), date1904);
  return { pageCount: 1, lines, source: 'spreadsheet' };
}

export const xlsxExtractor: TextExtractor = {
  id: 'xlsx',
  extract: (data) => readXlsx(data),
};
