import { useState } from 'react';
import { useLocation, useNavigate, useParams } from 'react-router';

import { Page } from '@/components/layout/Page';
import { AccountChips, CategoryChips, PaymentMethodChips } from '@/components/finance/Pickers';
import { Button, IconButton } from '@/components/ui/Button';
import { Centered, EmptyState, InlineError, ListSkeleton, Notice } from '@/components/ui/Feedback';
import { AmountField, DateField, FieldLabel, TextArea, TextField } from '@/components/ui/Fields';
import { Card, IconWell } from '@/components/ui/Surface';
import type { Expense } from '@/domain/models';
import type { ExpensePrefill } from '@/domain/prefill';
import type { ReceiptResult } from '@/domain/receipt/result';
import { useAccounts, useCapabilities, useCategories, useExpense, usePaymentMethods } from '@/hooks/data';
import { useGoBack } from '@/hooks/useGoBack';
import { useDeleteExpense, useSaveExpense } from '@/hooks/mutations';
import { phase2Ready } from '@/services/capabilities';
import { errorMessage } from '@/lib/errors';
import { dayMonthYear, formatCurrency } from '@/lib/format';
import { today } from '@/lib/dates';
import { amountToInput, parseAmount, validateAmount } from '@/lib/validators';
import { useFeedback } from '@/state/feedback';
import { useSettings } from '@/state/settings';

import { ReceiptReview } from '../receipt/ReceiptReview';
import { ScanSheet } from '../receipt/ScanSheet';

import styles from './Expenses.module.css';

/** `/expenses/new` (optionally with a prefill in the route state) and `/expenses/:id`. */
export function ExpenseFormPage() {
  const { id } = useParams();
  const location = useLocation();
  const prefill = (location.state as { prefill?: ExpensePrefill } | null)?.prefill;
  const existing = useExpense(id);

  if (id) {
    if (existing.isPending) {
      return (
        <Page title="Edit expense" back="/expenses" narrow>
          <ListSkeleton rows={4} />
        </Page>
      );
    }
    if (!existing.data) {
      return (
        <Page title="Edit expense" back="/expenses" narrow>
          <Centered>
            <EmptyState icon="searchOff" title="Expense not found" message="It may have been deleted on another device." />
          </Centered>
        </Page>
      );
    }
    return <ExpenseForm key={existing.data.id} expense={existing.data} />;
  }
  return <ExpenseForm key={location.key} prefill={prefill} />;
}

function ExpenseForm({ expense, prefill }: { expense?: Expense; prefill?: ExpensePrefill }) {
  const navigate = useNavigate();
  const goBack = useGoBack('/expenses');
  const { symbol, currency } = useSettings();
  const { toast, confirm } = useFeedback();
  const caps = useCapabilities();
  const categories = useCategories().data ?? [];
  const methods = usePaymentMethods().data ?? [];
  const accounts = (useAccounts().data ?? []).map((b) => b.account);
  const save = useSaveExpense();
  const remove = useDeleteExpense();
  const editing = expense != null;
  const seed = expense ?? null;

  const [amount, setAmount] = useState(seed ? amountToInput(seed.amount) : prefill?.amount != null ? amountToInput(prefill.amount) : '');
  const [merchant, setMerchant] = useState(seed?.merchant ?? prefill?.merchant ?? '');
  const [description, setDescription] = useState(seed?.description ?? prefill?.description ?? '');
  const [notes, setNotes] = useState(seed?.notes ?? prefill?.notes ?? '');
  const [categoryId, setCategoryId] = useState<string | null>(seed?.categoryId ?? prefill?.categoryId ?? null);
  const [paymentMethodId, setPaymentMethodId] = useState<string | null>(seed?.paymentMethodId ?? prefill?.paymentMethodId ?? null);
  const [bankAccountId, setBankAccountId] = useState<string | null>(seed?.bankAccountId ?? null);
  const [date, setDate] = useState(seed?.expenseDate ?? prefill?.date ?? today());
  const [fromScan, setFromScan] = useState(prefill?.source === 'receiptScan');
  const [submitted, setSubmitted] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [scanOpen, setScanOpen] = useState(false);
  const [receipt, setReceipt] = useState<ReceiptResult | null>(null);

  const busy = save.isPending || remove.isPending;
  const amountError = submitted ? validateAmount(amount) : null;
  const categoryMissing = submitted && categoryId == null;

  const applyPrefill = (scanned: ExpensePrefill) => {
    if (scanned.amount != null) setAmount(amountToInput(scanned.amount));
    if (scanned.merchant) setMerchant(scanned.merchant);
    if (scanned.description) setDescription(scanned.description);
    if (scanned.date) setDate(scanned.date);
    if (scanned.categoryId) setCategoryId(scanned.categoryId);
    if (scanned.paymentMethodId) setPaymentMethodId(scanned.paymentMethodId);
    setFromScan(true);
    setSubmitted(false);
    setError(null);
  };

  const submit = async () => {
    setSubmitted(true);
    setError(categoryId == null ? 'Choose a category for this expense.' : null);
    if (validateAmount(amount) || categoryId == null) return;
    try {
      await save.mutateAsync({
        id: expense?.id,
        draft: {
          amount: parseAmount(amount) ?? 0,
          expenseDate: date,
          categoryId,
          paymentMethodId,
          bankAccountId,
          merchant,
          description,
          notes,
        },
      });
      toast('success', editing ? 'Expense updated' : 'Expense added');
      goBack();
    } catch (failure) {
      setError(errorMessage(failure, 'Could not save the expense.'));
    }
  };

  const confirmDelete = async () => {
    if (!expense) return;
    const ok = await confirm({
      title: 'Delete expense?',
      message: `This removes ${formatCurrency(expense.amount, currency)} from ${dayMonthYear(expense.expenseDate)}. This cannot be undone.`,
    });
    if (!ok) return;
    try {
      await remove.mutateAsync(expense.id);
      toast('success', 'Expense deleted');
      goBack();
    } catch (failure) {
      setError(errorMessage(failure, 'Could not delete the expense.'));
    }
  };

  if (receipt) {
    return (
      <ReceiptReview
        result={receipt}
        onCancel={() => setReceipt(null)}
        onContinue={(scanned) => {
          applyPrefill(scanned);
          setReceipt(null);
        }}
      />
    );
  }

  return (
    <Page
      title={editing ? 'Edit expense' : 'Add expense'}
      back="/expenses"
      narrow
      actions={editing ? <IconButton icon="delete" label="Delete" disabled={busy} onClick={() => void confirmDelete()} /> : null}
      bar={
        <Button
          label={editing ? 'Save changes' : 'Add expense'}
          size="lg"
          block
          busy={save.isPending}
          busyLabel="Saving…"
          disabled={busy}
          onClick={() => void submit()}
        />
      }
    >
      {!editing ? (
        <div className="stack gap-sm">
          <EntryCard
            icon="scan"
            title="Scan a receipt"
            subtitle="Fill this form from a photo"
            action="Scan"
            actionIcon="camera"
            disabled={busy}
            onClick={() => setScanOpen(true)}
          />
          <EntryCard
            icon="sms"
            title="Paste bank SMS"
            subtitle="Read an alert from your bank"
            action="Paste"
            actionIcon="paste"
            disabled={busy}
            onClick={() => void navigate('/expenses/sms')}
          />
        </div>
      ) : null}

      {fromScan ? (
        <Notice icon="assistant" tone="var(--primary)" message="Filled in from your receipt. Change anything that is not right before saving." />
      ) : null}

      <AmountField value={amount} onChange={setAmount} symbol={symbol} tone="var(--expense)" autoFocus={!editing && !prefill} disabled={busy} error={amountError} />

      <div>
        <FieldLabel text="Category" required hint={categoryMissing ? 'Pick one' : null} hintIsError={categoryMissing} />
        <CategoryChips
          categories={categories}
          isSelected={(cid) => cid === categoryId}
          onToggle={(cid) => {
            setCategoryId(cid);
            setError(null);
          }}
          disabled={busy}
          error={categoryMissing}
        />
      </div>

      <div>
        <FieldLabel text="Date" required />
        <DateField value={date} onChange={setDate} disabled={busy} />
      </div>

      {phase2Ready(caps) ? (
        <div>
          <FieldLabel text="Paid from" required hint={bankAccountId == null ? 'No balance affected' : null} />
          {accounts.length ? (
            <AccountChips accounts={accounts} selectedId={bankAccountId} onSelect={setBankAccountId} disabled={busy} />
          ) : (
            <Notice message="Add a bank account to track expenses against a balance. Until then everything is recorded as cash." />
          )}
        </div>
      ) : null}

      <div>
        <FieldLabel text="Details" hint="Optional" />
        <Card>
          <div className="stack gap-sm">
            {caps.merchant ? (
              <TextField value={merchant} onChange={setMerchant} placeholder="Merchant" aria-label="Merchant" icon="store" autoCapitalize="words" disabled={busy} />
            ) : null}
            <TextField value={description} onChange={setDescription} placeholder="Description" aria-label="Description" icon="text" autoCapitalize="sentences" disabled={busy} />
            <TextArea value={notes} onChange={setNotes} placeholder="Notes" aria-label="Notes" icon="notes" disabled={busy} />
            {methods.length ? (
              <div className={styles.subField}>
                <span className="t-label-md">Payment method</span>
                <PaymentMethodChips methods={methods} selectedId={paymentMethodId} onSelect={setPaymentMethodId} disabled={busy} />
              </div>
            ) : null}
          </div>
        </Card>
      </div>

      {!caps.merchant ? (
        <Notice message='Merchant is hidden because the expenses table has no "merchant" column yet. Run the migration from the setup notes to enable it.' />
      ) : null}

      {error ? <InlineError message={error} /> : null}

      <ScanSheet open={scanOpen} onClose={() => setScanOpen(false)} onScanned={setReceipt} />
    </Page>
  );
}

/** "Scan a receipt" / "Paste bank SMS" entry points at the top of a new expense. */
function EntryCard({
  icon,
  title,
  subtitle,
  action,
  actionIcon,
  onClick,
  disabled,
}: {
  icon: 'scan' | 'sms';
  title: string;
  subtitle: string;
  action: string;
  actionIcon: 'camera' | 'paste';
  onClick: () => void;
  disabled?: boolean;
}) {
  return (
    <Card padding="flush">
      <div className={styles.entry}>
        <IconWell icon={icon} size={30} />
        <div className="grow stack">
          <span className="t-title-sm">{title}</span>
          <span className="t-body-sm t-ellipsis">{subtitle}</span>
        </div>
        <Button label={action} icon={actionIcon} size="sm" variant="tonal" onClick={onClick} disabled={disabled} />
      </div>
    </Card>
  );
}
