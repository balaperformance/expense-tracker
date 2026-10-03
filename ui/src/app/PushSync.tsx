import { useEffect, useRef } from 'react';

import { useCapabilities } from '@/hooks/data';
import { syncPushSubscription } from '@/services/push';

/** Often enough to follow a traveller's time zone, rarely enough to cost nothing. */
const RESYNC_AFTER_MS = 60 * 60 * 1000;

/**
 * Keeps a device that has notifications on registered with the project: its
 * time zone (the server decides "10 PM" from it) and its subscription, which
 * the browser can replace. Renders nothing and never asks for permission.
 */
export function PushSync() {
  const enabled = useCapabilities().notifications;
  const last = useRef(0);

  useEffect(() => {
    if (!enabled) return;
    const sync = () => {
      if (Date.now() - last.current < RESYNC_AFTER_MS) return;
      last.current = Date.now();
      syncPushSubscription().catch((error: unknown) => {
        // Not worth interrupting anyone for: the next visit tries again.
        console.warn('Could not refresh the push subscription.', error);
        last.current = 0;
      });
    };
    sync();
    const onVisible = () => {
      if (document.visibilityState === 'visible') sync();
    };
    document.addEventListener('visibilitychange', onVisible);
    return () => document.removeEventListener('visibilitychange', onVisible);
  }, [enabled]);

  return null;
}
