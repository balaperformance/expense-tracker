import { Icon, type IconName } from '@/components/ui/Icon';
import { APP_NAME } from '@/domain/defaults';

import styles from './Layout.module.css';

/** The rounded black brand tile with the taupe wallet (BrandMark). */
export function BrandMark({ size = 56, icon = 'wallet' }: { size?: number; icon?: IconName }) {
  return (
    <span className={styles.brandMark} style={{ width: size, height: size, borderRadius: size * 0.3 }} aria-hidden>
      <Icon name={icon} size={Math.round(size * 0.48)} />
    </span>
  );
}

export function BrandLockup({ tagline, markSize = 64 }: { tagline?: string; markSize?: number }) {
  return (
    <div className={styles.lockup}>
      <BrandMark size={markSize} />
      <h1 className="t-headline-lg">{APP_NAME}</h1>
      {tagline ? <span className="t-eyebrow">{tagline}</span> : null}
    </div>
  );
}
