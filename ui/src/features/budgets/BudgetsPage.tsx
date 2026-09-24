import { useState } from 'react';

import { Page } from '@/components/layout/Page';
import { BudgetAlertBanner, BudgetCard } from '@/components/finance/Budget';
import { CategoryAvatar } from '@/components/finance/Avatars';
import { MonthStepper } from '@/components/finance/Stats';
import { Button, Fab, IconButton } from '@/components/ui/Button';
import { Chip, ChipGroup } from '@/components/ui/Chip';
import { Centered, EmptyState, ErrorView, InlineError, ListSkeleton, Notice } from '@/components/ui/Feedback';
import { AmountField, FieldLabel } from '@/components/ui/Fields';
import { Sheet } from '@/components/ui/Sheet';
import { SectionHeader } from '@/components/ui/Surface';
import { budgetAlerts, type BudgetProgress } from '@/domain/analytics';
import { budgetLabel, type Budget } from '@/domain/models';
import { useBudgets, useCategories } from '@/hooks/data';
import { useIsDark } from '@/hooks/useIsDark';
import { useSheet } from '@/hooks/useSheet';
import { useCopyBudgets, useDeleteBudget, useSetBudget } from '@/hooks/mutations';
import { readableOn } from '@/lib/color';
import { addMonths, firstOfMonth, today } from '@/lib/dates';
import { errorMessage } from '@/lib/errors';
import { monthYear } from '@/lib/format';
import { amountToInput, parseAmount, validateAmount } from '@/lib/validators';
import { useFeedback } from '@/state/feedback';
import { useSettings } from '@/state/settings';

export function BudgetsPage() {
  const { currency } = useSettings();
  const { toast } = useFeedback();
  const [month, setMonth] = useState(firstOfMonth(today()));
  const budgets = useBudgets(month);
  const copy = useCopyBudgets();
  const editor = useSheet<Budget | null>();
  const data = budgets.data;
  const hasAny = Boolean(data && (data.overall || data.categories.length));

  const copyPrevious = async () => {
    try {
      const copied = await copy.mutateAsync(month);
      if (copied === 0) toast('info', 'Nothing to copy from last month.');
      else toast('success', `Copied ${copied} ${copied === 1 ? 'budget' : 'budgets'}.`);
    } catch (error) {
      toast('error', errorMessage(error, 'Could not copy last month.'));
    }
  };

  let body;
  if (budgets.isPending) body = <ListSkeleton rows={4} />;
  else if (budgets.isError && !hasAny) {
    body = (
      <Centered>
        <ErrorView message={errorMessage(budgets.error)} onRetry={() => void budgets.refetch()} />
      </Centered>
    );
  } else if (!data || !hasAny) {
    body = (
      <Centered>
        <EmptyState
          icon="budget"
          title="No budgets this month"
          message="Set an overall limit, or one per category, to track how much of your plan you have used."
          actionLabel="Set a budget"
          onAction={() => editor.open(null)}
        />
      </Centered>
    );
  } else {
    const alerts = budgetAlerts(data);
    body = (
      <>
        {alerts.length ? <BudgetAlertBanner alerts={alerts} /> : null}
        {data.overall ? (
          <div>
            <SectionHeader title="Overall" />
            <BudgetCard progress={data.overall} currency={currency} showAvatar={false} onClick={() => data.overall && editor.open(data.overall.budget)} />
          </div>
        ) : null}
        {data.categories.length ? (
          <div>
            <SectionHeader title="By category" caption={String(data.categories.length)} />
            <div className="stack" style={{ gap: 'var(--card-gap)' }}>
              {data.categories.map((progress) => (
                <BudgetCard key={progress.budget.id} progress={progress} currency={currency} onClick={() => editor.open(progress.budget)} />
              ))}
            </div>
          </div>
        ) : null}
      </>
    );
  }

  return (
    <Page
      title="Budgets"
      back="/settings"
      narrow
      actions={<IconButton icon="copy" label="Copy last month" disabled={copy.isPending} onClick={() => void copyPrevious()} />}
      below={<MonthStepper month={month} onPrevious={() => setMonth((m) => addMonths(m, -1))} onNext={() => setMonth((m) => addMonths(m, 1))} />}
    >
      {body}
      <Fab label="Budget" onClick={() => editor.open(null)} />
      <BudgetEditorSheet
        key={editor.key}
        open={editor.isOpen}
        existing={editor.data}
        month={month}
        taken={data?.categories ?? []}
        onClose={editor.close}
      />
    </Page>
  );
}

function BudgetEditorSheet({
  open,
  existing,
  month,
  taken,
  onClose,
}: {
  open: boolean;
  existing: Budget | null;
  month: string;
  taken: BudgetProgress[];
  onClose: () => void;
}) {
  const { symbol } = useSettings();
  const { toast, confirm } = useFeedback();
  const dark = useIsDark();
  const categories = useCategories().data ?? [];
  const save = useSetBudget();
  const remove = useDeleteBudget();
  const editing = existing != null;
  const [amount, setAmount] = useState(existing ? amountToInput(existing.amount) : '');
  const [categoryId, setCategoryId] = useState<string | null>(existing?.categoryId ?? null);
  const [submitted, setSubmitted] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const busy = save.isPending || remove.isPending;

  const takenIds = new Set(taken.map((p) => p.budget.categoryId).filter((id) => id !== existing?.categoryId));
  const selectable = categories.filter((c) => !takenIds.has(c.id));

  const submit = async () => {
    setSubmitted(true);
    if (validateAmount(amount)) return;
    setError(null);
    try {
      await save.mutateAsync({ categoryId, month, amount: parseAmount(amount) ?? 0 });
      toast('success', 'Budget saved');
      onClose();
    } catch (failure) {
      setError(errorMessage(failure, 'Could not save the budget.'));
    }
  };

  const confirmDelete = async () => {
    if (!existing) return;
    const ok = await confirm({
      title: 'Delete budget?',
      message: `The limit for ${budgetLabel(existing).toLowerCase()} will be removed for this month.`,
    });
    if (!ok) return;
    try {
      await remove.mutateAsync(existing.id);
      toast('success', 'Budget deleted');
      onClose();
    } catch (failure) {
      setError(errorMessage(failure, 'Could not delete the budget.'));
    }
  };

  return (
    <Sheet
      open={open}
      onClose={onClose}
      busy={busy}
      title={editing ? 'Edit budget' : 'New budget'}
      subtitle={monthYear(month)}
      action={editing ? <IconButton icon="delete" label="Delete budget" color="var(--error)" disabled={busy} onClick={() => void confirmDelete()} /> : null}
      footer={<Button label={editing ? 'Save changes' : 'Set budget'} size="lg" block busy={save.isPending} busyLabel="Saving…" onClick={() => void submit()} />}
    >
      <div className="stack gap-sm">
        <AmountField value={amount} onChange={setAmount} symbol={symbol} tone="var(--primary)" disabled={busy} error={submitted ? validateAmount(amount) : null} label="Monthly limit" />
        <p className="t-label-sm t-center">Monthly limit</p>
      </div>
      <div>
        <FieldLabel text="Applies to" required hint={editing ? 'Locked' : null} />
        <ChipGroup label="Applies to">
          <Chip label="Everything" icon="allInclusive" selected={categoryId == null} disabled={busy || editing} onClick={() => setCategoryId(null)} />
          {selectable.map((category) => (
            <Chip
              key={category.id}
              label={category.name}
              selected={categoryId === category.id}
              disabled={busy || editing}
              tone={readableOn(category.color, dark)}
              avatar={<CategoryAvatar icon={category.icon} color={category.color} size={24} />}
              onClick={() => setCategoryId(category.id)}
            />
          ))}
        </ChipGroup>
      </div>
      {editing ? <Notice message="Create a new budget to change what it applies to." /> : null}
      {error ? <InlineError message={error} /> : null}
    </Sheet>
  );
}
