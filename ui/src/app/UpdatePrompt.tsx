import { useRegisterSW } from 'virtual:pwa-register/react';

import { Button } from '@/components/ui/Button';
import { Icon } from '@/components/ui/Icon';
import sheetStyles from '@/components/ui/Sheet.module.css';

const HOUR = 60 * 60 * 1000;

/**
 * Registers the service worker and offers a new version when one is ready,
 * rather than swapping code under a half-filled form.
 */
export function UpdatePrompt() {
  const {
    needRefresh: [needRefresh, setNeedRefresh],
    updateServiceWorker,
  } = useRegisterSW({
    onRegisteredSW(_url, registration) {
      if (!registration) return;
      // An installed PWA can stay open for days; look for updates hourly.
      setInterval(() => void registration.update(), HOUR);
    },
  });

  if (!needRefresh) return null;
  return (
    <div className={sheetStyles.toasts} style={{ zIndex: 95 }}>
      <div className={sheetStyles.toast} role="status">
        <Icon name="refresh" size={18} />
        <span>A new version is ready.</span>
        <Button label="Later" variant="ghost" size="sm" onClick={() => setNeedRefresh(false)} style={{ color: 'var(--bg)' }} />
        <Button label="Reload" size="sm" variant="secondary" onClick={() => void updateServiceWorker(true)} style={{ color: 'var(--bg)', borderColor: 'currentColor' }} />
      </div>
    </div>
  );
}
