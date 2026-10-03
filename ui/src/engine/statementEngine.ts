/**
 * The statement-import engine for the phone app.
 *
 * The Android app reads bank statements with exactly this code, not a copy:
 * this module is bundled (npm run build:engine) into one offline script that
 * runs in a hidden system WebView on the phone, and the app talks to it with
 * JSON. Everything here is a thin wrapper — reading, parsing, classification,
 * duplicate detection, review edits and the import plan are the web modules
 * the Import statement screen already uses, so a parser fixed here is fixed
 * on both platforms by rebuilding the bundle.
 *
 * Stateless by design: the app holds the review items and passes them back
 * with each call. Nothing here talks to the network or writes anything; the
 * app performs the writes with its own repositories after the user confirms.
 */
import { addDays, type IsoDate } from '@/lib/dates';
import type { BankAccount, CreditCard, ExpenseCategory, LedgerEntry, PaymentMethod } from '@/domain/models';
import { isBlockingDuplicate, markDuplicates, NEARBY_DAYS } from '@/domain/statementImport/duplicates';
import {
  buildImportPlan,
  countOperations,
  withoutNewlyRecorded,
  type ImportOperation,
  type ImportPlan,
} from '@/domain/statementImport/importPlan';
import type { ExistingMovement, NormalizedTransaction, TransactionType } from '@/domain/statementImport/model';
import { accountMismatch, type ProcessedStatement } from '@/domain/statementImport/pipeline';
import {
  detailProblem,
  isUncategorized,
  needsAttention,
  reviewProblemMessage,
  reviewReducer,
  summarize,
  toReviewItems,
  type ReviewAction,
  type ReviewItem,
} from '@/domain/statementImport/review';
import { fallbackCategory } from '@/domain/sms/smsDraft';
import {
  availableKinds,
  findTransferMatches,
  isPlainMovement,
  TRANSFER_MATCH_DAYS,
  treatmentPayload,
  type TreatmentRequest,
} from '@/domain/treatment';
import { duplicateBadge, duplicateText, kindLabel, periodLabel } from '@/features/statementImport/labels';
import { StatementReadError } from '@/services/statementImport/extractors';
import { readStatementFile } from '@/services/statementImport/reader';

/** How the engine gets a picked file's bytes: the host app hands them over in chunks. */
export type FileSource = (token: string) => Promise<Uint8Array>;

/** [detail] is for logs only — the app shows [message] or its own wording for [code]. */
export type EngineError = { code: string; message: string; detail?: string };

export class EngineFailure extends Error {
  constructor(readonly failure: EngineError) {
    super(failure.message);
  }
}

type ReadArgs = {
  token: string;
  fileName: string;
  password?: string | null;
  account: BankAccount;
  accounts: readonly BankAccount[];
  categories: readonly ExpenseCategory[];
  cards?: readonly CreditCard[];
};

/** The session span: every statement's period, earliest to latest. */
function sessionRange(statements: readonly Pick<ProcessedStatement, 'period'>[]): { from: string; to: string } | null {
  const dates = statements.flatMap((s) => (s.period ? [s.period.from, s.period.to] : [])).sort();
  const [from] = dates;
  const to = dates[dates.length - 1];
  return from && to ? { from, to } : null;
}

/**
 * What the app's database can store, so the plan writes each row the way the
 * web import would on the same database (see buildImportPlan's options).
 */
type PlanOptions = {
  /** Migration 005: a transfer to an account is saved with record_bank_movement. */
  linkAccounts?: boolean;
  /** Migration 003: without 005, both legs of a transfer as one insert. */
  pairAccounts?: boolean;
  /** Migration 007: the reference, UPI ID and time go on the movement. */
  storeDetails?: boolean;
  /** Migration 006: tags are written as tags. */
  storeTags?: boolean;
  /** Account nicknames by id, for the other leg's description. */
  accountNames?: Readonly<Record<string, string>>;
};

type TreatmentOperation = Extract<ImportOperation, { type: 'treatment' }>;

/** Transfers to one of the user's accounts whose other leg the import is left to find. */
function autoMatchOperations(operations: readonly ImportOperation[]): TreatmentOperation[] {
  return operations.filter(
    (op): op is TreatmentOperation => op.type === 'treatment' && op.autoMatch === true && op.request.transferTarget?.type === 'account',
  );
}

/** The ledger windows to read for [autoMatches]: each target account around the transfers to it. */
function autoMatchWindows(operations: readonly ImportOperation[]): { accountId: string; from: IsoDate; toExclusive: IsoDate }[] {
  const byAccount = new Map<string, IsoDate[]>();
  for (const op of autoMatchOperations(operations)) {
    const target = op.request.transferTarget;
    if (target?.type !== 'account') continue;
    byAccount.set(target.accountId, [...(byAccount.get(target.accountId) ?? []), op.date]);
  }
  return [...byAccount].map(([accountId, dates]) => {
    const sorted = [...dates].sort();
    return {
      accountId,
      from: addDays(sorted[0] ?? '', -TRANSFER_MATCH_DAYS),
      toExclusive: addDays(sorted[sorted.length - 1] ?? '', TRANSFER_MATCH_DAYS + 1),
    };
  });
}

/**
 * The importer's rule (services/statementImport/importer.ts): a plain row on
 * the other account with the opposite direction and the same amount within a
 * few days is the same movement, already there from that account's statement —
 * linked instead of adding a second leg. Only a single, unclaimed match is used.
 */
function autoMatches(operations: readonly ImportOperation[], entries: readonly LedgerEntry[]): Record<string, string> {
  const byAccount = new Map<string, LedgerEntry[]>();
  for (const entry of entries) byAccount.set(entry.accountId, [...(byAccount.get(entry.accountId) ?? []), entry]);
  const claimed = new Set<string>();
  const result: Record<string, string> = {};
  for (const op of autoMatchOperations(operations)) {
    const target = op.request.transferTarget;
    if (target?.type !== 'account') continue;
    const matches = findTransferMatches(byAccount.get(target.accountId) ?? [], { direction: op.direction, amount: op.amount, date: op.date }).filter(
      (e) => isPlainMovement(e) && !claimed.has(e.id),
    );
    const [only] = matches;
    if (matches.length === 1 && only) {
      claimed.add(only.id);
      result[op.itemId] = only.id;
    }
  }
  return result;
}

export function createEngine(readFile: FileSource) {
  return {
    /** Constants the app needs to fetch the right window of recorded transactions. */
    constants: () => ({ nearbyDays: NEARBY_DAYS }),

    /**
     * One statement file in, a processed statement out — or a coded failure
     * (passwordRequired, passwordIncorrect, notPdf, unsupportedFormat,
     * scanned, tooLarge, failed) the app turns into its own message or prompt.
     */
    async read(args: ReadArgs) {
      const bytes = await readFile(args.token);
      const file = new File([bytes.slice()], args.fileName);
      try {
        const statement = await readStatementFile({
          file,
          password: args.password ?? undefined,
          account: args.account,
          accounts: args.accounts,
          categories: args.categories,
          cards: args.cards ?? [],
        });
        return {
          statement,
          periodLabel: periodLabel(statement.period, statement.periodKind),
          accountMismatch: accountMismatch(statement, args.account),
        };
      } catch (error) {
        if (error instanceof StatementReadError) throw new EngineFailure({ code: error.code, message: error.message });
        throw new EngineFailure({ code: 'failed', message: 'The statement could not be read.', detail: String(error) });
      }
    },

    sessionRange: ({ statements }: { statements: readonly Pick<ProcessedStatement, 'period'>[] }) => sessionRange(statements),

    /**
     * New statement rows as review items. Earlier rows (with the user's edits)
     * keep priority: only the new rows get fresh duplicate flags.
     */
    review({
      current,
      transactions,
      existing,
      categories,
    }: {
      current: readonly ReviewItem[];
      transactions: readonly NormalizedTransaction[];
      existing: readonly ExistingMovement[];
      categories: readonly ExpenseCategory[];
    }) {
      const marked = markDuplicates([...current, ...transactions], existing).slice(current.length);
      return toReviewItems(marked, categories);
    },

    /** Fresh duplicate flags after a retried check against recorded transactions. */
    recheck: ({ items, existing }: { items: ReviewItem[]; existing: readonly ExistingMovement[] }) =>
      reviewReducer(items, { type: 'applyDuplicates', marked: markDuplicates(items, existing) }),

    /** Select, deselect, edit or remove — the same reducer the web review uses. */
    reduce: ({ items, action }: { items: ReviewItem[]; action: ReviewAction }) => reviewReducer(items, action),

    /** Counts, plus per-row flags and wording, so the app shows exactly what the web shows. */
    view({ items }: { items: readonly ReviewItem[] }) {
      return {
        summary: summarize(items),
        rows: items.map((item) => {
          // What the row still lacks before it can be imported as chosen — on a
          // multi-account statement, first of all its account.
          const problem = detailProblem(item);
          return {
            id: item.id,
            blocking: isBlockingDuplicate(item.duplicate),
            uncategorized: isUncategorized(item),
            attention: needsAttention(item),
            kindLabel: kindLabel(item.kind, item.transactionType),
            duplicateBadge: item.duplicate ? duplicateBadge(item.duplicate) : null,
            duplicateText: item.duplicate ? duplicateText(item.duplicate) : null,
            problem,
            problemText: problem ? reviewProblemMessage(problem, item.transactionType) : null,
          };
        }),
      };
    },

    /**
     * Kinds valid for a direction. [treatments] false leaves out loans and
     * reimbursements, for a client (or a database) that cannot record them.
     */
    kindsFor: ({ type, treatments = true }: { type: TransactionType; treatments?: boolean }) => availableKinds(type, treatments),

    /**
     * The exact writes, decided before any write — with the same fallback
     * category the web import uses, and the same choices for what the
     * database can store ([options]); plus how many of each, for the
     * confirmation.
     */
    plan: ({
      items,
      categories,
      paymentMethods,
      options = {},
    }: {
      items: readonly ReviewItem[];
      categories: readonly ExpenseCategory[];
      paymentMethods: readonly PaymentMethod[];
      options?: PlanOptions;
    }) => {
      const plan = buildImportPlan(items, {
        fallbackCategoryId: fallbackCategory(categories)?.id ?? null,
        paymentMethods,
        accountNames: new Map(Object.entries(options.accountNames ?? {})),
        linkAccounts: options.linkAccounts,
        pairAccounts: options.pairAccounts,
        storeDetails: options.storeDetails,
        storeTags: options.storeTags,
      });
      return { ...plan, counts: countOperations(plan.operations) };
    },

    /** The last guard before writing: drops anything recorded since review began. */
    finalPlan: ({ plan, items, fresh }: { plan: ImportPlan; items: readonly ReviewItem[]; fresh: readonly ExistingMovement[] }) =>
      withoutNewlyRecorded(plan, items, fresh),

    /** How many of each kind [operations] are — for the result once the import has run. */
    counts: ({ operations }: { operations: readonly ImportOperation[] }) => countOperations(operations),

    /**
     * The body of record_bank_movement's p_treatment for a planned treatment,
     * with what is only known while writing: the saved movement a repayment
     * settles, and the other leg found for a transfer.
     */
    treatmentPayload: ({
      request,
      settleEntryId = null,
      matchEntryId = null,
    }: {
      request: TreatmentRequest;
      settleEntryId?: string | null;
      matchEntryId?: string | null;
    }) => {
      let resolved = request;
      if (settleEntryId) resolved = { ...resolved, settles: { entryId: settleEntryId } };
      if (matchEntryId) resolved = { ...resolved, matchEntryId };
      return treatmentPayload(resolved);
    },

    /** The ledger the app reads before writing, so [autoMatches] can link a transfer's other leg. */
    autoMatchWindows: ({ operations }: { operations: readonly ImportOperation[] }) => autoMatchWindows(operations),

    /** Transfers whose other leg is already on that account: item id → that row's id. */
    autoMatches: ({ operations, entries }: { operations: readonly ImportOperation[]; entries: readonly LedgerEntry[] }) =>
      autoMatches(operations, entries),
  };
}

export type StatementEngine = ReturnType<typeof createEngine>;
