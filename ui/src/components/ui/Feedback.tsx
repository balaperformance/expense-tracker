import type { CSSProperties, ReactNode } from 'react';

import { Button } from './Button';
import styles from './Feedback.module.css';
import { Icon, type IconName } from './Icon';
import { Card } from './Surface';

const toneStyle = (tone?: string) => (tone ? ({ '--tone': tone } as CSSProperties) : undefined);

/** A quiet explanatory line (AppNotice). */
export function Notice({ message, icon = 'info', tone }: { message: ReactNode; icon?: IconName; tone?: string }) {
  return (
    <div className={styles.notice} style={toneStyle(tone)} role="note">
      <Icon name={icon} size={16} />
      <div>{message}</div>
    </div>
  );
}

export function InlineError({ message }: { message: string }) {
  return (
    <div className={styles.inlineError} role="alert">
      <Icon name="error" size={16} />
      <div>{message}</div>
    </div>
  );
}

export function Badge({ label, icon, tone }: { label: string; icon?: IconName; tone?: string }) {
  return (
    <span className={styles.badge} style={toneStyle(tone)}>
      {icon ? <Icon name={icon} size={12} /> : null}
      {label}
    </span>
  );
}

type StateProps = {
  icon: IconName;
  title: string;
  message?: ReactNode;
  actionLabel?: string;
  onAction?: () => void;
  compact?: boolean;
};

export function EmptyState({ icon, title, message, actionLabel, onAction, compact }: StateProps) {
  return (
    <div className={[styles.state, compact && styles.stateCompact].filter(Boolean).join(' ')}>
      <span className={styles.stateIcon}>
        <Icon name={icon} size={compact ? 22 : 26} />
      </span>
      <h3 className={compact ? 't-title-md' : 't-headline-sm'}>{title}</h3>
      {message ? <p className="t-body-sm">{message}</p> : null}
      {actionLabel && onAction ? (
        <div className={styles.stateAction}>
          <Button label={actionLabel} icon="add" size="sm" variant="tonal" onClick={onAction} />
        </div>
      ) : null}
    </div>
  );
}

export function ErrorView({ message, onRetry, compact }: { message: string; onRetry?: () => void; compact?: boolean }) {
  return (
    <div className={[styles.state, styles.stateError, compact && styles.stateCompact].filter(Boolean).join(' ')} role="alert">
      <span className={styles.stateIcon}>
        <Icon name={navigator.onLine ? 'error' : 'offline'} size={compact ? 22 : 26} />
      </span>
      <h3 className={compact ? 't-title-md' : 't-headline-sm'}>{navigator.onLine ? 'Something went wrong' : 'You are offline'}</h3>
      <p className="t-body-sm">{message}</p>
      {onRetry ? (
        <div className={styles.stateAction}>
          <Button label="Try again" icon="refresh" size="sm" variant="tonal" onClick={onRetry} />
        </div>
      ) : null}
    </div>
  );
}

/** Centres a state view in the viewport's free space. */
export function Centered({ children }: { children: ReactNode }) {
  return <div className={styles.centered}>{children}</div>;
}

export function Skeleton({ width = '100%', height = 14, radius = 6 }: { width?: number | string; height?: number; radius?: number }) {
  return <span className={styles.skeleton} style={{ width, height, borderRadius: radius }} aria-hidden />;
}

/** Placeholder rows shaped like the list that is loading. */
export function ListSkeleton({ rows = 6 }: { rows?: number }) {
  return (
    <div aria-busy="true" aria-label="Loading" className="stack gap-md">
      <Skeleton width={90} height={11} />
      <Card padding="flush">
        {Array.from({ length: rows }, (_, i) => (
          <div key={i} className={styles.skeletonRow}>
            <Skeleton width={34} height={34} radius={10} />
            <div className="grow stack gap-sm">
              <Skeleton width={`${55 + ((i * 17) % 30)}%`} height={12} />
              <Skeleton width="35%" height={10} />
            </div>
            <Skeleton width={64} height={14} />
          </div>
        ))}
      </Card>
    </div>
  );
}

export function Spinner({ size = 18 }: { size?: number }) {
  return <span className={styles.spinner} style={{ width: size, height: size }} role="status" aria-label="Loading" />;
}

export function ProgressBar() {
  return <span className={styles.progressBar} role="progressbar" aria-label="Loading" />;
}
