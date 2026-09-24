import type { ButtonHTMLAttributes } from 'react';

import styles from './Button.module.css';
import { Icon, type IconName } from './Icon';

export type ButtonVariant = 'primary' | 'secondary' | 'tonal' | 'ghost' | 'danger' | 'dangerGhost';
export type ButtonSize = 'sm' | 'md' | 'lg';

type ButtonProps = Omit<ButtonHTMLAttributes<HTMLButtonElement>, 'children'> & {
  label: string;
  variant?: ButtonVariant;
  size?: ButtonSize;
  icon?: IconName;
  /** Only the one committing action on a screen spans the full width. */
  block?: boolean;
  busy?: boolean;
  busyLabel?: string;
};

export function Button({
  label,
  variant = 'primary',
  size = 'md',
  icon,
  block,
  busy,
  busyLabel,
  className,
  disabled,
  type = 'button',
  ...rest
}: ButtonProps) {
  const classes = [styles.button, styles[variant], size !== 'md' && styles[size], block && styles.block, className]
    .filter(Boolean)
    .join(' ');
  return (
    <button type={type} className={classes} disabled={disabled || busy} aria-busy={busy || undefined} {...rest}>
      {busy ? <span className={styles.spinner} aria-hidden /> : icon ? <Icon name={icon} size={size === 'sm' ? 15 : 17} /> : null}
      <span>{busy && busyLabel ? busyLabel : label}</span>
    </button>
  );
}

type IconButtonProps = Omit<ButtonHTMLAttributes<HTMLButtonElement>, 'children'> & {
  icon: IconName;
  /** Accessible name — also the tooltip. */
  label: string;
  glass?: boolean;
  small?: boolean;
  badge?: number;
  color?: string;
  iconSize?: number;
};

export function IconButton({ icon, label, glass, small, badge, color, iconSize, className, type = 'button', ...rest }: IconButtonProps) {
  const classes = [styles.iconButton, glass && styles.iconButtonGlass, small && styles.iconButtonSm, className]
    .filter(Boolean)
    .join(' ');
  return (
    <button type={type} className={classes} aria-label={label} title={label} style={color ? { color } : undefined} {...rest}>
      <Icon name={icon} size={iconSize ?? (small ? 18 : 21)} />
      {badge ? <span className={styles.badge}>{badge}</span> : null}
    </button>
  );
}

type FabProps = {
  label: string;
  onClick: () => void;
  icon?: IconName;
  /** The desktop rail offers the same action, so the button steps aside there. */
  railed?: boolean;
};

/**
 * Extended floating action — the same family as the page's buttons, not a
 * larger species. It clears the floating navigation bar through the shell's
 * --nav-clearance token.
 */
export function Fab({ label, onClick, icon = 'add', railed }: FabProps) {
  return (
    <button type="button" className={railed ? `${styles.fab} ${styles.fabRailed}` : styles.fab} onClick={onClick}>
      <Icon name={icon} size={20} />
      <span>{label}</span>
    </button>
  );
}
