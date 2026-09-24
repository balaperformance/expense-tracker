/**
 * Renderers for an [ExportDataset].
 *
 * CSV is a port of `csv_export_service.dart`, including its spreadsheet
 * formula-injection guard. The PDF is produced by the browser's own print
 * engine from a self-contained HTML document ("Save as PDF"), which keeps a
 * PDF library out of the bundle and renders with the same typography.
 */
import { timestamp } from '@/lib/format';

import type { ExportCell, ExportDataset } from './model';

const FORMULA_LEADERS = '=+-@\t\r';

function csvValue(cellValue: ExportCell): string {
  if (cellValue.raw == null) return cellValue.text;
  switch (cellValue.kind) {
    case 'money':
      return cellValue.raw.toFixed(2);
    case 'count':
      return cellValue.raw.toFixed(0);
    case 'percent':
      return cellValue.raw.toFixed(4);
    default:
      return cellValue.text;
  }
}

function csvEscape(value: string): string {
  let text = value.replace(/\r\n/g, ' ').replace(/\n/g, ' ');
  const risky = text.length > 0 && FORMULA_LEADERS.includes(text[0] ?? '') && Number.isNaN(Number(text));
  if (risky) text = `'${text}`;
  const needsQuotes = risky || text.includes(',') || text.includes('"') || text.trim() !== text;
  return needsQuotes ? `"${text.replace(/"/g, '""')}"` : text;
}

export function renderCsv(dataset: ExportDataset): string {
  const out: string[] = [];
  const row = (cells: string[]) => out.push(cells.map(csvEscape).join(','));
  const gap = () => out.push('');

  row([dataset.title]);
  if (dataset.subtitle) row([dataset.subtitle]);
  row(['Period', dataset.periodLabel]);
  row(['Generated', timestamp(dataset.generatedAt)]);

  if (dataset.summary.length) {
    gap();
    for (const item of dataset.summary) row([item.label, item.value]);
  }

  for (const section of dataset.sections) {
    gap();
    row([section.title]);
    if (section.note) row([section.note]);
    if (!section.rows.length) {
      row([section.emptyMessage]);
      continue;
    }
    row(section.columns.map((c) => c.label));
    for (const cells of section.rows) row(cells.map(csvValue));
    if (section.totalRow) row(section.totalRow.map(csvValue));
  }

  if (dataset.footnote) {
    gap();
    row([dataset.footnote]);
  }
  return `${out.join('\r\n')}\r\n`;
}

const escapeHtml = (value: string) =>
  value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

/** A print-ready document; the page is A4 with the app's serif headings. */
export function renderPrintableHtml(dataset: ExportDataset, appName: string): string {
  const summary = dataset.summary
    .map(
      (item) =>
        `<div class="kpi${item.emphasis ? ' kpi--em' : ''}"><span>${escapeHtml(item.label)}</span><strong>${escapeHtml(item.value)}</strong></div>`,
    )
    .join('');

  const sections = dataset.sections
    .map((section) => {
      const widths = section.columns.reduce((s, c) => s + c.width, 0);
      const head = section.columns
        .map(
          (c) =>
            `<th style="width:${((c.width / widths) * 100).toFixed(1)}%" class="${c.align === 'right' ? 'r' : ''}">${escapeHtml(c.label)}</th>`,
        )
        .join('');
      const cells = (row: ExportCell[], tag: 'td' | 'th') =>
        row
          .map((value, i) => `<${tag} class="${section.columns[i]?.align === 'right' ? 'r' : ''}">${escapeHtml(value.text)}</${tag}>`)
          .join('');
      const body = section.rows.length
        ? section.rows.map((row) => `<tr>${cells(row, 'td')}</tr>`).join('')
        : `<tr><td colspan="${section.columns.length}" class="empty">${escapeHtml(section.emptyMessage)}</td></tr>`;
      const foot = section.totalRow && section.rows.length ? `<tfoot><tr>${cells(section.totalRow, 'th')}</tr></tfoot>` : '';
      return `<section><h2>${escapeHtml(section.title)}</h2>${section.note ? `<p class="note">${escapeHtml(section.note)}</p>` : ''}<table><thead><tr>${head}</tr></thead><tbody>${body}</tbody>${foot}</table></section>`;
    })
    .join('');

  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>${escapeHtml(dataset.title)} — ${escapeHtml(dataset.periodLabel)}</title>
<style>
@page { size: A4; margin: 14mm 12mm; }
* { box-sizing: border-box; }
body { margin: 0; color: #1a1616; font: 10.5px/1.4 system-ui, -apple-system, 'Segoe UI', Roboto, Arial, sans-serif; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
header { display: flex; justify-content: space-between; align-items: flex-end; border-bottom: 2px solid #1a1616; padding-bottom: 8px; margin-bottom: 12px; }
h1 { font: 500 22px/1.15 ui-serif, Georgia, 'Times New Roman', serif; margin: 0; letter-spacing: -0.3px; }
h2 { font: 500 14px/1.2 ui-serif, Georgia, 'Times New Roman', serif; margin: 16px 0 6px; }
.meta { text-align: right; color: #6f6363; font-size: 9.5px; }
.sub { color: #6f6363; margin-top: 2px; }
.kpis { display: grid; grid-template-columns: repeat(${Math.max(1, Math.min(4, dataset.summary.length))}, 1fr); gap: 6px; margin-bottom: 4px; }
.kpi { border: 1px solid #e3e1e1; border-radius: 8px; padding: 7px 9px; display: flex; flex-direction: column; gap: 2px; }
.kpi span { color: #6f6363; font-size: 9px; text-transform: uppercase; letter-spacing: 0.6px; }
.kpi strong { font-size: 13px; font-variant-numeric: tabular-nums; }
.kpi--em { background: #1a1616; color: #f7f5f5; border-color: #1a1616; }
.kpi--em span { color: #bcb2b2; }
table { width: 100%; border-collapse: collapse; table-layout: fixed; }
th, td { padding: 4px 5px; text-align: left; vertical-align: top; word-wrap: break-word; }
thead th { font-size: 9px; text-transform: uppercase; letter-spacing: 0.5px; color: #6f6363; border-bottom: 1px solid #1a1616; }
tbody tr:nth-child(even) td { background: #f7f6f6; }
tbody td { border-bottom: 1px solid #eeeaea; }
tfoot th { border-top: 1.5px solid #1a1616; font-weight: 700; }
.r { text-align: right; font-variant-numeric: tabular-nums; }
.note { color: #6f6363; margin: 0 0 6px; }
.empty { color: #6f6363; text-align: center; padding: 14px; }
footer { margin-top: 16px; color: #6f6363; font-size: 9px; border-top: 1px solid #e3e1e1; padding-top: 6px; }
thead { display: table-header-group; } tr { page-break-inside: avoid; }
</style></head><body>
<header><div><h1>${escapeHtml(dataset.title)}</h1>${dataset.subtitle ? `<div class="sub">${escapeHtml(dataset.subtitle)}</div>` : ''}</div>
<div class="meta">${escapeHtml(appName)}<br>${escapeHtml(dataset.periodLabel)}<br>Generated ${escapeHtml(timestamp(dataset.generatedAt))}</div></header>
${summary ? `<div class="kpis">${summary}</div>` : ''}
${sections}
${dataset.footnote ? `<footer>${escapeHtml(dataset.footnote)}</footer>` : ''}
</body></html>`;
}
