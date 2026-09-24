import type { CSSProperties, ReactNode } from 'react';

import styles from './Chip.module.css';
import { Icon, type IconName } from './Icon';

type ChipProps = {
  label: string;
  selected: boolean;
  onClick: () => void;
  icon?: IconName;
  avatar?: ReactNode;
  tone?: string;
  disabled?: boolean;
};

/** A selectable pill (AppChoiceChip). The tone tints it when selected. */
export function Chip({ label, selected, onClick, icon, avatar, tone, disabled }: ChipProps) {
  return (
    <button
      type="button"
      className={[styles.chip, selected && styles.selected, avatar && styles.withAvatar].filter(Boolean).join(' ')}
      style={tone ? ({ '--tone': tone } as CSSProperties) : undefined}
      onClick={onClick}
      disabled={disabled}
      aria-pressed={selected}
    >
      {avatar ?? (icon ? <Icon name={selected ? 'check' : icon} size={16} /> : null)}
      <span className={styles.label}>{label}</span>
    </button>
  );
}

export function ChipGroup({ children, error, label }: { children: ReactNode; error?: boolean; label?: string }) {
  return (
    <div className={[styles.wrap, error && styles.pickerError].filter(Boolean).join(' ')} role="group" aria-label={label}>
      {children}
    </div>
  );
}

type SegmentedProps<T extends string> = {
  value: T;
  options: ReadonlyArray<{ value: T; label: string; icon?: IconName }>;
  onChange: (value: T) => void;
  label: string;
  disabled?: boolean;
};

/** A sliding segmented control (SegmentedButton). */
export function Segmented<T extends string>({ value, options, onChange, label, disabled }: SegmentedProps<T>) {
  const index = Math.max(
    0,
    options.findIndex((o) => o.value === value),
  );
  return (
    <div className={styles.segmented} role="radiogroup" aria-label={label}>
      <span
        className={styles.thumb}
        style={{ width: `calc((100% - 6px) / ${options.length})`, transform: `translateX(${index * 100}%)` }}
        aria-hidden
      />
      {options.map((option) => (
        <button
          key={option.value}
          type="button"
          role="radio"
          aria-checked={option.value === value}
          className={[styles.segment, option.value === value && styles.segmentOn].filter(Boolean).join(' ')}
          onClick={() => onChange(option.value)}
          disabled={disabled}
        >
          {option.icon ? <Icon name={option.icon} size={15} /> : null}
          {option.label}
        </button>
      ))}
    </div>
  );
}
