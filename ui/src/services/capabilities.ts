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
  /** `credit_cards`, `credit_card_transactions` and both `credit_card_id` columns (migration 004) */
  creditCards: boolean;
  /** `receivables`, `account_transactions.receivable_id` and the treatment functions (migration 005) */
  treatments: boolean;
  /** `tags`, `expense_tags`, `income_tags` and `set_transaction_tags` (migration 006) */
  tags: boolean;
  /** `account_transactions.reference`, `upi_id` and `txn_time` (migration 007) */
  statementDetails: boolean;
  /** `notification_preferences` and `push_subscriptions` (migration 008) */
  notifications: boolean;
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
    const [merchant, bankAccounts, expenseBankLink, incomeBankLink, transfers, card1, card2, card3, card4, tags1, tags2, tags3, statementDetails, notifications1, notifications2, ...treatmentParts] = await Promise.all([
      probe('expenses', 'merchant'),
      probe('bank_accounts', 'id'),
      probe('expenses', 'bank_account_id'),
      probe('income', 'bank_account_id'),
      probe('account_transactions', 'counterparty_account_id'),
      probe('credit_cards', 'id'),
      probe('credit_card_transactions', 'id'),
      probe('expenses', 'credit_card_id'),
      probe('account_transactions', 'credit_card_id'),
      probe('tags', 'id, name'),
      probe('expense_tags', 'expense_id, tag_id'),
      probe('income_tags', 'income_id, tag_id'),
      probe('account_transactions', 'reference, upi_id, txn_time'),
      probe('notification_preferences', 'user_id, daily_reminder, spending_summary, low_balance, card_due, timezone'),
      probe('push_subscriptions', 'id, endpoint'),
      probe('receivables', 'id, kind, person, ledger_entry_id, expense_id, due_date, note'),
      probe('account_transactions', 'receivable_id'),
    ]);
    // One migration adds all four, so the feature is on only when every part is there.
    const creditCards = [card1, card2, card3, card4].every(Boolean);
    // 005 builds on 004 (it links card purchases), so it counts only with it.
    const treatments = creditCards && treatmentParts.every(Boolean);
    // One migration adds all three tables; tags need no other feature.
    const tags = [tags1, tags2, tags3].every(Boolean);
    // One migration adds both tables, and they are only useful together.
    const notifications = notifications1 && notifications2;
    return { merchant, bankAccounts, expenseBankLink, incomeBankLink, transfers, creditCards, treatments, tags, statementDetails, notifications };
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
    resolved ?? {
      merchant: false,
      bankAccounts: false,
      expenseBankLink: false,
      incomeBankLink: false,
      transfers: false,
      creditCards: false,
      treatments: false,
      tags: false,
      statementDetails: false,
      notifications: false,
    }
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
    !caps.creditCards && 'credit card tables and columns (004)',
    !caps.treatments && 'loans, reimbursements and transfer linking (005)',
    !caps.tags && 'tags (006)',
    !caps.statementDetails && 'statement references and UPI details (007)',
    !caps.notifications && 'push notifications (008)',
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
