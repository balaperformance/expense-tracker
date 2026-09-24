import { useEffect, type ReactNode } from 'react';

import { BrandMark } from '@/components/layout/Brand';
import { APP_NAME } from '@/domain/defaults';
import { IconButton } from '@/components/ui/Button';
import type { IconName } from '@/components/ui/Icon';
import { Card } from '@/components/ui/Surface';
import { useGoBack } from '@/hooks/useGoBack';

import styles from './Auth.module.css';

/** The auth screens' frame: a soft taupe glow, the brand, a serif headline and one card (AuthScaffold). */
export function AuthLayout({
  title,
  subtitle,
  children,
  back,
  icon = 'wallet',
}: {
  title: string;
  subtitle: ReactNode;
  children: ReactNode;
  back?: string;
  icon?: IconName;
}) {
  const goBack = useGoBack(back ?? '/login');
  useEffect(() => {
    document.title = `${title} · ${APP_NAME}`;
  }, [title]);
  return (
    <div className={styles.screen}>
      <div className={styles.glow} aria-hidden />
      <div className={styles.column}>
        {back ? <IconButton icon="back" label="Back" onClick={goBack} className={styles.back} iconSize={26} /> : null}
        <BrandMark size={52} icon={icon} />
        <div className={styles.intro}>
          <h1 className="t-display-sm">{title}</h1>
          <p className={styles.subtitle}>{subtitle}</p>
        </div>
        <Card radius="xl" padding="roomy">
          <div className={styles.form}>{children}</div>
        </Card>
      </div>
    </div>
  );
}
