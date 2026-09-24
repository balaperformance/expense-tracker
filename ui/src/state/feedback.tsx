/**
 * App-wide feedback: toasts (AppFeedback.success / error / info) and the
 * confirmation dialog (AppFeedback.confirm), as promise-returning hooks.
 */
import { createContext, useCallback, useContext, useMemo, useRef, useState, type CSSProperties, type ReactNode } from 'react';
import { createPortal } from 'react-dom';

import { Button } from '@/components/ui/Button';
import { Icon, type IconName } from '@/components/ui/Icon';
import { Dialog } from '@/components/ui/Sheet';
import sheetStyles from '@/components/ui/Sheet.module.css';

type ToastKind = 'success' | 'error' | 'info';
type Toast = { id: number; kind: ToastKind; message: string; action?: { label: string; run: () => void } };

type ConfirmOptions = {
  title: string;
  message: ReactNode;
  confirmLabel?: string;
  cancelLabel?: string;
  destructive?: boolean;
};

type FeedbackApi = {
  toast: (kind: ToastKind, message: string, action?: Toast['action']) => void;
  confirm: (options: ConfirmOptions) => Promise<boolean>;
};

const FeedbackContext = createContext<FeedbackApi | null>(null);

const TOAST_ICON: Record<ToastKind, IconName> = { success: 'checkCircle', error: 'error', info: 'info' };
const TOAST_TONE: Record<ToastKind, string> = { success: 'var(--income)', error: 'var(--expense)', info: 'var(--accent)' };

export function FeedbackProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([]);
  const [dialog, setDialog] = useState<(ConfirmOptions & { open: boolean }) | null>(null);
  const resolver = useRef<((value: boolean) => void) | null>(null);
  const nextId = useRef(1);

  const toast = useCallback<FeedbackApi['toast']>((kind, message, action) => {
    const id = nextId.current++;
    setToasts((current) => [...current.slice(-2), { id, kind, message, action }]);
    setTimeout(() => setToasts((current) => current.filter((t) => t.id !== id)), action ? 5000 : 3200);
  }, []);

  const confirm = useCallback<FeedbackApi['confirm']>((options) => {
    resolver.current?.(false);
    setDialog({ ...options, open: true });
    return new Promise<boolean>((resolve) => {
      resolver.current = resolve;
    });
  }, []);

  const settle = (value: boolean) => {
    resolver.current?.(value);
    resolver.current = null;
    setDialog((current) => (current ? { ...current, open: false } : current));
  };

  const api = useMemo(() => ({ toast, confirm }), [toast, confirm]);

  return (
    <FeedbackContext.Provider value={api}>
      {children}
      {createPortal(
        <div className={sheetStyles.toasts} aria-live="polite">
          {toasts.map((t) => (
            <div
              key={t.id}
              className={sheetStyles.toast}
              style={{ '--tone': TOAST_TONE[t.kind] } as CSSProperties}
              role={t.kind === 'error' ? 'alert' : 'status'}
            >
              <Icon name={TOAST_ICON[t.kind]} size={18} />
              <span>{t.message}</span>
              {t.action ? (
                <button type="button" className={sheetStyles.toastAction} onClick={t.action.run}>
                  {t.action.label}
                </button>
              ) : null}
            </div>
          ))}
        </div>,
        document.body,
      )}
      {dialog ? (
        <Dialog
          open={dialog.open}
          onClose={() => settle(false)}
          title={dialog.title}
          actions={
            <>
              <Button label={dialog.cancelLabel ?? 'Cancel'} variant="ghost" onClick={() => settle(false)} />
              <Button
                label={dialog.confirmLabel ?? (dialog.destructive === false ? 'Confirm' : 'Delete')}
                variant={dialog.destructive === false ? 'primary' : 'danger'}
                onClick={() => settle(true)}
                autoFocus
              />
            </>
          }
        >
          {dialog.message}
        </Dialog>
      ) : null}
    </FeedbackContext.Provider>
  );
}

export function useFeedback(): FeedbackApi {
  const api = useContext(FeedbackContext);
  if (!api) throw new Error('useFeedback must be used inside FeedbackProvider');
  return api;
}
