import { useState } from 'react';
import { useParams } from 'react-router';

import { Page } from '@/components/layout/Page';
import { AccountChips } from '@/components/finance/Pickers';
import { Button, IconButton } from '@/components/ui/Button';
import { Chip, ChipGroup } from '@/components/ui/Chip';
import { Centered, EmptyState, InlineError, ListSkeleton, Notice } from '@/components/ui/Feedback';
import { AmountField, DateField, FieldLabel, TextArea, TextField } from '@/components/ui/Fields';
import { Card } from '@/components/ui/Surface';
import type { Income } from '@/domain/models';
import { useAccounts, useCapabilities, useIncomeItem } from '@/hooks/data';
import { useGoBack } from '@/hooks/useGoBack';
import { useDeleteIncome, useSaveIncome } from '@/hooks/mutations';
import { errorMessage } from '@/lib/errors';
import { dayMonthYear, formatCurrency } from '@/lib/format';
import { today } from '@/lib/dates';
import { amountToInput, parseAmount, validateAmount } from '@/lib/validators';
import { useFeedback } from '@/state/feedback';
import { useSettings } from '@/state/settings';

const COMMON_SOURCES = ['Salary', 'Freelance', 'Business', 'Interest', 'Dividends', 'Refund', 'Gift'];

export function IncomeFormPage() {
  const { id } = useParams();
  const existing = useIncomeItem(id);
  if (id) {
    if (existing.isPending) {
      return (
        <Page title="Edit income" back="/income" narrow>
          <ListSkeleton rows={3} />
        </Page>
      );
    }
    if (!existing.data) {
      return (
        <Page title="Edit income" back="/income" narrow>
          <Centered>
            <EmptyState icon="searchOff" title="Income not found" message="It may have been deleted on another device." />
          </Centered>
        </Page>
      );
    }
    return <IncomeForm key={existing.data.id} income={existing.data} />;
  }
  return <IncomeForm />;
}

function IncomeForm({ income }: { income?: Income }) {
  const goBack = useGoBack('/income');
  const { symbol, currency } = useSettings();
  const { toast, confirm } = useFeedback();
  const caps = useCapabilities();
  const accounts = (useAccounts().data ?? []).map((b) => b.account);
  const save = useSaveIncome();
  const remove = useDeleteIncome();
  const editing = income != null;

  const [amount, setAmount] = useState(income ? amountToInput(income.amount) : '');
  const [source, setSource] = useState(income?.source ?? '');
  const [description, setDescription] = useState(income?.description ?? '');
  const [date, setDate] = useState(income?.incomeDate ?? today());
  const [bankAccountId, setBankAccountId] = useState<string | null>(income?.bankAccountId ?? null);
  const [submitted, setSubmitted] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const busy = save.isPending || remove.isPending;
  const canLinkAccount = caps.bankAccounts && caps.incomeBankLink;

  const submit = async () => {
    setSubmitted(true);
    setError(null);
    if (validateAmount(amount)) return;
    try {
      await save.mutateAsync({
        id: income?.id,
        draft: { amount: parseAmount(amount) ?? 0, incomeDate: date, source, description, bankAccountId },
      });
      toast('success', editing ? 'Income updated' : 'Income added');
      goBack();
    } catch (failure) {
      setError(errorMessage(failure, 'Could not save the income.'));
    }
  };

  const confirmDelete = async () => {
    if (!income) return;
    const ok = await confirm({
      title: 'Delete income?',
      message: `This removes ${formatCurrency(income.amount, currency)} from ${dayMonthYear(income.incomeDate)}. This cannot be undone.`,
    });
    if (!ok) return;
    try {
      await remove.mutateAsync(income.id);
      toast('success', 'Income deleted');
      goBack();
    } catch (failure) {
      setError(errorMessage(failure, 'Could not delete the income.'));
    }
  };

  return (
    <Page
      title={editing ? 'Edit income' : 'Add income'}
      back="/income"
      narrow
      actions={editing ? <IconButton icon="delete" label="Delete" disabled={busy} onClick={() => void confirmDelete()} /> : null}
      bar={
        <Button
          label={editing ? 'Save changes' : 'Add income'}
          size="lg"
          block
          busy={save.isPending}
          busyLabel="Saving…"
          disabled={busy}
          onClick={() => void submit()}
        />
      }
    >
      <AmountField
        value={amount}
        onChange={setAmount}
        symbol={symbol}
        tone="var(--income)"
        autoFocus={!editing}
        disabled={busy}
        error={submitted ? validateAmount(amount) : null}
      />

      <div className="stack gap-sm">
        <FieldLabel text="Source" />
        <TextField value={source} onChange={setSource} placeholder="Salary, freelance, interest…" aria-label="Source" icon="work" autoCapitalize="words" disabled={busy} />
        <ChipGroup label="Common sources">
          {COMMON_SOURCES.map((option) => (
            <Chip
              key={option}
              label={option}
              selected={source.trim().toLowerCase() === option.toLowerCase()}
              disabled={busy}
              onClick={() => setSource(option)}
            />
          ))}
        </ChipGroup>
      </div>

      <div>
        <FieldLabel text="Date" required />
        <DateField value={date} onChange={setDate} disabled={busy} />
      </div>

      {canLinkAccount ? (
        <div>
          <FieldLabel text="Deposit into" hint={bankAccountId == null ? 'No balance affected' : null} />
          {accounts.length ? (
            <AccountChips accounts={accounts} selectedId={bankAccountId} onSelect={setBankAccountId} disabled={busy} noneLabel="Not tracked" />
          ) : (
            <Notice message="Add a bank account to credit income to a balance." />
          )}
        </div>
      ) : null}

      <div>
        <FieldLabel text="Details" hint="Optional" />
        <Card>
          <TextArea value={description} onChange={setDescription} placeholder="Description" aria-label="Description" icon="text" disabled={busy} />
        </Card>
      </div>

      {error ? <InlineError message={error} /> : null}
    </Page>
  );
}
