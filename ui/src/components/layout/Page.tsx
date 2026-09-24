import { useEffect, useState, type ReactNode } from 'react';

import { IconButton } from '@/components/ui/Button';
import { APP_NAME } from '@/domain/defaults';
import { useGoBack } from '@/hooks/useGoBack';

import styles from './Layout.module.css';

type PageProps = {
  title: ReactNode;
  /** Small tracked caps above the title (the dashboard greeting). */
  eyebrow?: string;
  /** Shows a back control; the string is where to go when there is no history. */
  back?: string;
  actions?: ReactNode;
  /** Pinned under the title — a search field, a month stepper. */
  below?: ReactNode;
  children: ReactNode;
  narrow?: boolean;
  /** A pinned bottom bar (the committing action of a form). */
  bar?: ReactNode;
  titleClassName?: string;
  /** The browser/app-switcher title, when the visible title is not plain text. */
  documentTitle?: string;
};

function useScrolled(): boolean {
  const [scrolled, setScrolled] = useState(false);
  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 4);
    onScroll();
    window.addEventListener('scroll', onScroll, { passive: true });
    return () => window.removeEventListener('scroll', onScroll);
  }, []);
  return scrolled;
}

/** A screen: sticky glass app bar, safe-area-aware content column, optional bottom bar. */
export function Page({ title, eyebrow, back, actions, below, children, narrow, bar, titleClassName = 't-title-lg', documentTitle }: PageProps) {
  const scrolled = useScrolled();
  const goBack = useGoBack(back ?? '/');
  const titleText = documentTitle ?? (typeof title === 'string' ? title : null);

  useEffect(() => {
    document.title = titleText ? `${titleText} · ${APP_NAME}` : APP_NAME;
  }, [titleText]);

  return (
    <div className={styles.page}>
      <header className={[styles.header, scrolled && styles.headerScrolled].filter(Boolean).join(' ')}>
        <div className={styles.headerInner}>
          {back != null ? <IconButton icon="back" label="Back" onClick={goBack} className={styles.headerBack} iconSize={26} /> : null}
          <div className={styles.titleBlock}>
            {eyebrow ? <span className="t-eyebrow">{eyebrow}</span> : null}
            <h1 className={`${titleClassName} ${styles.title}`}>{title}</h1>
          </div>
          {actions ? <div className={styles.actions}>{actions}</div> : null}
        </div>
        {below ? <div className={styles.headerBelow}>{below}</div> : null}
      </header>
      <main className={[styles.content, narrow && styles.contentNarrow, bar && styles.contentWithBar].filter(Boolean).join(' ')}>
        {children}
      </main>
      {bar ? (
        <div className={styles.actionBar}>
          <div className={styles.actionBarInner}>{bar}</div>
        </div>
      ) : null}
    </div>
  );
}
