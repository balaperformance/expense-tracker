import { useEffect, useId, useRef, useState, type ReactNode, type PointerEvent as ReactPointerEvent, type RefObject } from 'react';
import { createPortal } from 'react-dom';

import styles from './Sheet.module.css';

let scrollLocks = 0;

/** Stops the page scrolling behind an overlay; nested overlays share one lock. */
function useScrollLock(active: boolean) {
  useEffect(() => {
    if (!active) return;
    scrollLocks += 1;
    const html = document.documentElement;
    if (scrollLocks === 1) html.style.overflow = 'hidden';
    return () => {
      scrollLocks -= 1;
      if (scrollLocks === 0) html.style.overflow = '';
    };
  }, [active]);
}

/** Keeps an overlay mounted long enough to play its exit animation. */
function usePresence(open: boolean, exitMs = 170) {
  const [mounted, setMounted] = useState(open);
  const [closing, setClosing] = useState(false);
  const [prevOpen, setPrevOpen] = useState(open);
  if (open !== prevOpen) {
    setPrevOpen(open);
    if (open) {
      setMounted(true);
      setClosing(false);
    } else if (mounted) {
      setClosing(true);
    }
  }
  useEffect(() => {
    if (!closing) return;
    const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    const timer = setTimeout(
      () => {
        setMounted(false);
        setClosing(false);
      },
      reduced ? 0 : exitMs,
    );
    return () => clearTimeout(timer);
  }, [closing, exitMs]);
  return { mounted, closing };
}

/** Escape closes; focus moves into the overlay and back to the opener afterwards. */
function useOverlayFocus(open: boolean, panel: RefObject<HTMLElement | null>, onClose: () => void) {
  const onCloseRef = useRef(onClose);
  useEffect(() => {
    onCloseRef.current = onClose;
  });
  useEffect(() => {
    if (!open) return;
    const opener = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    const node = panel.current;
    const first = node?.querySelector<HTMLElement>('[autofocus], input, textarea, select');
    // Autofocus only on pointer-fine devices, so a phone keyboard does not
    // jump up over a sheet the user has not touched yet.
    if (first && window.matchMedia('(pointer: fine)').matches) first.focus();
    else node?.focus();
    const onKey = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.stopPropagation();
        onCloseRef.current();
      }
    };
    document.addEventListener('keydown', onKey);
    return () => {
      document.removeEventListener('keydown', onKey);
      opener?.focus({ preventScroll: true });
    };
  }, [open, panel]);
}

type SheetProps = {
  open: boolean;
  onClose: () => void;
  title: string;
  subtitle?: ReactNode;
  action?: ReactNode;
  footer?: ReactNode;
  children: ReactNode;
  /** Blocks dismissal while a save is in flight. */
  busy?: boolean;
};

/**
 * A bottom sheet on phones and a centred panel on wider screens (AppSheet).
 * The header can be dragged down to dismiss, like a native sheet.
 */
export function Sheet({ open, onClose, title, subtitle, action, footer, children, busy }: SheetProps) {
  const { mounted, closing } = usePresence(open);
  const panel = useRef<HTMLDivElement>(null);
  const titleId = useId();
  const drag = useRef<{ startY: number; dy: number } | null>(null);
  const safeClose = () => {
    if (!busy) onClose();
  };
  useScrollLock(mounted);
  useOverlayFocus(open, panel, safeClose);

  if (!mounted) return null;

  const onPointerDown = (event: ReactPointerEvent) => {
    // Only the phone layout is a bottom sheet; the centred panel does not drag.
    if (event.pointerType === 'mouse' || busy || window.innerWidth >= 768) return;
    drag.current = { startY: event.clientY, dy: 0 };
    (event.currentTarget as HTMLElement).setPointerCapture(event.pointerId);
  };
  const onPointerMove = (event: ReactPointerEvent) => {
    const state = drag.current;
    const node = panel.current;
    if (!state || !node) return;
    state.dy = Math.max(0, event.clientY - state.startY);
    node.style.transition = 'none';
    node.style.transform = `translateY(${state.dy}px)`;
  };
  const onPointerUp = () => {
    const state = drag.current;
    const node = panel.current;
    drag.current = null;
    if (!state || !node) return;
    node.style.transition = '';
    node.style.transform = '';
    if (state.dy > 110) onClose();
  };

  return createPortal(
    <>
      <div className={[styles.scrim, closing && styles.scrimClosing].filter(Boolean).join(' ')} onClick={safeClose} aria-hidden />
      <div
        ref={panel}
        className={[styles.sheet, closing && styles.sheetClosing].filter(Boolean).join(' ')}
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        tabIndex={-1}
      >
        <div onPointerDown={onPointerDown} onPointerMove={onPointerMove} onPointerUp={onPointerUp} onPointerCancel={onPointerUp}>
          <div className={styles.handle} aria-hidden />
          <div className={styles.header}>
            <div className={styles.titles}>
              <h2 id={titleId} className="t-title-lg">
                {title}
              </h2>
              {subtitle ? <p className="t-body-sm">{subtitle}</p> : null}
            </div>
            {action}
          </div>
        </div>
        <div className={styles.body}>{children}</div>
        {footer ? <div className={styles.footer}>{footer}</div> : null}
      </div>
    </>,
    document.body,
  );
}

type DialogProps = {
  open: boolean;
  onClose: () => void;
  title: string;
  children: ReactNode;
  actions: ReactNode;
};

export function Dialog({ open, onClose, title, children, actions }: DialogProps) {
  const { mounted, closing } = usePresence(open, 120);
  const panel = useRef<HTMLDivElement>(null);
  const titleId = useId();
  useScrollLock(mounted);
  useOverlayFocus(open, panel, onClose);
  if (!mounted) return null;
  return createPortal(
    <>
      <div
        className={[styles.scrim, styles.dialogScrim, closing && styles.scrimClosing].filter(Boolean).join(' ')}
        onClick={onClose}
        aria-hidden
      />
      <div ref={panel} className={styles.dialog} role="alertdialog" aria-modal="true" aria-labelledby={titleId} tabIndex={-1}>
        <h2 id={titleId} className="t-headline-sm">
          {title}
        </h2>
        <div className="t-body-md" style={{ color: 'var(--muted)' }}>
          {children}
        </div>
        <div className={styles.dialogActions}>{actions}</div>
      </div>
    </>,
    document.body,
  );
}
