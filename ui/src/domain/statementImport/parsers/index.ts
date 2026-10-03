/**
 * The parser registry.
 *
 * Adding a bank, once sample statements are available:
 *   1. Create `parsers/<bank>.ts` exporting a `StatementParser` whose
 *      `detect` returns > 0 only for that bank's statements (look for the
 *      bank's name, IFSC prefix or its exact header row) and whose `parse`
 *      locates each row's date, narration and amount text.
 *   2. Add it to BANK_PARSERS below.
 *   3. Add a test built from the (anonymised) text of a real statement.
 * Nothing else changes: normalisation, classification, duplicate protection,
 * review and import are shared by every parser.
 *
 * A payment app's statement (Paytm) is a parser like any other. It covers
 * several of the user's accounts, so it names each row's own account and sets
 * ParsedStatement.accountPerRow; the pipeline then matches every row to that
 * account instead of the one chosen for the upload.
 */
import type { StatementParser } from '../parser';

import { airtelPaymentsBankParser } from './airtelPaymentsBank';
import { genericTableParser } from './genericTable';
import { hdfcParser } from './hdfc';
import { paytmParser } from './paytm';

export const BANK_PARSERS: readonly StatementParser[] = [hdfcParser, airtelPaymentsBankParser, paytmParser];

export const FALLBACK_PARSER: StatementParser = genericTableParser;
