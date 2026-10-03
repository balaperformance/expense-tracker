import { useId, useState, type CSSProperties, type InputHTMLAttributes, type ReactNode, type Ref, type TextareaHTMLAttributes } from 'react';

import { addDays, today as todayIso } from '@/lib/dates';
import { dayMonthYear } from '@/lib/format';
import { sanitiseAmountInput } from '@/lib/validators';

import styles from './Fields.module.css';
import { Icon, type IconName } from './Icon';
import { IconButton } from './Button';

const cx = (...names: (string | false | null | undefined)[]) => names.filter(Boolean).join(' ');

export function FieldLabel({
  text,
  required,
  hint,
  hintIsError,
  htmlFor,
}: {
  text: string;
  required?: boolean;
  hint?: string | null;
  hintIsError?: boolean;
  htmlFor?: string;
}) {
  return (
    <label className={styles.label} htmlFor={htmlFor}>
      <span>{text}</span>
      {required ? <span className={styles.required}>*</span> : null}
      {hint ? <span className={cx(styles.hint, hintIsError && styles.hintError)}>{hint}</span> : null}
    </label>
  );
}

type TextFieldProps = Omit<InputHTMLAttributes<HTMLInputElement>, 'onChange' | 'value'> & {
  value: string;
  onChange: (value: string) => void;
  icon?: IconName;
  prefix?: string;
  trailing?: ReactNode;
  error?: string | null;
  helper?: string;
  inputRef?: Ref<HTMLInputElement>;
};

export function TextField({ value, onChange, icon, prefix, trailing, error, helper, disabled, inputRef, className, ...rest }: TextFieldProps) {
  const errorId = useId();
  return (
    <div className={className}>
      <div className={cx(styles.field, error && styles.fieldError, disabled && styles.fieldDisabled)}>
        {icon ? (
          <span className={styles.fieldIcon}>
            <Icon name={icon} size={20} />
          </span>
        ) : null}
        {prefix ? <span className={styles.prefix}>{prefix}</span> : null}
        <input
          ref={inputRef}
          className={styles.input}
          value={value}
          disabled={disabled}
          onChange={(e) => onChange(e.target.value)}
          aria-invalid={error ? true : undefined}
          aria-describedby={error ? errorId : undefined}
          {...rest}
        />
        {trailing ? <span className={styles.trailing}>{trailing}</span> : null}
      </div>
      {error ? (
        <div id={errorId} className={styles.error}>
          {error}
        </div>
      ) : helper ? (
        <div className={styles.helper}>{helper}</div>
      ) : null}
    </div>
  );
}

type TextAreaProps = Omit<TextareaHTMLAttributes<HTMLTextAreaElement>, 'onChange' | 'value'> & {
  value: string;
  onChange: (value: string) => void;
  icon?: IconName;
};

export function TextArea({ value, onChange, icon, disabled, rows = 2, ...rest }: TextAreaProps) {
  return (
    <div className={cx(styles.field, icon && styles.textareaWithIcon, disabled && styles.fieldDisabled)}>
      {icon ? (
        <span className={styles.fieldIcon}>
          <Icon name={icon} size={20} />
        </span>
      ) : null}
      <textarea
        className={styles.textarea}
        value={value}
        rows={rows}
        disabled={disabled}
        onChange={(e) => onChange(e.target.value)}
        {...rest}
      />
    </div>
  );
}

export function PasswordField({
  value,
  onChange,
  label,
  autoComplete,
  error,
  disabled,
  onEnter,
  autoFocus,
  name,
}: {
  value: string;
  onChange: (value: string) => void;
  label: string;
  autoComplete: 'current-password' | 'new-password';
  error?: string | null;
  disabled?: boolean;
  onEnter?: () => void;
  autoFocus?: boolean;
  name?: string;
}) {
  const [visible, setVisible] = useState(false);
  return (
    <TextField
      type={visible ? 'text' : 'password'}
      value={value}
      onChange={onChange}
      placeholder={label}
      aria-label={label}
      name={name}
      icon="lock"
      autoComplete={autoComplete}
      autoCapitalize="none"
      autoCorrect="off"
      spellCheck={false}
      disabled={disabled}
      error={error}
      autoFocus={autoFocus}
      enterKeyHint={onEnter ? 'go' : 'next'}
      onKeyDown={(e) => {
        if (e.key === 'Enter' && onEnter) {
          e.preventDefault();
          onEnter();
        }
      }}
      trailing={
        <IconButton icon={visible ? 'eyeOff' : 'eye'} label={visible ? 'Hide password' : 'Show password'} small onClick={() => setVisible((v) => !v)} />
      }
    />
  );
}

/** The large, centred figure at the top of every money form. */
export function AmountField({
  value,
  onChange,
  symbol,
  tone,
  autoFocus,
  disabled,
  error,
  label = 'Amount',
}: {
  value: string;
  onChange: (value: string) => void;
  symbol: string;
  tone?: string;
  autoFocus?: boolean;
  disabled?: boolean;
  error?: string | null;
  label?: string;
}) {
  return (
    <div>
      <div
        className={cx(styles.amount, error && styles.fieldError, disabled && styles.fieldDisabled)}
        style={tone ? ({ '--tone': tone } as CSSProperties) : undefined}
      >
        <span className={cx(styles.amountSymbol, styles.amountSymbolPinned)} aria-hidden>
          {symbol}
        </span>
        <input
          className={styles.amountInput}
          value={value}
          onChange={(e) => onChange(sanitiseAmountInput(e.target.value))}
          inputMode="decimal"
          enterKeyHint="done"
          placeholder="0"
          aria-label={label}
          autoComplete="off"
          autoFocus={autoFocus}
          disabled={disabled}
          aria-invalid={error ? true : undefined}
        />
      </div>
      {error ? <div className={styles.error}>{error}</div> : null}
    </div>
  );
}

/** A date shown the app's way, picked with the platform's own date picker. */
export function DatePickerField({
  value,
  onChange,
  placeholder = 'Pick a date',
  icon = 'calendar',
  disabled,
  min = '2000-01-01',
  max,
  label,
  clearable,
}: {
  value: string | null;
  onChange: (value: string | null) => void;
  placeholder?: string;
  icon?: IconName;
  disabled?: boolean;
  min?: string;
  max?: string;
  label: string;
  clearable?: boolean;
}) {
  return (
    <div className={cx(styles.select, disabled && styles.fieldDisabled)}>
      <Icon name={icon} size={20} color="var(--muted)" />
      <span className={cx(styles.selectValue, !value && styles.placeholder)}>{value ? dayMonthYear(value) : placeholder}</span>
      {clearable && value ? (
        <span style={{ position: 'relative', zIndex: 1 }}>
          <IconButton icon="close" label={`Clear ${label}`} small onClick={() => onChange(null)} />
        </span>
      ) : null}
      <input
        type="date"
        className={styles.nativeDate}
        value={value ?? ''}
        min={min}
        max={max ?? addDays(todayIso(), 366)}
        aria-label={label}
        disabled={disabled}
        onClick={(e) => {
          try {
            e.currentTarget.showPicker();
          } catch {
            // Browsers without showPicker open the picker on focus instead.
          }
        }}
        onChange={(e) => {
          if (e.target.value) onChange(e.target.value);
          else if (clearable) onChange(null);
        }}
        style={clearable && value ? { right: 44, width: 'auto' } : undefined}
      />
    </div>
  );
}

/** A choice from a short list, shown like the date field and picked with the platform's own menu. */
export function SelectField<T extends string>({
  value,
  onChange,
  options,
  label,
  icon,
  placeholder = 'Choose',
  disabled,
}: {
  value: T | '';
  onChange: (value: T | '') => void;
  options: ReadonlyArray<{ value: T; label: string }>;
  label: string;
  icon?: IconName;
  placeholder?: string;
  disabled?: boolean;
}) {
  const selected = options.find((o) => o.value === value);
  return (
    <div className={cx(styles.select, disabled && styles.fieldDisabled)}>
      {icon ? <Icon name={icon} size={20} color="var(--muted)" /> : null}
      <span className={cx(styles.selectValue, !selected && styles.placeholder)}>{selected ? selected.label : placeholder}</span>
      <Icon name="chevronDown" size={18} color="var(--muted)" />
      <select
        className={styles.nativeDate}
        value={selected ? value : ''}
        aria-label={label}
        disabled={disabled}
        onChange={(e) => onChange(e.target.value as T | '')}
      >
        <option value="">{placeholder}</option>
        {options.map((option) => (
          <option key={option.value} value={option.value}>
            {option.label}
          </option>
        ))}
      </select>
    </div>
  );
}

/** Date field with the Today / Yesterday quick picks (DateField). */
export function DateField({ value, onChange, disabled, label = 'Date' }: { value: string; onChange: (value: string) => void; disabled?: boolean; label?: string }) {
  const today = todayIso();
  const yesterday = addDays(today, -1);
  return (
    <div className={styles.dateRow}>
      <div className="grow">
        <DatePickerField value={value} onChange={(v) => v && onChange(v)} disabled={disabled} label={label} />
      </div>
      <button
        type="button"
        className={cx(styles.quickDate, value === today && styles.quickDateOn)}
        onClick={() => onChange(today)}
        disabled={disabled}
        aria-pressed={value === today}
      >
        Today
      </button>
      <button
        type="button"
        className={cx(styles.quickDate, value === yesterday && styles.quickDateOn)}
        onClick={() => onChange(yesterday)}
        disabled={disabled}
        aria-pressed={value === yesterday}
      >
        Yest
      </button>
    </div>
  );
}

export function SearchField({ value, onChange, placeholder }: { value: string; onChange: (value: string) => void; placeholder: string }) {
  return (
    <div className={styles.search}>
      <span className={styles.fieldIcon}>
        <Icon name="search" size={19} />
      </span>
      <input
        className={styles.input}
        type="search"
        value={value}
        onChange={(e) => onChange(e.target.value)}
        placeholder={placeholder}
        aria-label={placeholder}
        enterKeyHint="search"
        autoComplete="off"
      />
      {value ? (
        <span className={styles.trailing}>
          <IconButton icon="close" label="Clear search" small onClick={() => onChange('')} />
        </span>
      ) : null}
    </div>
  );
}
