import { useSyncExternalStore } from 'react';

/** Whether the page is currently in the dark theme (`<html data-theme>`). */
function subscribe(onChange: () => void) {
  const observer = new MutationObserver(onChange);
  observer.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
  return () => observer.disconnect();
}

const snapshot = () => document.documentElement.dataset.theme === 'dark';

export function useIsDark(): boolean {
  return useSyncExternalStore(subscribe, snapshot, () => false);
}
