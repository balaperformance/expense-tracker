import { useEffect, useState } from 'react';

type BeforeInstallPromptEvent = Event & {
  prompt: () => Promise<void>;
  userChoice: Promise<{ outcome: 'accepted' | 'dismissed' }>;
};

let deferred: BeforeInstallPromptEvent | null = null;
const listeners = new Set<() => void>();

// Captured as early as possible: the event fires once, often before any screen mounts.
if (typeof window !== 'undefined') {
  window.addEventListener('beforeinstallprompt', (event) => {
    event.preventDefault();
    deferred = event as BeforeInstallPromptEvent;
    listeners.forEach((notify) => notify());
  });
  window.addEventListener('appinstalled', () => {
    deferred = null;
    listeners.forEach((notify) => notify());
  });
}

export const isStandalone = () =>
  window.matchMedia('(display-mode: standalone)').matches || (navigator as Navigator & { standalone?: boolean }).standalone === true;

const isIos = () => /iphone|ipad|ipod/i.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);

/** How this browser can install the app: a prompt, iOS's Share-sheet steps, or not at all. */
export function useInstallPrompt() {
  const [, force] = useState(0);
  useEffect(() => {
    const notify = () => force((n) => n + 1);
    listeners.add(notify);
    return () => {
      listeners.delete(notify);
    };
  }, []);

  if (isStandalone()) return { mode: 'installed' as const };
  if (deferred) {
    const event = deferred;
    return {
      mode: 'prompt' as const,
      install: async () => {
        await event.prompt();
        await event.userChoice;
        deferred = null;
        force((n) => n + 1);
      },
    };
  }
  if (isIos()) return { mode: 'ios' as const };
  return { mode: 'unavailable' as const };
}
