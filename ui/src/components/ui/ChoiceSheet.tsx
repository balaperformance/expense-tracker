import { Icon } from './Icon';
import { Sheet } from './Sheet';
import { CardList, ListRow } from './Surface';

/** A sheet listing options with a check on the current one (sort, currency…). */
export function ChoiceSheet<T extends string>({
  open,
  onClose,
  title,
  subtitle,
  options,
  value,
  onChoose,
}: {
  open: boolean;
  onClose: () => void;
  title: string;
  subtitle?: string;
  options: ReadonlyArray<{ value: T; label: string; detail?: string }>;
  value: T;
  onChoose: (value: T) => void;
}) {
  return (
    <Sheet open={open} onClose={onClose} title={title} subtitle={subtitle}>
      <CardList indent={12}>
        {options.map((option) => (
          <ListRow
            key={option.value}
            dense
            title={option.label}
            subtitle={option.detail}
            trailing={option.value === value ? <Icon name="checkCircle" size={20} color="var(--primary)" /> : undefined}
            onClick={() => onChoose(option.value)}
          />
        ))}
      </CardList>
    </Sheet>
  );
}
