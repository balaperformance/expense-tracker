/**
 * From positioned text fragments (a PDF text layer or OCR words) to lines of
 * cells. Pure geometry, so any extractor can feed it and it can be tested
 * without a PDF.
 */
import type { TextCell, TextLine } from './model';

/** One fragment as an extractor reports it. y is the baseline, growing upwards (PDF space). */
export type TextFragment = { text: string; x: number; y: number; width: number; height: number };

/**
 * Groups one page's fragments into lines, top to bottom, and merges
 * fragments on a line that are closer than about half a character — pieces of
 * one word or one phrase — while keeping real column gaps as separate cells.
 */
export function groupFragments(fragments: readonly TextFragment[], page: number): TextLine[] {
  const usable = fragments.filter((f) => f.text.trim().length > 0);
  if (!usable.length) return [];

  const sorted = [...usable].sort((a, b) => b.y - a.y || a.x - b.x);
  const rows: TextFragment[][] = [];
  let current: TextFragment[] = [];
  let baseline = sorted[0]?.y ?? 0;
  let tolerance = 2;
  for (const fragment of sorted) {
    if (current.length && Math.abs(fragment.y - baseline) > tolerance) {
      rows.push(current);
      current = [];
    }
    if (!current.length) {
      baseline = fragment.y;
      tolerance = Math.max(2, (fragment.height || 8) * 0.45);
    }
    current.push(fragment);
  }
  if (current.length) rows.push(current);

  return rows.map((row) => {
    const byX = [...row].sort((a, b) => a.x - b.x);
    const cells: TextCell[] = [];
    let last: TextCell | null = null;
    for (const fragment of byX) {
      const text = fragment.text.replace(/\s+/g, ' ');
      const em = fragment.height || 8;
      if (last) {
        const gap = fragment.x - (last.x + last.width);
        if (gap < em * 0.5) {
          const joiner = gap > em * 0.12 && !last.text.endsWith(' ') && !text.startsWith(' ') ? ' ' : '';
          last.text = `${last.text}${joiner}${text}`;
          last.width = Math.max(last.width, fragment.x + fragment.width - last.x);
          continue;
        }
      }
      const cell: TextCell = { text, x: fragment.x, width: fragment.width };
      cells.push(cell);
      last = cell;
    }
    const trimmed = cells.map((c) => ({ ...c, text: c.text.trim() })).filter((c) => c.text);
    return {
      page,
      y: row[0]?.y ?? 0,
      cells: trimmed,
      text: trimmed.map((c) => c.text).join(' '),
    };
  });
}
