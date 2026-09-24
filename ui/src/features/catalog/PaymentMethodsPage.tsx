import { useState } from 'react';

import { Page } from '@/components/layout/Page';
import { Button, Fab, IconButton } from '@/components/ui/Button';
import { Centered, EmptyState, InlineError, ListSkeleton, Notice } from '@/components/ui/Feedback';
import { TextField } from '@/components/ui/Fields';
import type { IconName } from '@/components/ui/Icon';
import { Dialog } from '@/components/ui/Sheet';
import { CardList, IconWell, ListRow, SectionHeader } from '@/components/ui/Surface';
import type { PaymentMethod } from '@/domain/models';
import { usePaymentMethods } from '@/hooks/data';
import { useCreatePaymentMethod, useDeletePaymentMethod } from '@/hooks/mutations';
import { errorMessage } from '@/lib/errors';
import { validateRequired } from '@/lib/validators';
import { useFeedback } from '@/state/feedback';

/** The table stores only a name, so the icon is derived from it. */
function iconFor(name: string): IconName {
  const value = name.toLowerCase();
  if (value.includes('cash')) return 'cash';
  if (value.includes('upi')) return 'upi';
  if (value.includes('credit')) return 'cardSolid';
  if (value.includes('debit')) return 'card';
  if (value.includes('bank') || value.includes('net')) return 'bank';
  if (value.includes('wallet')) return 'walletOutline';
  return 'paymentMethod';
}

export function PaymentMethodsPage() {
  const { toast, confirm } = useFeedback();
  const methods = usePaymentMethods();
  const create = useCreatePaymentMethod();
  const remove = useDeletePaymentMethod();
  const [adding, setAdding] = useState(false);
  const [name, setName] = useState('');
  const [error, setError] = useState<string | null>(null);
  const list = methods.data ?? [];

  const openAdd = () => {
    setName('');
    setError(null);
    setAdding(true);
  };

  const add = async () => {
    const problem = validateRequired(name, 'Name');
    if (problem) {
      setError(problem);
      return;
    }
    try {
      await create.mutateAsync(name);
      setAdding(false);
      toast('success', 'Payment method added');
    } catch (failure) {
      setError(errorMessage(failure, 'Could not add the payment method.'));
    }
  };

  const confirmDelete = async (method: PaymentMethod) => {
    const ok = await confirm({
      title: `Delete "${method.name}"?`,
      message: 'Expenses paid with it keep their amount but lose the payment method. This cannot be undone.',
    });
    if (!ok) return;
    try {
      await remove.mutateAsync(method.id);
      toast('success', 'Payment method deleted');
    } catch (failure) {
      toast('error', errorMessage(failure, 'Could not delete the payment method.'));
    }
  };

  return (
    <Page title="Payment methods" back="/settings" narrow>
      {methods.isPending ? (
        <ListSkeleton rows={5} />
      ) : !list.length ? (
        <Centered>
          <EmptyState icon="card" title="No payment methods" message="Add the ways you pay so you can filter spending by them." actionLabel="Add method" onAction={openAdd} />
        </Centered>
      ) : (
        <>
          <div>
            <SectionHeader title="Methods" caption={String(list.length)} />
            <CardList indent={54}>
              {list.map((method) => (
                <ListRow
                  key={method.id}
                  dense
                  leading={<IconWell icon={iconFor(method.name)} size={30} />}
                  title={method.name}
                  action={<IconButton icon="delete" label={`Delete ${method.name}`} small color="var(--muted)" onClick={() => void confirmDelete(method)} />}
                />
              ))}
            </CardList>
          </div>
          <Notice message="Payment methods label how you paid. To track a real balance, use Bank accounts instead." />
        </>
      )}
      <Fab label="New" onClick={openAdd} />
      <Dialog
        open={adding}
        onClose={() => setAdding(false)}
        title="New payment method"
        actions={
          <>
            <Button label="Cancel" variant="ghost" onClick={() => setAdding(false)} />
            <Button label="Add" busy={create.isPending} onClick={() => void add()} />
          </>
        }
      >
        <form
          className="stack gap-sm"
          onSubmit={(e) => {
            e.preventDefault();
            void add();
          }}
        >
          <TextField value={name} onChange={setName} placeholder="e.g. HDFC Credit Card" aria-label="Name" autoCapitalize="words" autoFocus />
          {error ? <InlineError message={error} /> : null}
        </form>
      </Dialog>
    </Page>
  );
}
