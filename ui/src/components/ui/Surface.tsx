import type { CSSProperties, ReactNode } from 'react';
import { Link } from 'react-router';

import { Icon, type IconName } from './Icon';
import styles from './Surface.module.css';

const cx = (...names: (string | false | null | undefined)[]) => names.filter(Boolean).join(' ');

type CardProps = {
  children: ReactNode;
  padding?: 'normal' | 'flush' | 'roomy';
  radius?: 'lg' | 'xl';
  /** Tints the pane for a state that needs attention. */
  tone?: string;
  onClick?: () => void;
  className?: string;
  style?: CSSProperties;
  ariaLabel?: string;
};

/** A glass pane: translucent fill, lit top edge, two-layer shadow. */
export function Card({ children, padding = 'normal', radius = 'lg', tone, onClick, className, style, ariaLabel }: CardProps) {
  const classes = cx(
    styles.card,
    padding === 'flush' && styles.flush,
    padding === 'roomy' && styles.roomy,
    radius === 'xl' && styles.xl,
    tone && styles.toned,
    onClick && styles.interactive,
    className,
  );
  const toneStyle = tone ? ({ '--tone': tone, ...style } as CSSProperties) : style;
  if (onClick) {
    return (
      <button type="button" className={classes} style={toneStyle} onClick={onClick} aria-label={ariaLabel}>
        {children}
      </button>
    );
  }
  return (
    <div className={classes} style={toneStyle}>
      {children}
    </div>
  );
}

/** Rows grouped on one pane with hairline dividers aligned to the text column. */
export function CardList({ children, indent = 58, className }: { children: ReactNode; indent?: number | null; className?: string }) {
  return (
    <div
      className={cx(styles.card, styles.list, indent != null && styles.listIndented, className)}
      style={indent != null ? ({ '--divider-indent': `${indent}px` } as CSSProperties) : undefined}
    >
      {children}
    </div>
  );
}

type ListRowProps = {
  title: ReactNode;
  subtitle?: ReactNode;
  leading?: ReactNode;
  trailing?: ReactNode;
  /** A control beside the row (e.g. delete), kept outside the row's own tap area. */
  action?: ReactNode;
  chevron?: boolean;
  dense?: boolean;
  tone?: string;
  onClick?: () => void;
  to?: string;
  ariaLabel?: string;
};

export function ListRow({ action, ...row }: ListRowProps) {
  if (!action) return <RowBody {...row} />;
  return (
    <div className={styles.rowWithAction}>
      <RowBody {...row} />
      <span className={styles.rowAction}>{action}</span>
    </div>
  );
}

function RowBody({ title, subtitle, leading, trailing, chevron, dense, tone, onClick, to, ariaLabel }: Omit<ListRowProps, 'action'>) {
  const content = (
    <>
      {leading}
      <span className={styles.rowText}>
        <span className={styles.rowTitle} style={tone ? { color: tone } : undefined}>
          {title}
        </span>
        {subtitle ? <span className={styles.rowSubtitle}>{subtitle}</span> : null}
      </span>
      {trailing || chevron ? (
        <span className={styles.rowTrailing}>
          {trailing}
          {chevron ? <Icon name="chevronRight" size={20} /> : null}
        </span>
      ) : null}
    </>
  );
  const classes = cx(styles.row, dense && styles.rowDense);
  if (to) {
    return (
      <Link to={to} className={classes} aria-label={ariaLabel}>
        {content}
      </Link>
    );
  }
  if (onClick) {
    return (
      <button type="button" className={classes} onClick={onClick} aria-label={ariaLabel}>
        {content}
      </button>
    );
  }
  return <div className={classes}>{content}</div>;
}

/** An icon on a soft wash of its tone. */
export function IconWell({ icon, tone = 'var(--primary)', size = 34, round }: { icon: IconName; tone?: string; size?: number; round?: boolean }) {
  return (
    <span
      className={cx(styles.well, round && styles.wellRound)}
      style={{ width: size, height: size, '--tone': tone } as CSSProperties}
      aria-hidden
    >
      <Icon name={icon} size={Math.round(size * 0.52)} />
    </span>
  );
}

type SectionHeaderProps = {
  title: string;
  caption?: string;
  actionLabel?: string;
  onAction?: () => void;
  actionTo?: string;
};

/** A serif heading above a group of cards — a chapter of the page. */
export function SectionHeader({ title, caption, actionLabel, onAction, actionTo }: SectionHeaderProps) {
  return (
    <div className={styles.section}>
      <h2 className={cx('t-section', styles.sectionTitle)}>{title}</h2>
      {caption ? <span className={styles.sectionCaption}>{caption}</span> : null}
      {actionLabel && actionTo ? (
        <Link to={actionTo} className={styles.sectionAction}>
          {actionLabel}
        </Link>
      ) : actionLabel && onAction ? (
        <button type="button" className={styles.sectionAction} onClick={onAction}>
          {actionLabel}
        </button>
      ) : null}
    </div>
  );
}

/** A serif heading inside a card, with an optional caption pill and trailing control. */
export function CardHeader({ title, caption, trailing }: { title: string; caption?: string; trailing?: ReactNode }) {
  return (
    <div className={styles.cardHead}>
      <h2 className={cx('t-section', styles.sectionTitle)}>{title}</h2>
      {caption ? <span className={styles.sectionCaption}>{caption}</span> : null}
      {trailing}
    </div>
  );
}

/**
 * The one dark, dramatic surface on a light page: black shading into
 * taupe-black with two soft glows. Its content is set in the dark theme.
 */
export function Hero({ children, glow = 'var(--hero-accent)', className }: { children: ReactNode; glow?: string; className?: string }) {
  return (
    <div className={cx(styles.hero, className)}>
      <span
        className={styles.glow}
        style={{
          top: -80,
          right: -60,
          width: 210,
          height: 210,
          background: `radial-gradient(circle, color-mix(in srgb, ${glow} 26%, transparent), transparent 70%)`,
        }}
        aria-hidden
      />
      <span
        className={styles.glow}
        style={{
          bottom: -90,
          left: -40,
          width: 170,
          height: 170,
          background: 'radial-gradient(circle, color-mix(in srgb, var(--hero-accent) 12%, transparent), transparent 70%)',
        }}
        aria-hidden
      />
      <div className={cx('theme-dark', styles.heroContent)} style={{ background: 'transparent' }}>
        {children}
      </div>
    </div>
  );
}
