import { Chip, ChipGroup } from '@/components/ui/Chip';
import { Notice } from '@/components/ui/Feedback';
import { accountLabel, type BankAccount, type ExpenseCategory, type PaymentMethod } from '@/domain/models';
import { readableOn } from '@/lib/color';
import { useIsDark } from '@/hooks/useIsDark';

import { CategoryAvatar } from './Avatars';

/** Category chips, each tinted with its own colour. Single or multiple selection. */
export function CategoryChips({
  categories,
  isSelected,
  onToggle,
  disabled,
  error,
  emptyMessage = 'No categories yet. Add one from Settings › Categories.',
}: {
  categories: readonly ExpenseCategory[];
  isSelected: (id: string) => boolean;
  onToggle: (id: string) => void;
  disabled?: boolean;
  error?: boolean;
  emptyMessage?: string;
}) {
  const dark = useIsDark();
  if (!categories.length) return <Notice message={emptyMessage} />;
  return (
    <ChipGroup error={error} label="Category">
      {categories.map((category) => (
        <Chip
          key={category.id}
          label={category.name}
          selected={isSelected(category.id)}
          disabled={disabled}
          tone={readableOn(category.color, dark)}
          avatar={<CategoryAvatar icon={category.icon} color={category.color} size={24} />}
          onClick={() => onToggle(category.id)}
        />
      ))}
    </ChipGroup>
  );
}

/** "Cash" (or another no-account label) plus one chip per bank account. */
export function AccountChips({
  accounts,
  selectedId,
  onSelect,
  disabled,
  noneLabel = 'Cash',
  fullLabels,
}: {
  accounts: readonly BankAccount[];
  selectedId: string | null;
  onSelect: (id: string | null) => void;
  disabled?: boolean;
  noneLabel?: string;
  /** Show "Nickname •••• 1234" rather than the nickname alone. */
  fullLabels?: boolean;
}) {
  return (
    <ChipGroup label="Account">
      <Chip label={noneLabel} icon={noneLabel === 'Cash' ? 'cash' : 'close'} selected={selectedId == null} disabled={disabled} onClick={() => onSelect(null)} />
      {accounts.map((account) => (
        <Chip
          key={account.id}
          label={fullLabels ? accountLabel(account) : account.nickname}
          icon="bank"
          selected={selectedId === account.id}
          disabled={disabled}
          onClick={() => onSelect(account.id)}
        />
      ))}
    </ChipGroup>
  );
}

/** Optional payment method; tapping the selected one clears it. */
export function PaymentMethodChips({
  methods,
  selectedId,
  onSelect,
  disabled,
}: {
  methods: readonly PaymentMethod[];
  selectedId: string | null;
  onSelect: (id: string | null) => void;
  disabled?: boolean;
}) {
  return (
    <ChipGroup label="Payment method">
      {methods.map((method) => (
        <Chip
          key={method.id}
          label={method.name}
          selected={method.id === selectedId}
          disabled={disabled}
          onClick={() => onSelect(method.id === selectedId ? null : method.id)}
        />
      ))}
    </ChipGroup>
  );
}
