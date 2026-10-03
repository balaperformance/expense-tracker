import { useState } from 'react';
import { useNavigate } from 'react-router';

import { Page } from '@/components/layout/Page';
import { ClaimAvatar } from '@/components/finance/Avatars';
import { ProgressTrack } from '@/components/finance/Budget';
import { Money } from '@/components/finance/Money';
import { Segmented } from '@/components/ui/Chip';
import { Badge, Centered, EmptyState, ErrorView, ListSkeleton, Notice } from '@/components/ui/Feedback';
import { Card, Hero, IconWell } from '@/components/ui/Surface';
import { accountLabel, cardLabel } from '@/domain/models';
import {
  balancesByPerson,
  CLAIM_STATUS_LABELS,
  claimTitle,
  dueText,
  isOpen,
  totalOutstanding,
  type ClaimSummary,
} from '@/domain/receivables';
import { useAccounts, useCapabilities, useClaims, useCreditCards } from '@/hooks/data';
import { today } from '@/lib/dates';
import { errorMessage } from '@/lib/errors';
import { dayMonthYear, formatCurrency } from '@/lib/format';
import { useSettings } from '@/state/settings';

import styles from './Receivables.module.css';

type Show = 'open' | 'settled' | 'all';

const SHOW: ReadonlyArray<{ value: Show; label: string }> = [
  { value: 'open', label: 'Still owed' },
  { value: 'settled', label: 'Settled' },
  { value: 'all', label: 'All' },
];

/**
 * Money owed to you: what you lent, and what you paid for others. None of it
 * is income or spending — the balance moved when the money went out and comes
 * back as each repayment arrives.
 */
export function ReceivablesPage() {
  const navigate = useNavigate();
  const { currency } = useSettings();
  const caps = useCapabilities();
  const claims = useClaims();
  const accounts = (useAccounts().data ?? []).map((b) => b.account);
  const cards = (useCreditCards().data ?? []).map((o) => o.card);
  const [show, setShow] = useState<Show>('open');
  const day = today();

  const all = claims.data ?? [];
  const shown = all.filter((c) => (show === 'all' ? true : show === 'open' ? isOpen(c.status) : !isOpen(c.status)));
  const groups = balancesByPerson(shown);
  const owed = totalOutstanding(all);
  const openCount = all.filter((c) => isOpen(c.status)).length;
  const people = balancesByPerson(all).filter((p) => p.open > 0).length;

  const fromLabel = (claim: ClaimSummary) => {
    const source = claim.source;
    if (!source) return null;
    if (source.cardId) {
      const card = cards.find((c) => c.id === source.cardId);
      return card ? cardLabel(card) : 'Credit card';
    }
    if (source.accountId) {
      const account = accounts.find((a) => a.id === source.accountId);
      return account ? accountLabel(account) : null;
    }
    return 'Cash';
  };

  /** Where the money went out: the account statement, or the expense. */
  const open = (claim: ClaimSummary) => {
    const source = claim.source;
    if (!source) return;
    if (claim.receivable.kind === 'reimbursable' && source.expenseId) void navigate(`/expenses/${source.expenseId}`);
    else if (source.accountId) void navigate(`/accounts/${source.accountId}`);
  };

  let body;
  if (!caps.treatments) {
    body = (
      <Centered>
        <EmptyState
          icon="database"
          title="One migration away"
          message="Loans and reimbursements need ui/supabase/005_transaction_treatments.sql. Run it in the Supabase SQL editor; everything else keeps working without it."
        />
      </Centered>
    );
  } else if (claims.isPending) {
    body = <ListSkeleton rows={4} />;
  } else if (claims.isError) {
    body = (
      <Centered>
        <ErrorView message={errorMessage(claims.error)} onRetry={() => void claims.refetch()} />
      </Centered>
    );
  } else if (!all.length) {
    body = (
      <Centered>
        <EmptyState
          icon="lend"
          title="Nobody owes you anything"
          message="On an account statement, tap money you lent and record it as a Loan. On an expense, turn on “Paid for someone else”. Repayments are matched to them the same way."
        />
      </Centered>
    );
  } else {
    body = (
      <>
        <Hero>
          <div className={styles.totalRow}>
            <div className="grow stack gap-xs">
              <span className="t-eyebrow" style={{ color: 'var(--hero-accent)' }}>
                Owed to you
              </span>
              <Money amount={owed} currency={currency} className={styles.total} animate />
              <span className="t-body-sm">
                {openCount
                  ? `${String(openCount)} open · ${String(people)} ${people === 1 ? 'person' : 'people'}`
                  : 'Everything has been paid back'}
              </span>
            </div>
            <IconWell icon="lend" tone="var(--hero-accent)" size={44} />
          </div>
        </Hero>
        <Notice icon="info" message="Not income or spending: your balance went down when the money went out, and goes up as it comes back." />
        <Segmented label="Show" value={show} options={SHOW} onChange={setShow} />
        {!groups.length ? (
          <EmptyState compact icon="lend" title="Nothing here" message={show === 'open' ? 'Everything has been paid back.' : 'Nothing settled yet.'} />
        ) : (
          groups.map((group) => (
            <section key={group.person}>
              <div className={styles.person}>
                <span className="t-title-md">{group.person}</span>
                {group.outstanding > 0 ? (
                  <span className="t-label-md">
                    owes <Money amount={group.outstanding} currency={currency} />
                  </span>
                ) : null}
              </div>
              <div className={styles.list}>
                {group.claims.map((claim) => (
                  <ClaimCard key={claim.receivable.id} claim={claim} currency={currency} from={fromLabel(claim)} day={day} onOpen={() => open(claim)} />
                ))}
              </div>
            </section>
          ))
        )}
      </>
    );
  }

  return (
    <Page title="Owed to you" back="/accounts">
      {body}
    </Page>
  );
}

function ClaimCard({
  claim,
  currency,
  from,
  day,
  onOpen,
}: {
  claim: ClaimSummary;
  currency: string;
  from: string | null;
  day: string;
  onOpen: () => void;
}) {
  const due = dueText(claim, day);
  const settled = !isOpen(claim.status);
  const tone = settled ? 'var(--income)' : claim.overdue ? 'var(--warning)' : 'var(--transfer)';
  return (
    <Card>
      <div className={styles.claim}>
        <button type="button" className={styles.claimHead} onClick={onOpen} aria-label={`Open ${claimTitle(claim.receivable)}`}>
          <ClaimAvatar />
          <span className={styles.claimText}>
            <span className="t-title-sm t-ellipsis">{claimTitle(claim.receivable)}</span>
            <span className={styles.meta}>
              <span className="t-ellipsis">
                {claim.source ? `${claim.source.title} · ${dayMonthYear(claim.source.date)}` : 'Its source is no longer available'}
              </span>
              {from ? <span className="t-ellipsis">· {from}</span> : null}
            </span>
          </span>
          <span className={styles.claimFigures}>
            <Money amount={Math.max(claim.outstanding, 0)} currency={currency} tone={settled ? 'neutral' : 'transfer'} emphasis />
            <span className="t-label-sm">of {formatCurrency(claim.principal, currency)}</span>
          </span>
        </button>
        <ProgressTrack ratio={claim.principal > 0 ? claim.received / claim.principal : 0} tone={tone} />
        <div className={styles.meta}>
          <Badge label={CLAIM_STATUS_LABELS[claim.status]} icon={settled ? 'checkCircle' : undefined} tone={tone} />
          {due ? <Badge label={due} icon="calendar" tone={claim.overdue ? 'var(--warning)' : undefined} /> : null}
          {claim.status === 'overpaid' ? <span>{formatCurrency(-claim.outstanding, currency)} more than lent</span> : null}
          {claim.receivable.note ? <span className="t-ellipsis">· {claim.receivable.note}</span> : null}
        </div>
        {claim.repayments.length ? (
          <ul className={styles.repayments} aria-label="Paid back">
            {claim.repayments.map((r) => (
              <li key={r.entryId}>
                <span>
                  {dayMonthYear(r.date)} · {r.description?.trim() || 'Repayment'}
                </span>
                <span>{formatCurrency(r.amount, currency)}</span>
              </li>
            ))}
          </ul>
        ) : null}
      </div>
    </Card>
  );
}
