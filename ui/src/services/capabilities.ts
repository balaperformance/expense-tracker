/**
 * Detects which optional schema objects exist. Port of
 * `services/schema_capabilities.dart`.
 *
 * The Phase 2 tables and columns are added by migrations the developer runs
 * by hand. Rather than failing every query until then, the app asks the
 * database what it has and degrades to the Phase 1 feature set. PostgREST
 * validates selected columns before reading rows, so an empty result still
 * proves the shape exists.
 */
import { getSupabase } from '@/lib/supabase';
import { retryOnTransientAuth } from '@/lib/retry';

export type SchemaCapabilities = {
  /** `expenses.merchant` */
  merchant: boolean;
  /** `bank_accounts` + `account_transactions` */
  bankAccounts: boolean;
  expenseBankLink: boolean;
  incomeBankLink: boolean;
  /** `account_transactions.counterparty_account_id` (migration 003) */
  transfers: boolean;
};

const UNDEFINED_COLUMN = '42703';
const UNDEFINED_TABLE = 'PGRST205';
const UNDEFINED_TABLE_LEGACY = '42P01';

let resolved: SchemaCapabilities | null = null;
let inflight: Promise<SchemaCapabilities> | null = null;

async function probe(table: string, column: string): Promise<boolean> {
  const { error } = await getSupabase().from(table).select(column).limit(1);
  if (!error) return true;
  if (error.code === UNDEFINED_COLUMN || error.code === UNDEFINED_TABLE || error.code === UNDEFINED_TABLE_LEGACY) {
    return false;
  }
  // Anything else (network, auth) is not evidence of a missing feature.
  throw error;
}

/** Probes once per session unless [force] is set. */
export function resolveCapabilities(force = false): Promise<SchemaCapabilities> {
  if (resolved && !force) return Promise.resolve(resolved);
  if (inflight && !force) return inflight;
  inflight = retryOnTransientAuth(async () => {
    const [merchant, bankAccounts, expenseBankLink, incomeBankLink, transfers] = await Promise.all([
      probe('expenses', 'merchant'),
      probe('bank_accounts', 'id'),
      probe('expenses', 'bank_account_id'),
      probe('income', 'bank_account_id'),
      probe('account_transactions', 'counterparty_account_id'),
    ]);
    return { merchant, bankAccounts, expenseBankLink, incomeBankLink, transfers };
  })
    .then((caps) => {
      resolved = caps;
      return caps;
    })
    .finally(() => {
      inflight = null;
    });
  return inflight;
}

/** The last probe's answer. Only read after bootstrap has resolved it. */
export function capabilities(): SchemaCapabilities {
  return (
    resolved ?? { merchant: false, bankAccounts: false, expenseBankLink: false, incomeBankLink: false, transfers: false }
  );
}

/** Everything Phase 2 needs to record a bank-funded expense. */
export const phase2Ready = (caps: SchemaCapabilities) => caps.bankAccounts && caps.expenseBankLink;

export function missingSummary(caps: SchemaCapabilities): string {
  return [
    !caps.bankAccounts && 'bank_accounts / account_transactions tables',
    !caps.expenseBankLink && 'expenses.bank_account_id',
    !caps.incomeBankLink && 'income.bank_account_id',
    !caps.merchant && 'expenses.merchant',
    !caps.transfers && 'account_transactions.counterparty_account_id',
  ]
    .filter(Boolean)
    .join(', ');
}

/** Test / preview seam, like the Flutter `debugOverride`: fixes the probe's answer. */
export function overrideCapabilities(caps: SchemaCapabilities): void {
  resolved = caps;
  inflight = null;
}

export function resetCapabilities(): void {
  resolved = null;
  inflight = null;
}
