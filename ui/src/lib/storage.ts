/**
 * Device-local preferences (theme, masked balances, cached currency), the
 * equivalent of `PreferencesService`. Storage can throw in private mode or
 * when blocked, so every access degrades to the default instead.
 */

export const StorageKeys = {
  theme: 'et.theme',
  /** 'matte' for Matte & Sand; anything else is the current (Gothic Noir) palette. */
  palette: 'et.palette',
  hideBalances: 'et.hideBalances',
  currency: 'et.currency',
  /** '1' once the user turned push notifications on for this device; cleared when they turn them off. */
  pushEnabled: 'et.pushEnabled',
} as const;

export function readPref(key: string): string | null {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
}

export function writePref(key: string, value: string | null): void {
  try {
    if (value == null) localStorage.removeItem(key);
    else localStorage.setItem(key, value);
  } catch {
    // Losing a preference costs only its default on the next launch.
  }
}
