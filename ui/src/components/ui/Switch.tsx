import styles from './Switch.module.css';

type SwitchProps = {
  checked: boolean;
  onChange: (checked: boolean) => void;
  /** What the switch controls, for screen readers: there is no visible label of its own. */
  label: string;
  disabled?: boolean;
};

/** An on/off control. The track is the same size on every screen; the hit area is larger than it looks. */
export function Switch({ checked, onChange, label, disabled }: SwitchProps) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      aria-label={label}
      disabled={disabled}
      className={styles.switch}
      onClick={() => onChange(!checked)}
    >
      <span className={styles.track} data-on={checked}>
        <span className={styles.thumb} />
      </span>
    </button>
  );
}
