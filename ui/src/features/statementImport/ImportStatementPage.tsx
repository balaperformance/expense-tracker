import { useReducer, useRef, useState, type CSSProperties } from 'react';
import { useNavigate, useSearchParams } from 'react-router';

import { Page } from '@/components/layout/Page';
import { CategoryAvatar, ClaimAvatar, LedgerAvatar, TransferAvatar } from '@/components/finance/Avatars';
import { Money } from '@/components/finance/Money';
import { DayHeader } from '@/components/finance/TransactionRow';
import { Button } from '@/components/ui/Button';
import { Chip, ChipGroup, Segmented } from '@/components/ui/Chip';
import { Badge, Centered, EmptyState, InlineError, Notice, ProgressBar } from '@/components/ui/Feedback';
import { FieldLabel, TextField } from '@/components/ui/Fields';
import { Icon } from '@/components/ui/Icon';
import { Card, CardList, IconWell } from '@/components/ui/Surface';
import { groupByDay } from '@/domain/expenseFilter';
import { accountLabel, cardLabel, type BankAccount, type CreditCard, type ExpenseCategory } from '@/domain/models';
import type { ClaimSummary } from '@/domain/receivables';
import { fallbackCategory } from '@/domain/sms/smsDraft';
import { isBlockingDuplicate, markDuplicates } from '@/domain/statementImport/duplicates';
import { buildImportPlan, countOperations, type PlanCounts } from '@/domain/statementImport/importPlan';
import type { ExistingMovement, TransactionKind } from '@/domain/statementImport/model';
import { accountMismatch, type ProcessedStatement } from '@/domain/statementImport/pipeline';
import { availableKinds } from '@/domain/treatment';
import {
  detailProblem,
  isUncategorized,
  needsAttention,
  reviewReducer,
  summarize,
  toReviewItems,
  type ReviewAction,
  type ReviewItem,
} from '@/domain/statementImport/review';
import { useAccounts, useCapabilities, useCategories, useClaims, useCreditCards, usePaymentMethods } from '@/hooks/data';
import { useSheet } from '@/hooks/useSheet';
import { errorMessage } from '@/lib/errors';
import { formatCurrency, relativeDay } from '@/lib/format';
import { phase2Ready } from '@/services/capabilities';
import { StatementReadError } from '@/services/statementImport/extractors';
import { executeImport, fetchExistingForAccounts, type ImportResult } from '@/services/statementImport/importer';
import { readStatementFile, type ReadProgress } from '@/services/statementImport/reader';
import { useUserId } from '@/state/auth';
import { useFeedback } from '@/state/feedback';
import { invalidateFinance } from '@/state/queryClient';
import { useSettings } from '@/state/settings';

import { duplicateBadge, kindLabel, periodLabel } from './labels';
import { ReviewItemSheet } from './ReviewItemSheet';
import styles from './ImportStatement.module.css';

/** The confirmation's and result screen's lines: what each group is, and that only two of them are income or spending. */
function countLines(counts: PlanCounts): { key: keyof PlanCounts; text: string }[] {
  const n = (value: number, one: string, many: string) => `${String(value)} ${value === 1 ? one : many}`;
  const lines: { key: keyof PlanCounts; text: string }[] = [
    { key: 'expenses', text: n(counts.expenses, 'expense', 'expenses') },
    { key: 'income', text: n(counts.income, 'income', 'income') },
    { key: 'transfers', text: `${n(counts.transfers, 'transfer', 'transfers')} between your accounts` },
    { key: 'lent', text: `${n(counts.lent, 'loan', 'loans')} given — owed back, not spending` },
    { key: 'repaid', text: `${n(counts.repaid, 'repayment or reimbursement', 'repayments and reimbursements')} — not income` },
    { key: 'paidFor', text: `${n(counts.paidFor, 'purchase', 'purchases')} paid for someone else — not your spending` },
    { key: 'movements', text: `${n(counts.movements, 'refund, card bill or cash movement', 'refunds, card bills and cash movements')} (balance only)` },
  ];
  return lines.filter((line) => counts[line.key] > 0);
}

type Filter = 'all' | 'selected' | 'duplicates' | 'attention';

const FILTERS: ReadonlyArray<{ value: Filter; label: string }> = [
  { value: 'all', label: 'All' },
  { value: 'selected', label: 'To import' },
  { value: 'duplicates', label: 'Duplicates' },
  { value: 'attention', label: 'Check' },
];

type Pending = { file: File; rest: File[]; incorrect: boolean };

/** The span every statement in the session covers. */
function sessionRange(statements: readonly ProcessedStatement[]): { from: string; to: string } | null {
  const dates = statements.flatMap((s) => (s.period ? [s.period.from, s.period.to] : [])).sort();
  const [from] = dates;
  const to = dates[dates.length - 1];
  return from && to ? { from, to } : null;
}

function progressText(progress: ReadProgress | null, fileName: string | null): string {
  if (!progress) return 'Starting…';
  switch (progress.stage) {
    case 'opening':
      return `Opening ${fileName ?? 'statement'}…`;
    case 'extracting':
      return progress.page && progress.pageCount ? `Reading page ${String(progress.page)} of ${String(progress.pageCount)}…` : 'Reading…';
    case 'parsing':
      return 'Finding transactions…';
  }
}

export function ImportStatementPage() {
  const navigate = useNavigate();
  const [params] = useSearchParams();
  const userId = useUserId();
  const { currency, symbol } = useSettings();
  const { toast, confirm } = useFeedback();
  const caps = useCapabilities();
  const categories = useCategories().data ?? [];
  const paymentMethods = usePaymentMethods().data ?? [];
  const accountsQuery = useAccounts();
  const allAccounts = (accountsQuery.data ?? []).map((b) => b.account);
  const accounts = allAccounts.filter((a) => a.isActive);
  const cards = (useCreditCards().data ?? []).map((o) => o.card);
  const claims = useClaims().data ?? [];

  const [accountId, setAccountId] = useState<string | null>(() => params.get('account'));
  const [statements, setStatements] = useState<ProcessedStatement[]>([]);
  const [items, dispatch] = useReducer(reviewReducer, []);
  const [reading, setReading] = useState<{ file: string; progress: ReadProgress | null; checking: boolean } | null>(null);
  const [pending, setPending] = useState<Pending | null>(null);
  const [password, setPassword] = useState('');
  const [problem, setProblem] = useState<string | null>(null);
  const [filter, setFilter] = useState<Filter>('all');
  const [importing, setImporting] = useState<{ done: number; total: number } | null>(null);
  const [result, setResult] = useState<ImportResult | null>(null);
  const [checkFailed, setCheckFailed] = useState(false);
  const [rechecking, setRechecking] = useState(false);
  const fileInput = useRef<HTMLInputElement>(null);
  const editor = useSheet<string>();

  const account = accounts.find((a) => a.id === accountId) ?? null;
  const ready = caps.bankAccounts && phase2Ready(caps);

  const reset = () => {
    setStatements([]);
    dispatch({ type: 'replace', items: [] });
    setResult(null);
    setProblem(null);
    setPending(null);
    setPassword('');
    setFilter('all');
    setCheckFailed(false);
  };

  /**
   * Re-runs the check against recorded transactions for everything in the
   * session — on every account its rows are on. [quiet]: after a row moved to
   * another account; a failure then only holds the import back.
   */
  const recheck = async (current: readonly ReviewItem[] = items, quiet = false) => {
    const range = sessionRange(statements);
    if (!account || !range) return;
    setRechecking(true);
    try {
      const existing = await fetchExistingForAccounts(userId, [account.id, ...current.map((i) => i.bankAccountId)], range.from, range.to);
      dispatch({ type: 'applyDuplicates', marked: markDuplicates(current, existing) });
      setCheckFailed(false);
    } catch (error) {
      if (quiet) setCheckFailed(true);
      else toast('error', errorMessage(error, 'Still could not check for recorded transactions.'));
    } finally {
      setRechecking(false);
    }
  };

  /** Reads files one after another; a password-protected one pauses the queue until unlocked. */
  const readFiles = async (files: File[], target: BankAccount, passwordFor?: { file: File; value: string }) => {
    setProblem(null);
    let known = statements;
    let current = items;
    for (const [index, file] of files.entries()) {
      setReading({ file: file.name, progress: null, checking: false });
      try {
        const statement = await readStatementFile({
          file,
          password: passwordFor?.file === file ? passwordFor.value : undefined,
          account: target,
          accounts,
          categories,
          cards,
          onProgress: (progress) => setReading({ file: file.name, progress, checking: false }),
        });
        if (known.some((s) => s.id === statement.id)) {
          toast('info', `${file.name} was already added.`);
          continue;
        }
        if (!statement.transactions.length) {
          setProblem(`No transactions were found in ${file.name}. If it is a statement, its layout is not supported yet.`);
          continue;
        }
        setReading({ file: file.name, progress: null, checking: true });
        let existing: ExistingMovement[] = [];
        try {
          const range = sessionRange([...known, statement]);
          // Every account the session's rows are on: a Paytm statement spans several.
          const onAccounts = [target.id, ...current.map((i) => i.bankAccountId), ...statement.transactions.map((t) => t.bankAccountId)];
          existing = range ? await fetchExistingForAccounts(userId, onAccounts, range.from, range.to) : [];
        } catch {
          // Still reviewable — overlaps between these files are caught — but importing
          // waits until the check against recorded transactions succeeds.
          setCheckFailed(true);
        }
        // Earlier statements (with the user's edits) keep priority; only the new rows get fresh flags.
        const marked = markDuplicates([...current, ...statement.transactions], existing).slice(current.length);
        const added = toReviewItems(marked, categories);
        known = [...known, statement];
        current = [...current, ...added];
        setStatements(known);
        dispatch({ type: 'append', items: added });
        setPending(null);
        setPassword('');
      } catch (error) {
        if (error instanceof StatementReadError && (error.code === 'passwordRequired' || error.code === 'passwordIncorrect')) {
          setPending({ file, rest: files.slice(index + 1), incorrect: error.code === 'passwordIncorrect' });
          setReading(null);
          return;
        }
        setProblem(`${file.name}: ${error instanceof StatementReadError ? error.message : errorMessage(error, 'The statement could not be read.')}`);
      }
    }
    setReading(null);
  };

  const pick = (list: FileList | null) => {
    const files = [...(list ?? [])];
    if (fileInput.current) fileInput.current.value = '';
    if (!files.length || !account) return;
    void readFiles(files, account);
  };

  const unlock = () => {
    if (!pending || !account || !password) return;
    void readFiles([pending.file, ...pending.rest], account, { file: pending.file, value: password });
  };

  const summary = summarize(items);
  const visible = items.filter((item) => {
    if (filter === 'selected') return item.selected;
    if (filter === 'duplicates') return item.duplicate != null;
    if (filter === 'attention') return needsAttention(item) || isUncategorized(item) || detailProblem(item) != null;
    return true;
  });
  const newestFirst = [...visible].sort((a, b) => (a.transactionDate < b.transactionDate ? 1 : a.transactionDate > b.transactionDate ? -1 : 0));
  const groups = groupByDay(newestFirst, (i) => i.transactionDate, (i) => (i.transactionType === 'credit' ? i.amount : -i.amount));
  const editing = items.find((i) => i.id === editor.data) ?? null;

  const runImport = async () => {
    if (!account) return;
    const fallback = fallbackCategory(categories);
    const plan = buildImportPlan(items, {
      fallbackCategoryId: fallback?.id ?? null,
      paymentMethods,
      accountNames: new Map(allAccounts.map((a) => [a.id, a.nickname])),
      linkAccounts: caps.treatments,
      pairAccounts: caps.transfers,
      storeDetails: caps.statementDetails,
      storeTags: caps.tags,
    });
    if (!plan.operations.length) {
      setProblem(plan.skipped[0] ? `Nothing can be imported yet: ${plan.skipped[0].reason.toLowerCase()}.` : 'Select at least one transaction.');
      return;
    }
    const total = (type: 'expense' | 'income') =>
      formatCurrency(plan.operations.filter((op) => op.type === type).reduce((s, op) => s + op.amount, 0), currency);
    const counts = countOperations(plan.operations);
    const untracked = items.filter((i) => i.selected && i.kind === 'transfer' && i.transferTarget == null).length;
    // A multi-account statement writes into each row's own account.
    const perAccount = new Map<string, number>();
    for (const op of plan.operations) perAccount.set(op.bankAccountId, (perAccount.get(op.bankAccountId) ?? 0) + 1);
    const into = [...perAccount]
      .map(([id, n]) => {
        const target = allAccounts.find((a) => a.id === id);
        return `${target ? accountLabel(target) : 'an account'}${perAccount.size > 1 ? ` (${String(n)})` : ''}`;
      })
      .join(', ');
    const ok = await confirm({
      title: `Import ${String(plan.operations.length)} ${plan.operations.length === 1 ? 'transaction' : 'transactions'}?`,
      message: (
        <div className="stack gap-xs">
          <span>Into {into}:</span>
          {countLines(counts).map((line) => (
            <span key={line.key}>
              • {line.text}
              {line.key === 'expenses' ? ` · ${total('expense')}` : line.key === 'income' ? ` · ${total('income')}` : ''}
            </span>
          ))}
          {untracked ? (
            <span>
              {untracked} {untracked === 1 ? 'transfer has' : 'transfers have'} no account chosen and will change this balance only.
            </span>
          ) : null}
          {plan.skipped.length ? <span>{plan.skipped.length} selected rows will be skipped: {plan.skipped[0]?.reason.toLowerCase()}.</span> : null}
          <span>Rows recorded meanwhile are checked again and left out.</span>
        </div>
      ),
      confirmLabel: 'Import',
    });
    if (!ok) return;
    setImporting({ done: 0, total: plan.operations.length });
    try {
      const outcome = await executeImport(userId, {
        plan,
        items,
        onProgress: (done, totalOps) => setImporting({ done, total: totalOps }),
      });
      setResult(outcome);
    } catch (error) {
      setProblem(errorMessage(error, 'The import could not start.'));
    } finally {
      setImporting(null);
      // Some rows may have been written even if others failed.
      await invalidateFinance();
    }
  };

  // ---- Screens ---------------------------------------------------------------

  if (!ready) {
    return (
      <Page title="Import statement" back="/accounts" narrow>
        <Centered>
          <EmptyState icon="bank" title="Bank accounts needed" message="Statement import links every row to a bank account. Set up bank accounts first." />
        </Centered>
      </Page>
    );
  }

  if (result && account) {
    const imported = Object.values(result.imported).reduce((sum, value) => sum + value, 0);
    return (
      <Page title="Import complete" back={`/accounts/${account.id}`} narrow>
        <Card padding="roomy">
          <div className="stack gap-md" style={{ alignItems: 'center', textAlign: 'center' }}>
            <IconWell icon={result.failed.length ? 'warning' : 'checkCircle'} tone={result.failed.length ? 'var(--warning)' : 'var(--income)'} size={54} round />
            <h2 className="t-headline-sm">
              {imported} {imported === 1 ? 'transaction' : 'transactions'} imported
            </h2>
            <p className="t-body-sm">{countLines(result.imported).map((line) => line.text).join(' · ') || 'Nothing new was saved'}</p>
          </div>
        </Card>
        {result.skipped.length ? (
          <Notice icon="copy" message={`${String(result.skipped.length)} skipped — ${[...new Set(result.skipped.map((s) => s.reason.toLowerCase()))].join(', ')}.`} />
        ) : null}
        {result.failed.length || result.notAttempted ? (
          <Notice
            icon="error"
            tone="var(--error)"
            message={`${String(result.failed.length + result.notAttempted)} could not be saved (${result.failed[0]?.message ?? 'connection problem'}). Import the statement again: rows already saved are recognised and left out.`}
          />
        ) : null}
        {result.partial ? (
          <Notice
            icon="warning"
            tone="var(--warning)"
            message={`${String(result.partial)} saved without all their tags or UPI details. Open them to add the tags.`}
          />
        ) : null}
        <div className="row gap-sm">
          {statements.some((s) => s.accountPerRow) ? (
            <Button label="View accounts" icon="bank" onClick={() => void navigate('/accounts')} />
          ) : (
            <Button label="View account" icon="bank" onClick={() => void navigate(`/accounts/${account.id}`)} />
          )}
          <Button label="Import another" variant="secondary" onClick={reset} />
        </div>
      </Page>
    );
  }

  const input = (
    <input
      ref={fileInput}
      type="file"
      accept="application/pdf,.pdf,.xlsx,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      multiple
      hidden
      onChange={(event) => pick(event.target.files)}
      aria-label="Statement file"
    />
  );

  const progressCard = reading ? (
    <Card>
      <div className="stack gap-sm">
        <div className="row gap-sm">
          <Icon name="document" size={18} color="var(--primary)" />
          <span className="grow t-title-sm t-ellipsis">{reading.checking ? 'Checking for duplicates…' : progressText(reading.progress, reading.file)}</span>
        </div>
        <ProgressBar />
        <span className="t-label-sm">Read on this device — the file is not uploaded.</span>
      </div>
    </Card>
  ) : null;

  const passwordCard = pending ? (
    <Card>
      <div className="stack gap-md">
        <div className="row gap-sm">
          <Icon name="lock" size={18} color="var(--primary)" />
          <span className="t-title-sm grow t-ellipsis">{pending.file.name} is password protected</span>
        </div>
        <div>
          <FieldLabel text="Statement password" hint={pending.incorrect ? 'That password did not work' : null} hintIsError={pending.incorrect} />
          <TextField
            value={password}
            onChange={setPassword}
            type="password"
            autoComplete="off"
            aria-label="Statement password"
            icon="password"
            onKeyDown={(event) => {
              if (event.key === 'Enter') unlock();
            }}
            autoFocus
          />
        </div>
        <p className="t-body-sm">Used only to open the file on this device. It is not saved or sent anywhere.</p>
        <div className="row gap-sm">
          <Button label="Unlock" icon="lock" disabled={!password} onClick={unlock} />
          <Button label="Skip this file" variant="ghost" onClick={() => { const rest = pending.rest; setPending(null); setPassword(''); if (account && rest.length) void readFiles(rest, account); }} />
        </div>
      </div>
    </Card>
  ) : null;

  // Setup: no statement read yet.
  if (!statements.length) {
    return (
      <Page title="Import statement" back={accountId ? `/accounts/${accountId}` : '/accounts'} narrow>
        {input}
        <div>
          <FieldLabel text="Account" required />
          {accountsQuery.isPending ? (
            <p className="t-body-sm">Loading accounts…</p>
          ) : accounts.length ? (
            <ChipGroup label="Account">
              {accounts.map((a) => (
                <Chip key={a.id} label={accountLabel(a)} icon="bank" selected={a.id === accountId} disabled={Boolean(reading)} onClick={() => setAccountId(a.id)} />
              ))}
            </ChipGroup>
          ) : (
            <Notice message="Add a bank account first — every imported row belongs to one." />
          )}
        </div>
        <button type="button" className={styles.drop} disabled={!account || Boolean(reading) || Boolean(pending)} onClick={() => fileInput.current?.click()}>
          <IconWell icon="document" size={46} />
          <span className="t-title-md">{account ? 'Choose statement (PDF or Excel)' : 'Choose an account first'}</span>
          <span className="t-body-sm">Weekly, fortnightly or monthly. You can add several — overlapping periods are handled.</span>
        </button>
        {progressCard}
        {passwordCard}
        {problem ? <Notice icon="error" tone="var(--error)" message={problem} /> : null}
        <Notice
          icon="lock"
          message="The statement is read on this device and never uploaded or sent to an AI service. Nothing is saved until you review the transactions and confirm."
        />
      </Page>
    );
  }

  // Review.
  const allVisibleSelected = visible.length > 0 && visible.every((i) => i.selected);
  return (
    <Page
      title="Review statement"
      back={account ? `/accounts/${account.id}` : '/accounts'}
      bar={
        <>
          <Button label="Start over" variant="secondary" size="lg" disabled={Boolean(importing)} onClick={reset} />
          <Button
            label={importing ? `Saving ${String(importing.done)} of ${String(importing.total)}` : `Import ${String(summary.selected)}`}
            size="lg"
            icon="download"
            busy={Boolean(importing)}
            busyLabel={importing ? `Saving ${String(importing.done)} of ${String(importing.total)}…` : 'Saving…'}
            disabled={!summary.selected || Boolean(reading) || checkFailed}
            onClick={() => void runImport()}
          />
        </>
      }
    >
      {input}
      <div className={styles.statements}>
        {statements.map((s) => (
          <Card key={s.id} padding="flush">
            <div className={styles.statementRow}>
              <IconWell icon="document" size={36} />
              <div className="grow stack" style={{ minWidth: 0 }}>
                <span className="t-title-sm t-ellipsis">{s.fileName}</span>
                <span className="t-body-sm t-ellipsis">
                  {s.bankName ? `${s.bankName} · ` : ''}
                  {periodLabel(s.period, s.periodKind)} · {s.transactions.length} rows
                </span>
              </div>
              {s.warnings.length ? <Badge label={`${String(s.warnings.length)} notes`} icon="info" /> : null}
            </div>
            {account && accountMismatch(s, account) ? (
              <div className={styles.statementNote}>
                <Notice icon="warning" tone="var(--warning)" message={`This statement is for an account ending ${s.accountLast4 ?? ''}, not ${accountLabel(account)}. Start over if that is the wrong account.`} />
              </div>
            ) : null}
            {s.accountPerRow ? (
              <div className={styles.statementNote}>
                <AccountSpread items={items.filter((i) => i.sourceStatementId === s.id)} accounts={allAccounts} bankName={s.bankName} />
              </div>
            ) : null}
            {s.warnings.length ? (
              <details className={styles.warnings}>
                <summary>What could not be read</summary>
                <ul>
                  {s.warnings.slice(0, 12).map((w, i) => (
                    <li key={i}>{w.message}</li>
                  ))}
                </ul>
              </details>
            ) : null}
          </Card>
        ))}
        <div className="row gap-sm">
          <Button label="Add another statement" icon="add" size="sm" variant="tonal" disabled={Boolean(reading) || Boolean(importing)} onClick={() => fileInput.current?.click()} />
          {/* A Paytm statement's rows go to their own accounts: the upload's account says nothing about them. */}
          {account && !statements.some((s) => s.accountPerRow) ? <span className="t-label-sm t-ellipsis">{accountLabel(account)}</span> : null}
        </div>
      </div>
      {progressCard}
      {passwordCard}
      {checkFailed ? (
        <Card tone="var(--warning)">
          <div className="stack gap-sm">
            <span className="t-title-sm">Duplicate check did not finish</span>
            <span className="t-body-sm">
              Rows repeated between these files are already marked, but the transactions you have recorded could not be checked. Importing
              waits until this succeeds, so nothing is added twice.
            </span>
            <div>
              <Button label="Check again" icon="refresh" size="sm" busy={rechecking} onClick={() => void recheck()} />
            </div>
          </div>
        </Card>
      ) : null}

      <div className={styles.summary}>
        <SummaryTile label="Found" value={String(summary.total)} />
        <SummaryTile label="Money in" value={String(summary.income.count)} detail={formatCurrency(summary.income.amount, currency, { compact: true })} tone="var(--income)" />
        <SummaryTile label="Money out" value={String(summary.expense.count)} detail={formatCurrency(summary.expense.amount, currency, { compact: true })} tone="var(--expense)" />
        <SummaryTile label="Duplicates" value={String(summary.duplicates)} detail={summary.nearby ? `${String(summary.nearby)} similar` : 'left out'} tone="var(--warning)" />
        <SummaryTile
          label="Uncategorised"
          value={String(summary.uncategorized)}
          detail={
            summary.refunds + summary.transfers + summary.loans
              ? `${String(summary.refunds + summary.transfers + summary.loans)} transfers, loans, refunds`
              : undefined
          }
        />
        {summary.needsDetail ? (
          <SummaryTile label="Need details" value={String(summary.needsDetail)} detail="who, or which account" tone="var(--warning)" />
        ) : null}
      </div>

      <Segmented label="Show" value={filter} options={FILTERS} onChange={setFilter} />
      <div className="row gap-sm">
        <Button
          label={allVisibleSelected ? 'Deselect all' : 'Select all'}
          size="sm"
          variant="ghost"
          icon={allVisibleSelected ? 'close' : 'check'}
          disabled={!visible.length}
          onClick={() => dispatch({ type: 'setSelected', ids: visible.map((i) => i.id), selected: !allVisibleSelected })}
        />
        <span className="grow" />
        <span className="t-label-sm">
          {summary.selected} of {summary.total} selected
        </span>
      </div>

      {problem ? <InlineError message={problem} /> : null}

      {!visible.length ? (
        <EmptyState compact icon="expenses" title="Nothing here" message="No transactions match this view." />
      ) : (
        <div>
          {groups.map((group, index) => (
            <section key={group.day}>
              <DayHeader label={relativeDay(group.day)} total={group.total} currency={currency} tone="auto" first={index === 0} />
              <CardList indent={null}>
                {group.items.map((item) => (
                  <ReviewRow
                    key={item.id}
                    item={item}
                    items={items}
                    categories={categories}
                    accounts={allAccounts}
                    cards={cards}
                    claims={claims}
                    currency={currency}
                    treatments={caps.treatments}
                    showAccount={item.sourceAccount != null}
                    onToggle={() => dispatch({ type: 'toggle', id: item.id })}
                    onOpen={() => editor.open(item.id)}
                    onKind={(kind) => {
                      dispatch({ type: 'edit', id: item.id, patch: { kind } });
                      // Transfers, loans and reimbursements need a detail or two: ask for them straight away.
                      if (kind === 'transfer' || kind === 'loan' || kind === 'reimbursement') editor.open(item.id);
                    }}
                  />
                ))}
              </CardList>
            </section>
          ))}
        </div>
      )}

      {editing ? (
        <ReviewItemSheet
          key={editor.key}
          open={editor.isOpen}
          item={editing}
          items={items}
          categories={categories}
          account={account}
          accounts={allAccounts}
          cards={cards}
          claims={claims}
          currency={currency}
          symbol={symbol}
          onClose={editor.close}
          onSave={({ patch, similar }) => {
            const actions: ReviewAction[] = [{ type: 'edit', id: editing.id, patch }];
            if (similar) actions.push({ type: 'editMany', ids: similar.ids, patch: similar.patch });
            for (const action of actions) dispatch(action);
            editor.close();
            // Moved to another account: check that account's recorded transactions too.
            if (patch.bankAccountId !== undefined) void recheck(actions.reduce(reviewReducer, items), true);
          }}
          onRemove={() => {
            editor.close();
            dispatch({ type: 'remove', id: editing.id });
          }}
        />
      ) : null}
    </Page>
  );
}

function SummaryTile({ label, value, detail, tone }: { label: string; value: string; detail?: string; tone?: string }) {
  return (
    <div className={styles.tile} style={tone ? ({ '--tone': tone } as CSSProperties) : undefined}>
      <span className="t-label-sm">{label}</span>
      <span className={styles.tileValue}>{value}</span>
      {detail ? <span className={styles.tileDetail}>{detail}</span> : null}
    </div>
  );
}

/** The row's second line: what its treatment points at — the category, the account, the person. */
function rowDetail(
  item: ReviewItem,
  {
    items,
    categories,
    accounts,
    cards,
    claims,
  }: {
    items: readonly ReviewItem[];
    categories: readonly ExpenseCategory[];
    accounts: readonly BankAccount[];
    cards: readonly CreditCard[];
    claims: readonly ClaimSummary[];
  },
): string | null {
  const out = item.transactionType === 'debit';
  const person = item.person.trim();
  switch (item.kind) {
    case 'expense': {
      const name = categories.find((c) => c.id === item.categoryId)?.name ?? 'No category';
      return item.reimbursable && person ? `${name} · paid for ${person}` : name;
    }
    case 'income':
      return item.category ?? null;
    case 'refund':
      return 'Balance only';
    case 'transfer': {
      const target = item.transferTarget;
      if (!target) return null;
      if (target.type === 'cash') return out ? 'to cash' : 'from cash';
      if (target.type === 'card') {
        const card = cards.find((c) => c.id === target.cardId);
        return card ? `${cardLabel(card)} bill` : 'Card bill';
      }
      const other = accounts.find((a) => a.id === target.accountId)?.nickname ?? 'your account';
      const linked = item.transferMatch && item.transferMatch !== 'new' ? ' · linked' : '';
      return `${out ? 'to' : 'from'} ${other}${linked}`;
    }
    case 'loan':
    case 'reimbursement': {
      if (out) return person ? `to ${person}` : null;
      const settles = item.settles;
      const who =
        settles?.type === 'claim'
          ? claims.find((c) => c.receivable.id === settles.receivableId)?.receivable.person
          : settles?.type === 'pending'
            ? items.find((i) => i.id === settles.itemId)?.person.trim()
            : person;
      return who ? `from ${who}` : null;
    }
  }
}

/**
 * A multi-account statement's rows by the account each went to — and how many
 * named an account that is not one of the user's, so they can choose it.
 */
function AccountSpread({ items, accounts, bankName }: { items: readonly ReviewItem[]; accounts: readonly BankAccount[]; bankName: string | null }) {
  const counts = new Map<string, number>();
  for (const item of items) counts.set(item.bankAccountId, (counts.get(item.bankAccountId) ?? 0) + 1);
  const unmatched = counts.get('') ?? 0;
  const placed = [...counts]
    .filter(([id]) => id)
    .map(([id, n]) => `${accounts.find((a) => a.id === id)?.nickname ?? 'an account'} (${String(n)})`)
    .join(', ');
  const who = bankName ?? 'the statement';
  return (
    <div className="stack gap-xs">
      <Notice icon="bank" message={placed ? `Each payment goes to the account ${who} names: ${placed}.` : `None of the accounts ${who} names is one of yours yet.`} />
      {unmatched ? (
        <Notice
          icon="warning"
          tone="var(--warning)"
          message={`${String(unmatched)} ${unmatched === 1 ? 'payment names an account' : 'payments name accounts'} that could not be matched to yours. Choose the account on ${unmatched === 1 ? 'it' : 'each'} — nothing is put in an account you did not choose.`}
        />
      ) : null}
    </div>
  );
}

const NEEDS: Record<string, string> = {
  account: 'Choose account',
  transferTarget: 'Choose account',
  loanPerson: 'Who?',
  loan: 'Which loan?',
  settles: 'Which purchase?',
  settlePerson: 'Who?',
  paidForPerson: 'Who?',
};

function ReviewRow({
  item,
  items,
  categories,
  accounts,
  cards,
  claims,
  currency,
  treatments,
  showAccount,
  onToggle,
  onOpen,
  onKind,
}: {
  item: ReviewItem;
  items: readonly ReviewItem[];
  categories: readonly ExpenseCategory[];
  accounts: readonly BankAccount[];
  cards: readonly CreditCard[];
  claims: readonly ClaimSummary[];
  currency: string;
  /** Migration 005 is in place: loans and reimbursements can be chosen. */
  treatments: boolean;
  /** The row comes from a statement covering several accounts: say which one it went to. */
  showAccount: boolean;
  onToggle: () => void;
  onOpen: () => void;
  onKind: (kind: TransactionKind) => void;
}) {
  const category = item.kind === 'expense' ? categories.find((c) => c.id === item.categoryId) : undefined;
  const owed = item.kind === 'loan' || item.kind === 'reimbursement';
  const avatar =
    item.kind === 'transfer' ? (
      <TransferAvatar />
    ) : owed ? (
      <ClaimAvatar />
    ) : category ? (
      <CategoryAvatar icon={category.icon} color={category.color} />
    ) : (
      <LedgerAvatar credit={item.transactionType === 'credit'} />
    );
  const detail = rowDetail(item, { items, categories, accounts, cards, claims });
  const missing = detailProblem(item);
  const blocking = isBlockingDuplicate(item.duplicate);
  // Neither income nor spending: shown in the neutral transfer tone.
  const neutral = item.kind === 'transfer' || owed || (item.kind === 'expense' && item.reimbursable);
  const pillTone = neutral ? 'var(--transfer)' : item.transactionType === 'credit' ? 'var(--income)' : 'var(--primary)';
  const kinds = availableKinds(item.transactionType, treatments);
  return (
    <div className={[styles.item, !item.selected && styles.itemOff].filter(Boolean).join(' ')}>
      <button type="button" className={styles.check} role="checkbox" aria-checked={item.selected} aria-label={`Import ${item.description}`} onClick={onToggle}>
        <span className={[styles.box, item.selected && styles.boxOn].filter(Boolean).join(' ')}>{item.selected ? <Icon name="check" size={14} /> : null}</span>
      </button>
      <div className={styles.itemMain}>
        <button type="button" className={styles.itemBody} onClick={onOpen}>
          {avatar}
          <span className={styles.itemText}>
            <span className={styles.itemTitle}>{item.counterparty ?? item.description}</span>
            <span className={styles.itemMeta}>
              {detail ? <span className="t-ellipsis">{detail}</span> : null}
              {showAccount && item.bankAccountId ? (
                <span className={styles.metaAccount}>
                  <Icon name="bank" size={12} />
                  {accounts.find((a) => a.id === item.bankAccountId)?.nickname ?? 'Account'}
                </span>
              ) : null}
              {item.tags?.map((tag) => (
                <span key={tag} className={styles.metaTag}>
                  #{tag}
                </span>
              ))}
              {item.duplicate ? <Badge label={duplicateBadge(item.duplicate)} icon="copy" tone={blocking ? 'var(--warning)' : undefined} /> : null}
              {needsAttention(item) ? <Badge label="Check" icon="factCheck" tone="var(--warning)" /> : null}
              {isUncategorized(item) && !item.duplicate ? <Badge label="Uncategorised" /> : null}
            </span>
          </span>
          <Money
            amount={item.transactionType === 'credit' ? item.amount : -item.amount}
            currency={currency}
            tone={neutral ? 'transfer' : item.transactionType === 'credit' ? 'positive' : 'negative'}
            signed
            emphasis
            className={styles.itemAmount}
          />
        </button>
        <div className={styles.itemTools}>
          <label className={styles.pill} style={{ '--tone': pillTone } as CSSProperties}>
            <span>{kindLabel(item.kind, item.transactionType)}</span>
            <Icon name="chevronDown" size={14} />
            <select value={item.kind} aria-label={`Record ${item.counterparty ?? item.description} as`} onChange={(e) => onKind(e.target.value as TransactionKind)}>
              {kinds.map((kind) => (
                <option key={kind} value={kind}>
                  {kindLabel(kind, item.transactionType)}
                </option>
              ))}
            </select>
          </label>
          {missing ? (
            <button type="button" className={styles.needs} onClick={onOpen}>
              <Badge label={NEEDS[missing] ?? 'Add details'} icon="edit" tone="var(--warning)" />
            </button>
          ) : null}
        </div>
      </div>
    </div>
  );
}
