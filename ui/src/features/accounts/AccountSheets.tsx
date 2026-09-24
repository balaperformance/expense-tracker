import { useState, type CSSProperties } from 'react';

import { Money } from '@/components/finance/Money';
import { Button, IconButton } from '@/components/ui/Button';
import { Chip, ChipGroup, Segmented } from '@/components/ui/Chip';
import { InlineError } from '@/components/ui/Feedback';
import { AmountField, DateField, FieldLabel, TextField } from '@/components/ui/Fields';
import { Icon } from '@/components/ui/Icon';
import { Sheet } from '@/components/ui/Sheet';
import { Card, IconWell } from '@/components/ui/Surface';
import { accountLabel, currentBalance, MONEY_TRANSFER_LABEL, type BankAccount, type BankAccountBalance } from '@/domain/models';
import { useDeleteAccount, useRecordMovement, useSaveAccount, useTransfer } from '@/hooks/mutations';
import { errorMessage } from '@/lib/errors';
import { today } from '@/lib/dates';
import { amountToInput, parseAmount, sanitiseAmountInput, validateAmount, validateRequired } from '@/lib/validators';
import { accountMovementCount } from '@/services/accounts';
import { useUserId } from '@/state/auth';
import { useFeedback } from '@/state/feedback';
import { useSettings } from '@/state/settings';

import styles from './Accounts.module.css';

// ---------------------------------------------------------------------------
// Add / edit account (AccountFormSheet)
// ---------------------------------------------------------------------------

export function AccountFormSheet({ open, account, onClose }: { open: boolean; account: BankAccount | null; onClose: () => void }) {
  const userId = useUserId();
  const { symbol } = useSettings();
  const { toast, confirm } = useFeedback();
  const save = useSaveAccount();
  const remove = useDeleteAccount();
  const editing = account != null;
  const [bankName, setBankName] = useState(account?.bankName ?? '');
  const [nickname, setNickname] = useState(account?.nickname ?? '');
  const [last4, setLast4] = useState(account?.last4 ?? '');
  const [opening, setOpening] = useState(account ? amountToInput(account.openingBalance) : '');
  const [errors, setErrors] = useState<Partial<Record<'bank' | 'nickname' | 'opening', string | null>>>({});
  const [error, setError] = useState<string | null>(null);
  const busy = save.isPending || remove.isPending;

  const validateOpening = (value: string) => {
    if (!value.trim()) return 'Opening balance is required';
    const parsed = parseAmount(value);
    if (parsed == null) return 'Enter a valid number';
    if (Math.abs(parsed) > 999_999_999) return 'Amount is too large';
    return null;
  };

  const submit = async () => {
    const next = { bank: validateRequired(bankName, 'Bank name'), nickname: validateRequired(nickname, 'Nickname'), opening: validateOpening(opening) };
    setErrors(next);
    if (next.bank || next.nickname || next.opening) return;
    setError(null);
    try {
      await save.mutateAsync({
        id: account?.id,
        draft: { bankName, nickname, last4: last4 || null, openingBalance: parseAmount(opening) ?? 0 },
      });
      toast('success', editing ? 'Account updated' : 'Account added');
      onClose();
    } catch (failure) {
      setError(errorMessage(failure, 'Could not save the account.'));
    }
  };

  const confirmDelete = async () => {
    if (!account) return;
    const movements = await accountMovementCount(userId, account.id);
    const ok = await confirm({
      title: `Delete "${account.nickname}"?`,
      message:
        movements === 0
          ? 'This account has no transactions. This cannot be undone.'
          : `Its ${movements} ${movements === 1 ? 'transaction' : 'transactions'} will be removed too. Linked expenses and income are kept but revert to Cash / untracked. This cannot be undone.`,
    });
    if (!ok) return;
    try {
      await remove.mutateAsync(account.id);
      toast('success', 'Account deleted');
      onClose();
    } catch (failure) {
      setError(errorMessage(failure, 'Could not delete the account.'));
    }
  };

  return (
    <Sheet
      open={open}
      onClose={onClose}
      busy={busy}
      title={editing ? 'Edit account' : 'New bank account'}
      subtitle={editing ? account.bankName : 'Track its balance and statement'}
      action={editing ? <IconButton icon="delete" label="Delete account" color="var(--error)" disabled={busy} onClick={() => void confirmDelete()} /> : null}
      footer={<Button label={editing ? 'Save changes' : 'Add account'} size="lg" block busy={save.isPending} busyLabel="Saving…" onClick={() => void submit()} />}
    >
      <div>
        <FieldLabel text="Bank" required />
        <TextField value={bankName} onChange={setBankName} placeholder="HDFC, ICICI, SBI…" aria-label="Bank" icon="bank" autoCapitalize="words" disabled={busy} error={errors.bank} />
      </div>
      <div>
        <FieldLabel text="Nickname" required />
        <TextField value={nickname} onChange={setNickname} placeholder="Salary account, Joint savings…" aria-label="Nickname" icon="badge" autoCapitalize="words" disabled={busy} error={errors.nickname} />
      </div>
      <div>
        <FieldLabel text="Last 4 digits" hint="Optional" />
        <TextField
          value={last4}
          onChange={(v) => setLast4(v.replace(/\D/g, '').slice(0, 4))}
          placeholder="4821"
          aria-label="Last 4 digits"
          icon="tag"
          inputMode="numeric"
          maxLength={4}
          disabled={busy}
        />
      </div>
      <div>
        <FieldLabel text="Opening balance" required />
        <TextField
          value={opening}
          onChange={(v) => setOpening(sanitiseAmountInput(v, true))}
          prefix={symbol}
          placeholder="0"
          aria-label="Opening balance"
          inputMode="decimal"
          disabled={busy}
          error={errors.opening}
          helper="The balance before any tracked transactions"
        />
      </div>
      {error ? <InlineError message={error} /> : null}
    </Sheet>
  );
}

// ---------------------------------------------------------------------------
// Money in / money out (DepositSheet)
// ---------------------------------------------------------------------------

const CREDIT_PRESETS = ['Deposit', 'Refund', 'Interest', 'Cashback'];
const DEBIT_PRESETS = ['Withdrawal', 'Bank charge', 'ATM', 'Fee'];

export function MovementSheet({ open, account, onClose }: { open: boolean; account: BankAccount; onClose: () => void }) {
  const { symbol } = useSettings();
  const { toast } = useFeedback();
  const record = useRecordMovement();
  const [out, setOut] = useState(false);
  const [amount, setAmount] = useState('');
  const [description, setDescription] = useState('');
  const [date, setDate] = useState(today());
  const [submitted, setSubmitted] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const presets = out ? DEBIT_PRESETS : CREDIT_PRESETS;

  const submit = async () => {
    setSubmitted(true);
    if (validateAmount(amount)) return;
    setError(null);
    try {
      await record.mutateAsync({
        accountId: account.id,
        direction: out ? 'debit' : 'credit',
        amount: parseAmount(amount) ?? 0,
        date,
        description,
      });
      toast('success', out ? 'Debit recorded' : 'Money added');
      onClose();
    } catch (failure) {
      setError(errorMessage(failure, 'Could not record the transaction.'));
    }
  };

  return (
    <Sheet
      open={open}
      onClose={onClose}
      busy={record.isPending}
      title={out ? 'Take money out' : 'Add money'}
      subtitle={accountLabel(account)}
      footer={
        <Button label={out ? 'Record debit' : 'Add money'} size="lg" block busy={record.isPending} busyLabel="Saving…" onClick={() => void submit()} />
      }
    >
      <Segmented
        label="Direction"
        value={out ? 'out' : 'in'}
        onChange={(v) => setOut(v === 'out')}
        options={[
          { value: 'in', label: 'Money in', icon: 'moneyIn' },
          { value: 'out', label: 'Money out', icon: 'moneyOut' },
        ]}
        disabled={record.isPending}
      />
      <AmountField
        value={amount}
        onChange={setAmount}
        symbol={symbol}
        tone={out ? 'var(--expense)' : 'var(--income)'}
        disabled={record.isPending}
        error={submitted ? validateAmount(amount) : null}
      />
      <div>
        <FieldLabel text="Date" required />
        <DateField value={date} onChange={setDate} disabled={record.isPending} />
      </div>
      <div className="stack gap-sm">
        <FieldLabel text="Description" />
        <TextField value={description} onChange={setDescription} placeholder="What was this for?" aria-label="Description" icon="text" disabled={record.isPending} />
        <ChipGroup label="Suggestions">
          {presets.map((preset) => (
            <Chip key={preset} label={preset} selected={description.trim() === preset} onClick={() => setDescription(preset)} disabled={record.isPending} />
          ))}
        </ChipGroup>
      </div>
      {error ? <InlineError message={error} /> : null}
    </Sheet>
  );
}

// ---------------------------------------------------------------------------
// Transfer (TransferSheet)
// ---------------------------------------------------------------------------

export function TransferSheet({
  open,
  balances,
  fromAccountId,
  onClose,
}: {
  open: boolean;
  balances: BankAccountBalance[];
  fromAccountId: string | null;
  onClose: () => void;
}) {
  const { symbol, currency } = useSettings();
  const { toast } = useFeedback();
  const transfer = useTransfer();
  const accounts = balances.map((b) => b.account);
  const initialFrom = fromAccountId ?? accounts[0]?.id ?? null;
  const [from, setFrom] = useState<string | null>(initialFrom);
  const [to, setTo] = useState<string | null>(accounts.find((a) => a.id !== initialFrom)?.id ?? null);
  const [amount, setAmount] = useState('');
  const [date, setDate] = useState(today());
  const [note, setNote] = useState('');
  const [error, setError] = useState<string | null>(null);

  const source = balances.find((b) => b.account.id === from);
  const destination = balances.find((b) => b.account.id === to);
  const typed = parseAmount(amount);

  const submit = async () => {
    setError(null);
    try {
      await transfer.mutateAsync({ draft: { fromAccountId: from, toAccountId: to, amount: typed, date, note }, accounts, currency });
      toast('success', 'Transfer complete');
      onClose();
    } catch (failure) {
      setError(errorMessage(failure, 'Could not complete the transfer.'));
    }
  };

  const after = source && typed != null && typed > 0 ? currentBalance(source) - typed : null;

  return (
    <Sheet
      open={open}
      onClose={onClose}
      busy={transfer.isPending}
      title="Transfer money"
      subtitle="Between your own accounts · not income or spending"
      footer={<Button label="Transfer" icon="transfer" size="lg" block busy={transfer.isPending} busyLabel="Transferring…" onClick={() => void submit()} />}
    >
      <AmountField value={amount} onChange={setAmount} symbol={symbol} tone="var(--transfer)" disabled={transfer.isPending} />

      <Card>
        <div className="stack">
          <RoutePicker
            label="From"
            icon="moneyOut"
            tone="var(--expense)"
            balances={balances}
            value={from}
            currency={currency}
            disabled={transfer.isPending}
            onChange={(id) => {
              setFrom(id);
              if (id === to) setTo(null);
            }}
          />
          <div className={styles.routeDivider}>
            <span className={styles.routeLine} />
            <IconButton
              icon="swapVertical"
              label="Swap accounts"
              small
              disabled={!to || transfer.isPending}
              onClick={() => {
                setFrom(to);
                setTo(from);
              }}
            />
          </div>
          <RoutePicker
            label="To"
            icon="moneyIn"
            tone="var(--income)"
            balances={balances.filter((b) => b.account.id !== from)}
            value={to}
            currency={currency}
            disabled={transfer.isPending}
            onChange={setTo}
          />
        </div>
      </Card>

      {source && after != null ? (
        <div className={styles.preview} data-short={after < 0 || undefined}>
          <span className="t-label-sm t-center">After this transfer</span>
          <div className="row gap-sm">
            <span className="grow t-body-sm t-ellipsis">{source.account.nickname}</span>
            <Money amount={after} currency={currency} tone={after < 0 ? 'negative' : 'neutral'} className="t-title-sm" />
          </div>
          {destination && typed != null ? (
            <div className="row gap-sm">
              <span className="grow t-body-sm t-ellipsis">{destination.account.nickname}</span>
              <Money amount={currentBalance(destination) + typed} currency={currency} className="t-title-sm" />
            </div>
          ) : null}
          {after < 0 ? (
            <p className="t-body-sm t-center" style={{ color: 'var(--expense)' }}>
              That is more than {source.account.nickname} holds.
            </p>
          ) : null}
        </div>
      ) : null}

      <div>
        <FieldLabel text="Date" required />
        <DateField value={date} onChange={setDate} disabled={transfer.isPending} />
      </div>
      <div>
        <FieldLabel text="Note" hint="Optional" />
        <TextField value={note} onChange={setNote} placeholder="Rent set aside, savings top-up…" aria-label="Note" icon="text" disabled={transfer.isPending} />
      </div>
      {error ? <InlineError message={error} /> : null}
      <p className="t-label-sm t-center row gap-xs" style={{ justifyContent: 'center' }}>
        <Icon name="info" size={14} />
        Shows as {MONEY_TRANSFER_LABEL} on both statements.
      </p>
    </Sheet>
  );
}

function RoutePicker({
  label,
  icon,
  tone,
  balances,
  value,
  currency,
  disabled,
  onChange,
}: {
  label: string;
  icon: 'moneyIn' | 'moneyOut';
  tone: string;
  balances: BankAccountBalance[];
  value: string | null;
  currency: string;
  disabled?: boolean;
  onChange: (id: string | null) => void;
}) {
  const selected = balances.find((b) => b.account.id === value);
  return (
    <label className={styles.route} style={{ '--tone': tone } as CSSProperties}>
      <IconWell icon={icon} tone={tone} size={30} />
      <span className="grow stack">
        <span className="t-label-sm">{label}</span>
        <span className={styles.routeSelect}>
          <select value={selected ? value ?? '' : ''} onChange={(e) => onChange(e.target.value || null)} disabled={disabled} aria-label={`${label} account`}>
            <option value="">Select an account</option>
            {balances.map((b) => (
              <option key={b.account.id} value={b.account.id}>
                {accountLabel(b.account)}
              </option>
            ))}
          </select>
          <Icon name="chevronDown" size={18} />
        </span>
      </span>
      {selected ? <Money amount={currentBalance(selected)} currency={currency} compact className="t-body-sm" /> : null}
    </label>
  );
}
