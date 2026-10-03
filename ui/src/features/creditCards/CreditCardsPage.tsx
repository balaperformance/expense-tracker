import { useQueryClient } from '@tanstack/react-query';
import { useState } from 'react';
import { useNavigate } from 'react-router';

import { Page } from '@/components/layout/Page';
import { CardAvatar } from '@/components/finance/Avatars';
import { Money } from '@/components/finance/Money';
import { Button, Fab } from '@/components/ui/Button';
import { Centered, EmptyState, ErrorView, ListSkeleton, Notice } from '@/components/ui/Feedback';
import { Icon, type IconName } from '@/components/ui/Icon';
import { Card, Hero, IconWell, SectionHeader } from '@/components/ui/Surface';
import { cardIssuerLine, cardLabel, type CreditCard } from '@/domain/models';
import { dueStatusText } from '@/domain/creditCards';
import { useCapabilities, useCreditCards, type CreditCardOverview } from '@/hooks/data';
import { useSheet } from '@/hooks/useSheet';
import { errorMessage } from '@/lib/errors';
import { formatCurrency } from '@/lib/format';
import { missingSummary, resolveCapabilities } from '@/services/capabilities';
import { useUserId } from '@/state/auth';
import { keys } from '@/state/queryClient';
import { useSettings } from '@/state/settings';

import { DueLine, UtilisationTrack } from './CardParts';
import { CardFormSheet, CardPaymentSheet } from './CardSheets';
import styles from './CreditCards.module.css';

type SheetState = { kind: 'form'; card: CreditCard | null } | { kind: 'pay'; overview: CreditCardOverview };

export function CreditCardsPage() {
  const navigate = useNavigate();
  const userId = useUserId();
  const client = useQueryClient();
  const { currency } = useSettings();
  const caps = useCapabilities();
  const cards = useCreditCards();
  const sheet = useSheet<SheetState>();
  const [rechecking, setRechecking] = useState(false);

  const list = cards.data ?? [];
  const active = list.filter((o) => o.card.isActive);
  const inactive = list.filter((o) => !o.card.isActive);
  // Everything owed counts, including a closed card still being paid off;
  // the limit and headroom only make sense for cards in use.
  const owed = list.reduce((sum, o) => sum + o.summary.outstanding, 0);
  const limit = active.reduce((sum, o) => sum + o.card.creditLimit, 0);
  const available = active.reduce((sum, o) => sum + o.summary.available, 0);
  // Utilisation compares like with like: what active cards owe against their limits.
  const activeOwed = active.reduce((sum, o) => sum + Math.max(o.summary.outstanding, 0), 0);
  const overdue = list.filter((o) => o.summary.lastStatement.status === 'overdue');

  const recheck = async () => {
    setRechecking(true);
    try {
      client.setQueryData(keys.capabilities(userId), await resolveCapabilities(true));
    } finally {
      setRechecking(false);
    }
  };

  const tile = (overview: CreditCardOverview) => (
    <CardTile
      key={overview.card.id}
      overview={overview}
      currency={currency}
      onOpen={() => void navigate(`/cards/${overview.card.id}`)}
      onPay={() => sheet.open({ kind: 'pay', overview })}
      onEdit={() => sheet.open({ kind: 'form', card: overview.card })}
    />
  );

  let body;
  if (!caps.creditCards) {
    body = (
      <Centered>
        <div className="stack gap-md" style={{ alignItems: 'center', textAlign: 'center', maxWidth: 380 }}>
          <IconWell icon="database" size={54} />
          <h2 className="t-headline-sm">One migration away</h2>
          <p className="t-body-sm">
            Credit cards need their tables. Run ui/supabase/004_credit_cards.sql in the Supabase SQL editor (after the bank-account
            migrations 002 and 003).
          </p>
          <Notice icon="database" message={`Missing: ${missingSummary(caps)}`} />
          <Button label="Check again" icon="refresh" busy={rechecking} onClick={() => void recheck()} />
          <p className="t-label-sm">Every other feature keeps working without this.</p>
        </div>
      </Centered>
    );
  } else if (cards.isPending) {
    body = <ListSkeleton rows={4} />;
  } else if (cards.isError && !list.length) {
    body = (
      <Centered>
        <ErrorView message={errorMessage(cards.error)} onRetry={() => void cards.refetch()} />
      </Centered>
    );
  } else if (!list.length) {
    body = (
      <Centered>
        <EmptyState
          icon="card"
          title="No credit cards yet"
          message="Add a card to track what you owe on it, its bills and due dates, and a full statement."
          actionLabel="Add card"
          onAction={() => sheet.open({ kind: 'form', card: null })}
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
                Total outstanding
              </span>
              <Money amount={owed} currency={currency} className={styles.total} animate />
              <span className="t-body-sm">
                Across {list.length} {list.length === 1 ? 'card' : 'cards'}
              </span>
            </div>
            <IconWell icon="cardSolid" tone="var(--hero-accent)" size={44} />
          </div>
          {limit > 0 ? (
            <div className={styles.heroFoot}>
              <UtilisationTrack ratio={activeOwed / limit} />
              <div className={styles.heroLegs}>
                <span className={styles.heroLeg}>
                  <span className="t-label-sm">Available</span>
                  <Money amount={available} currency={currency} className={styles.heroLegValue} />
                </span>
                <span className={styles.heroLeg}>
                  <span className="t-label-sm">Total limit</span>
                  <Money amount={limit} currency={currency} className={styles.heroLegValue} />
                </span>
              </div>
            </div>
          ) : null}
        </Hero>

        {overdue.map((o) => (
          <Notice
            key={o.card.id}
            icon="warning"
            tone="var(--expense)"
            message={`${cardLabel(o.card)}: ${formatCurrency(o.summary.lastStatement.remaining, currency)} — ${dueStatusText(o.summary.lastStatement).toLowerCase()}.`}
          />
        ))}

        {active.length ? (
          <div>
            <SectionHeader title="Your cards" />
            <div className={styles.grid}>{active.map(tile)}</div>
          </div>
        ) : null}
        {inactive.length ? (
          <div>
            <SectionHeader title="Inactive" caption="Kept for their history" />
            <div className={styles.grid}>{inactive.map(tile)}</div>
          </div>
        ) : null}
        <p className="t-label-sm t-center">
          Card purchases count as spending when you make them. Paying the bill moves money from your account to the card, so it is not counted again.
        </p>
      </>
    );
  }

  return (
    <Page title="Credit cards" back="/">
      {body}
      {caps.creditCards && list.length ? <Fab label="Card" onClick={() => sheet.open({ kind: 'form', card: null })} /> : null}
      {sheet.data?.kind === 'form' ? <CardFormSheet key={sheet.key} open={sheet.isOpen} card={sheet.data.card} onClose={sheet.close} /> : null}
      {sheet.data?.kind === 'pay' ? (
        <CardPaymentSheet key={sheet.key} open={sheet.isOpen} card={sheet.data.overview.card} summary={sheet.data.overview.summary} onClose={sheet.close} />
      ) : null}
    </Page>
  );
}

function CardTile({
  overview,
  currency,
  onOpen,
  onPay,
  onEdit,
}: {
  overview: CreditCardOverview;
  currency: string;
  onOpen: () => void;
  onPay: () => void;
  onEdit: () => void;
}) {
  const { card, summary } = overview;
  const credit = summary.outstanding < 0;
  return (
    <Card padding="flush">
      <button type="button" className={styles.cardHead} onClick={onOpen}>
        <CardAvatar size={42} />
        <span className="grow stack gap-xs" style={{ minWidth: 0 }}>
          <span className="t-title-md t-ellipsis">
            {card.cardName}
            {!card.isActive ? <span className={styles.inactiveTag}>Inactive</span> : null}
          </span>
          <span className="t-body-sm t-ellipsis">{cardIssuerLine(card)}</span>
        </span>
        <span className={styles.owed}>
          <Money amount={credit ? -summary.outstanding : summary.outstanding} currency={currency} tone={credit ? 'positive' : 'neutral'} className="t-headline-sm" />
          <span className="t-label-sm">{credit ? 'Credit balance' : 'Outstanding'}</span>
        </span>
      </button>
      <div className={styles.cardBody}>
        {card.creditLimit > 0 ? (
          <>
            <UtilisationTrack ratio={summary.utilisation} />
            <div className={styles.cardFacts}>
              <span>
                {summary.overLimit > 0
                  ? `${formatCurrency(summary.overLimit, currency)} over the limit`
                  : `${formatCurrency(summary.available, currency)} available`}
              </span>
              <span>Limit {formatCurrency(card.creditLimit, currency, { compact: true })}</span>
            </div>
          </>
        ) : null}
        <DueLine summary={summary} currency={currency} />
      </div>
      <div className={styles.cardActions}>
        <TileAction icon="expenses" label="Statement" onClick={onOpen} />
        <TileAction icon="transfer" label="Pay bill" onClick={onPay} />
        <TileAction icon="edit" label="Edit" onClick={onEdit} />
      </div>
    </Card>
  );
}

function TileAction({ icon, label, onClick }: { icon: IconName; label: string; onClick: () => void }) {
  return (
    <button type="button" className={styles.cardAction} onClick={onClick} title={label} aria-label={label}>
      <Icon name={icon} size={19} />
      <span className={styles.cardActionLabel}>{label}</span>
    </button>
  );
}
