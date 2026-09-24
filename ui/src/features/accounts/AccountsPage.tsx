import { useQueryClient } from '@tanstack/react-query';
import { useState } from 'react';
import { useNavigate } from 'react-router';

import { Page } from '@/components/layout/Page';
import { BankAvatar } from '@/components/finance/Avatars';
import { Money } from '@/components/finance/Money';
import { Button, Fab, IconButton } from '@/components/ui/Button';
import { Centered, EmptyState, ErrorView, ListSkeleton, Notice } from '@/components/ui/Feedback';
import { Icon, type IconName } from '@/components/ui/Icon';
import { Card, Hero, IconWell, SectionHeader } from '@/components/ui/Surface';
import { accountBankLine, accountInitial, currentBalance, type BankAccount } from '@/domain/models';
import { useAccounts, useCapabilities } from '@/hooks/data';
import { useSheet } from '@/hooks/useSheet';
import { errorMessage } from '@/lib/errors';
import { missingSummary, resolveCapabilities } from '@/services/capabilities';
import { useUserId } from '@/state/auth';
import { keys } from '@/state/queryClient';
import { useSettings } from '@/state/settings';

import { AccountFormSheet, MovementSheet, TransferSheet } from './AccountSheets';
import styles from './Accounts.module.css';

type SheetState =
  | { kind: 'form'; account: BankAccount | null }
  | { kind: 'movement'; account: BankAccount }
  | { kind: 'transfer'; from: string | null };

export function AccountsPage() {
  const navigate = useNavigate();
  const userId = useUserId();
  const client = useQueryClient();
  const { currency } = useSettings();
  const caps = useCapabilities();
  const accounts = useAccounts();
  const { data: sheet, isOpen: sheetOpen, key: sheetKey, open, close } = useSheet<SheetState>();
  const [rechecking, setRechecking] = useState(false);

  const balances = accounts.data ?? [];
  const transfersAvailable = caps.bankAccounts && caps.transfers;
  const canTransfer = transfersAvailable && balances.length >= 2;
  const total = balances.reduce((sum, b) => sum + currentBalance(b), 0);

  const recheck = async () => {
    setRechecking(true);
    try {
      client.setQueryData(keys.capabilities(userId), await resolveCapabilities(true));
    } finally {
      setRechecking(false);
    }
  };

  let body;
  if (!caps.bankAccounts) {
    body = (
      <Centered>
        <div className="stack gap-md" style={{ alignItems: 'center', textAlign: 'center', maxWidth: 380 }}>
          <IconWell icon="database" size={54} />
          <h2 className="t-headline-sm">One migration away</h2>
          <p className="t-body-sm">
            Bank accounts need the Phase 2 tables. Run supabase/002_phase2_bank_accounts_and_ledger.sql and then
            supabase/003_phase2_transfers.sql in the Supabase SQL editor.
          </p>
          <Notice icon="database" message={`Missing: ${missingSummary(caps)}`} />
          <Button label="Check again" icon="refresh" busy={rechecking} onClick={() => void recheck()} />
          <p className="t-label-sm">Every other feature keeps working without this.</p>
        </div>
      </Centered>
    );
  } else if (accounts.isPending) {
    body = <ListSkeleton rows={4} />;
  } else if (accounts.isError && !balances.length) {
    body = (
      <Centered>
        <ErrorView message={errorMessage(accounts.error)} onRetry={() => void accounts.refetch()} />
      </Centered>
    );
  } else if (!balances.length) {
    body = (
      <Centered>
        <EmptyState
          icon="bank"
          title="No accounts yet"
          message="Add an account to track its balance and see a full transaction statement."
          actionLabel="Add account"
          onAction={() => open({ kind: 'form', account: null })}
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
                Total balance
              </span>
              <Money amount={total} currency={currency} tone={total < 0 ? 'negative' : 'neutral'} className={styles.total} animate />
              <span className="t-body-sm">
                Across {balances.length} {balances.length === 1 ? 'account' : 'accounts'}
              </span>
            </div>
            <IconWell icon="bankSolid" tone="var(--hero-accent)" size={44} />
          </div>
        </Hero>
        {transfersAvailable ? (
          <div>
            <Button
              label={canTransfer ? 'Transfer' : 'Add a second account to transfer'}
              icon="transfer"
              variant="tonal"
              disabled={!canTransfer}
              onClick={() => open({ kind: 'transfer', from: null })}
            />
          </div>
        ) : (
          <Notice icon="transfer" message="Transfers need supabase/003_phase2_transfers.sql. Everything else here works without it." />
        )}
        <div>
          <SectionHeader title="Your accounts" />
          <div className={styles.grid}>
            {balances.map((balance) => {
              const value = currentBalance(balance);
              const account = balance.account;
              return (
                <Card key={account.id} padding="flush">
                  <button type="button" className={styles.accountHead} onClick={() => void navigate(`/accounts/${account.id}`)}>
                    <BankAvatar initial={accountInitial(account)} size={42} />
                    <span className="grow stack gap-xs" style={{ minWidth: 0 }}>
                      <span className="t-title-md t-ellipsis">{account.nickname}</span>
                      <span className="t-body-sm t-ellipsis">{accountBankLine(account)}</span>
                    </span>
                    <span className={styles.accountBalance}>
                      <Money amount={value} currency={currency} tone={value < 0 ? 'negative' : 'neutral'} className="t-headline-sm" />
                      <span className="t-label-sm">Available</span>
                    </span>
                  </button>
                  <div className={styles.accountActions}>
                    <CardAction icon="expenses" label="Statement" onClick={() => void navigate(`/accounts/${account.id}`)} />
                    <CardAction icon="add" label="Add money" onClick={() => open({ kind: 'movement', account })} />
                    {canTransfer ? <CardAction icon="transfer" label="Transfer" onClick={() => open({ kind: 'transfer', from: account.id })} /> : null}
                    <CardAction icon="edit" label="Edit" onClick={() => open({ kind: 'form', account })} />
                  </div>
                </Card>
              );
            })}
          </div>
        </div>
        <p className="t-label-sm t-center">Cash is tracked separately and never affects these balances.</p>
      </>
    );
  }

  return (
    <Page
      title="Accounts"
      back="/"
      actions={canTransfer ? <IconButton icon="transfer" label="Transfer" onClick={() => open({ kind: 'transfer', from: null })} /> : null}
    >
      {body}
      {caps.bankAccounts && balances.length ? <Fab label="Account" onClick={() => open({ kind: 'form', account: null })} /> : null}
      {sheet?.kind === 'form' ? <AccountFormSheet key={sheetKey} open={sheetOpen} account={sheet.account} onClose={close} /> : null}
      {sheet?.kind === 'movement' ? <MovementSheet key={sheetKey} open={sheetOpen} account={sheet.account} onClose={close} /> : null}
      {sheet?.kind === 'transfer' ? (
        <TransferSheet key={sheetKey} open={sheetOpen} balances={balances} fromAccountId={sheet.from} onClose={close} />
      ) : null}
    </Page>
  );
}

function CardAction({ icon, label, onClick }: { icon: IconName; label: string; onClick: () => void }) {
  return (
    <button type="button" className={styles.accountAction} onClick={onClick} title={label} aria-label={label}>
      <Icon name={icon} size={19} />
      <span className={styles.accountActionLabel}>{label}</span>
    </button>
  );
}
