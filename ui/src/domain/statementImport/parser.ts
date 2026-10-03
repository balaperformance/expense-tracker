/**
 * The pluggable parser contract.
 *
 *   StatementParser
 *     ├── (bank parsers — added once real statements are available)
 *     └── genericTableParser — header-driven, bank-agnostic fallback
 *
 * A bank parser only has to do two things: say how sure it is that a
 * document is its bank's (detect), and locate each row's date, description
 * and amount text (parse). Dates, amounts, direction, balances, categories and
 * duplicates are all handled downstream, identically for every bank.
 */
import type { ExtractedDocument, ParsedStatement } from './model';

export type StatementParser = {
  /** Stable id, recorded with the statement ("generic-table", "hdfc-savings", …). */
  id: string;
  /** Shown to the user: "HDFC Bank", "Generic table". */
  label: string;
  /**
   * 0–1: how confident this parser is that it understands the document.
   * Bank parsers should look for unmistakable markers (the bank's name, IFSC
   * prefix, a known header row) and return 0 for anything else.
   */
  detect: (doc: ExtractedDocument) => number;
  parse: (doc: ExtractedDocument) => ParsedStatement;
};

export type ParserChoice = { parser: StatementParser; score: number };

/**
 * Picks the parser most confident about the document. The fallback is used
 * only when no specific parser claims it, so adding a bank parser can never
 * make an unrelated statement read worse.
 */
export function selectParser(
  doc: ExtractedDocument,
  parsers: readonly StatementParser[],
  fallback: StatementParser,
): ParserChoice {
  let best: ParserChoice | null = null;
  for (const parser of parsers) {
    const score = Math.min(Math.max(parser.detect(doc), 0), 1);
    if (score > 0 && (!best || score > best.score)) best = { parser, score };
  }
  return best ?? { parser: fallback, score: 0 };
}
