import { describe, expect, it } from 'vitest';

import { processStatement } from '@/domain/statementImport/pipeline';

import { StatementReadError } from './extractors';
import { readStatementFile } from './reader';
import { dateStylesOf, decodeXml, readXlsx, serialToDate, sharedStringsOf, XLSX_COLUMN_WIDTH } from './xlsx';

// ---------------------------------------------------------------------------
// A minimal zip writer, so the test exercises the real reader on real bytes
// ---------------------------------------------------------------------------

const crcTable = Array.from({ length: 256 }, (_, n) => {
  let c = n;
  for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});
const crc32 = (data: Uint8Array) => {
  let c = 0xffffffff;
  for (const byte of data) c = (crcTable[(c ^ byte) & 0xff] ?? 0) ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
};

async function deflateRaw(raw: Uint8Array): Promise<Uint8Array> {
  const stream = new Blob([raw.slice()]).stream().pipeThrough(new CompressionStream('deflate-raw'));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

async function zip(files: Record<string, string>): Promise<Uint8Array> {
  const chunks: Uint8Array[] = [];
  const central: Uint8Array[] = [];
  let offset = 0;
  for (const [name, text] of Object.entries(files)) {
    const raw = new TextEncoder().encode(text);
    const data = await deflateRaw(raw);
    const nameBytes = new TextEncoder().encode(name);
    const local = new DataView(new ArrayBuffer(30));
    local.setUint32(0, 0x04034b50, true);
    local.setUint16(8, 8, true);
    local.setUint32(14, crc32(raw), true);
    local.setUint32(18, data.length, true);
    local.setUint32(22, raw.length, true);
    local.setUint16(26, nameBytes.length, true);
    const entry = new DataView(new ArrayBuffer(46));
    entry.setUint32(0, 0x02014b50, true);
    entry.setUint16(10, 8, true);
    entry.setUint32(16, crc32(raw), true);
    entry.setUint32(20, data.length, true);
    entry.setUint32(24, raw.length, true);
    entry.setUint16(28, nameBytes.length, true);
    entry.setUint32(42, offset, true);
    chunks.push(new Uint8Array(local.buffer), nameBytes, data);
    central.push(new Uint8Array(entry.buffer), nameBytes);
    offset += 30 + nameBytes.length + data.length;
  }
  const size = central.reduce((n, c) => n + c.length, 0);
  const end = new DataView(new ArrayBuffer(22));
  end.setUint32(0, 0x06054b50, true);
  end.setUint16(8, Object.keys(files).length, true);
  end.setUint16(10, Object.keys(files).length, true);
  end.setUint32(12, size, true);
  end.setUint32(16, offset, true);
  const all = [...chunks, ...central, new Uint8Array(end.buffer)];
  const out = new Uint8Array(all.reduce((n, c) => n + c.length, 0));
  let at = 0;
  for (const c of all) {
    out.set(c, at);
    at += c.length;
  }
  return out;
}

// A synthetic HDFC-style download: shared strings, a rich-text string, an
// inline string, an entity, numeric amounts, and one date stored as a serial.
const SHARED = [
  'HDFC BANK Ltd.      Page No .:  1      Statement of accounts',
  'Date', 'Narration', 'Chq./Ref.No.', 'Value Dt', 'Withdrawal Amt.', 'Deposit Amt.', 'Closing Balance',
  '01/09/26',
  'UPI-SAMPLE STORE-store@okicici-ICIC0001234-612345678901-UPI',
  '0000612345678901',
];
const sharedXml =
  `<sst>${SHARED.map((s) => `<si><t xml:space="preserve">${s}</t></si>`).join('')}` +
  '<si><r><rPr><b/></rPr><t>UPI-TEA </t></r><r><t>&amp; SNACKS-tea@okaxis-UTIB0000001-612345678902-UPI</t></r><rPh><t>x</t></rPh></si></sst>';
const stylesXml =
  '<styleSheet><numFmts count="1"><numFmt numFmtId="164" formatCode="dd/mm/yyyy"/></numFmts>' +
  '<cellXfs count="3"><xf numFmtId="0"/><xf numFmtId="0"/><xf numFmtId="164"/></cellXfs></styleSheet>';
const s = (ref: string, index: number) => `<c r="${ref}" t="s"><v>${String(index)}</v></c>`;
const n = (ref: string, value: number, style = 1) => `<c r="${ref}" s="${String(style)}"><v>${String(value)}</v></c>`;
const sheetXml =
  '<worksheet><sheetData>' +
  `<row r="1">${s('A1', 0)}</row>` +
  '<row r="2"><c r="A2" t="inlineStr"><is><t>**********</t></is></c></row>' +
  `<row r="3">${['A', 'B', 'C', 'D', 'E', 'F', 'G'].map((col, i) => s(`${col}3`, i + 1)).join('')}</row>` +
  `<row r="5">${s('A5', 8)}${s('B5', 9)}${s('C5', 10)}${s('D5', 8)}${n('E5', 2900)}${n('G5', 47100)}</row>` +
  // Date as an Excel serial with a date style; a decimal amount; an empty Withdrawal cell.
  `<row r="6">${n('A6', 46266, 2)}${s('B6', 11)}<c r="C6" t="str"><v>0000612345678902</v></c>${n('D6', 46266, 2)}<c r="E6" s="1"/>${n('F6', 120.5)}${n('G6', 47220.5)}</row>` +
  '</sheetData></worksheet>';
const workbookXml = '<workbook><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>';
const relsXml = '<Relationships><Relationship Id="rId1" Type="worksheet" Target="worksheets/sheet1.xml"/></Relationships>';

const XLSX = await zip({
  '[Content_Types].xml': '<Types/>',
  'xl/workbook.xml': workbookXml,
  'xl/_rels/workbook.xml.rels': relsXml,
  'xl/sharedStrings.xml': sharedXml,
  'xl/styles.xml': stylesXml,
  'xl/worksheets/sheet1.xml': sheetXml,
});

describe('xlsx reader', () => {
  it('turns the first worksheet into column-positioned lines', async () => {
    const doc = await readXlsx(XLSX);
    expect(doc.source).toBe('spreadsheet');
    expect(doc.lines).toHaveLength(5);
    const header = doc.lines[2];
    expect(header?.cells.map((c) => c.text)).toEqual(['Date', 'Narration', 'Chq./Ref.No.', 'Value Dt', 'Withdrawal Amt.', 'Deposit Amt.', 'Closing Balance']);
    expect(header?.cells.map((c) => c.x / XLSX_COLUMN_WIDTH)).toEqual([0, 1, 2, 3, 4, 5, 6]);
    const second = doc.lines[4];
    expect(second?.cells.map((c) => [c.x / XLSX_COLUMN_WIDTH, c.text])).toEqual([
      [0, '01/09/2026'],
      [1, 'UPI-TEA & SNACKS-tea@okaxis-UTIB0000001-612345678902-UPI'],
      [2, '0000612345678902'],
      [3, '01/09/2026'],
      [5, '120.50'],
      [6, '47220.50'],
    ]);
  });

  it('feeds the HDFC parser like any other document', async () => {
    const doc = await readXlsx(XLSX);
    const account = { id: 'a', userId: 'u', bankName: 'HDFC Bank', nickname: 'Main', last4: null, openingBalance: 0, isActive: true, createdAt: null };
    const statement = processStatement({ doc, statementId: 's', fileName: 's.xlsx', account, accounts: [account], categories: [] });
    expect(statement.parserId).toBe('hdfc-bank');
    expect(statement.transactions.map((t) => [t.transactionDate, t.transactionType, t.amount, t.balance, t.counterparty])).toEqual([
      ['2026-09-01', 'debit', 2900, 47100, 'SAMPLE STORE'],
      ['2026-09-01', 'credit', 120.5, 47220.5, 'TEA & SNACKS'],
    ]);
  });

  it('decodes XML, shared strings, date styles and serials', () => {
    expect(decodeXml('A &amp; B &lt;x&gt; &#8377; &#x20B9;')).toBe('A & B <x> ₹ ₹');
    expect(sharedStringsOf(null)).toEqual([]);
    expect([...dateStylesOf(stylesXml)]).toEqual([2]);
    expect(serialToDate(46266)).toBe('01/09/2026');
    expect(serialToDate(44804, true)).toBe('01/09/2026');
  });

  it('rejects files that are not workbooks', async () => {
    await expect(readXlsx(new TextEncoder().encode('not a zip at all'))).rejects.toBeInstanceOf(StatementReadError);
    await expect(readXlsx(await zip({ 'readme.txt': 'hello' }))).rejects.toMatchObject({ code: 'unsupportedFormat' });
  });
});

describe('statement file types', () => {
  const account = { id: 'a', userId: 'u', bankName: 'HDFC Bank', nickname: 'Main', last4: null, openingBalance: 0, isActive: true, createdAt: null };
  const read = (bytes: Uint8Array, name: string) =>
    readStatementFile({ file: new File([bytes.slice()], name), account, accounts: [account], categories: [] });

  it('reads an .xlsx statement end to end', async () => {
    const statement = await read(XLSX, 'Account statement.xlsx');
    expect(statement.transactions).toHaveLength(2);
    expect(statement.id).toMatch(/^[0-9a-f]{24}$/);
  });

  it('explains old .xls and password-protected spreadsheets instead of failing silently', async () => {
    const ole = new Uint8Array([0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1, 0, 0, 0, 0]);
    await expect(read(ole, 'statement.xls')).rejects.toMatchObject({ code: 'unsupportedFormat' });
    await expect(read(new TextEncoder().encode('hello'), 'notes.txt')).rejects.toMatchObject({ code: 'notPdf' });
  });
});
