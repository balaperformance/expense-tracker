import { useState } from 'react';

import { Button } from '@/components/ui/Button';
import { Chip, ChipGroup } from '@/components/ui/Chip';
import { Notice } from '@/components/ui/Feedback';
import { DatePickerField, FieldLabel } from '@/components/ui/Fields';
import { Sheet } from '@/components/ui/Sheet';
import { CategoryChips } from '@/components/finance/Pickers';
import type { ExpenseFilter } from '@/domain/expenseFilter';
import { useCategories, usePaymentMethods } from '@/hooks/data';
import { addDays, addMonths, monthRange, today } from '@/lib/dates';

/** Date range, categories and payment methods for the expenses list (ExpenseFilterSheet). */
export function FilterSheet({
  open,
  initial,
  onClose,
  onApply,
}: {
  open: boolean;
  initial: ExpenseFilter;
  onClose: () => void;
  onApply: (filter: ExpenseFilter) => void;
}) {
  const categories = useCategories().data ?? [];
  const methods = usePaymentMethods().data ?? [];
  const [categoryIds, setCategoryIds] = useState<string[]>([...initial.categoryIds]);
  const [paymentIds, setPaymentIds] = useState<string[]>([...initial.paymentMethodIds]);
  const [from, setFrom] = useState<string | null>(initial.from);
  const [to, setTo] = useState<string | null>(initial.to);

  const thisMonth = monthRange(today());
  const lastMonth = monthRange(addMonths(today(), -1));
  const last30 = { start: addDays(today(), -30), end: today() };
  const matches = (start: string, end: string) => from === start && to === end;

  const count = categoryIds.length + paymentIds.length + (from ? 1 : 0) + (to ? 1 : 0);
  const toggle = (list: string[], id: string) => (list.includes(id) ? list.filter((x) => x !== id) : [...list, id]);

  return (
    <Sheet
      open={open}
      onClose={onClose}
      title="Filters"
      subtitle={count ? `${count} active` : 'Narrow down the list'}
      action={
        <Button
          label="Clear all"
          variant="ghost"
          size="sm"
          disabled={!count}
          onClick={() => {
            setCategoryIds([]);
            setPaymentIds([]);
            setFrom(null);
            setTo(null);
          }}
        />
      }
      footer={
        <Button
          label={count ? `Apply ${count} filters` : 'Apply'}
          size="lg"
          block
          onClick={() => onApply({ ...initial, categoryIds, paymentMethodIds: paymentIds, from, to })}
        />
      }
    >
      <div>
        <FieldLabel text="Date range" />
        <div className="stack gap-sm">
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8 }}>
            <DatePickerField label="From" placeholder="From" value={from} onChange={setFrom} clearable />
            <DatePickerField label="To" placeholder="To" value={to} onChange={setTo} clearable icon="calendarRange" />
          </div>
          <ChipGroup label="Quick ranges">
            <Chip
              label="This month"
              selected={matches(thisMonth.start, thisMonth.endInclusive)}
              onClick={() => {
                setFrom(thisMonth.start);
                setTo(thisMonth.endInclusive);
              }}
            />
            <Chip
              label="Last month"
              selected={matches(lastMonth.start, lastMonth.endInclusive)}
              onClick={() => {
                setFrom(lastMonth.start);
                setTo(lastMonth.endInclusive);
              }}
            />
            <Chip
              label="Last 30 days"
              selected={matches(last30.start, last30.end)}
              onClick={() => {
                setFrom(last30.start);
                setTo(last30.end);
              }}
            />
          </ChipGroup>
        </div>
      </div>
      <div>
        <FieldLabel text="Categories" hint={categoryIds.length ? `${categoryIds.length} selected` : null} />
        <CategoryChips
          categories={categories}
          isSelected={(id) => categoryIds.includes(id)}
          onToggle={(id) => setCategoryIds((list) => toggle(list, id))}
          emptyMessage="No categories yet."
        />
      </div>
      <div>
        <FieldLabel text="Payment methods" hint={paymentIds.length ? `${paymentIds.length} selected` : null} />
        {methods.length ? (
          <ChipGroup label="Payment methods">
            {methods.map((method) => (
              <Chip
                key={method.id}
                label={method.name}
                selected={paymentIds.includes(method.id)}
                onClick={() => setPaymentIds((list) => toggle(list, method.id))}
              />
            ))}
          </ChipGroup>
        ) : (
          <Notice message="No payment methods yet." />
        )}
      </div>
    </Sheet>
  );
}
