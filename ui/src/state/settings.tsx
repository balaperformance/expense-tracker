/**
 * Profile, currency, theme and masked balances. Port of
 * `providers/settings_provider.dart`.
 *
 * Theme and "hide balances" are device-local (the profiles table has no
 * column for them); name and currency round-trip to Supabase.
 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';

import { profileDisplayName, type Profile } from '@/domain/models';
import { currencySymbol, DEFAULT_CURRENCY } from '@/lib/format';
import { readPref, StorageKeys, writePref } from '@/lib/storage';
import { fetchOrCreateProfile, updateProfile } from '@/services/profile';

import { useAuth } from './auth';
import { keys } from './queryClient';

export type ThemePreference = 'system' | 'light' | 'dark';

/** The visual design language, independent of light/dark. 'current' is Gothic Noir. */
export type PalettePreference = 'current' | 'matte';

function readTheme(): ThemePreference {
  const saved = readPref(StorageKeys.theme);
  return saved === 'light' || saved === 'dark' ? saved : 'system';
}

/** Everyone stays on the current palette until they choose Matte & Sand. */
function readPalette(): PalettePreference {
  return readPref(StorageKeys.palette) === 'matte' ? 'matte' : 'current';
}

const darkQuery = () => window.matchMedia('(prefers-color-scheme: dark)');

/** The page colour of each palette, for the browser chrome and iOS status bar area. */
const PAGE_COLOR: Record<PalettePreference, { light: string; dark: string }> = {
  current: { light: '#F5F4F4', dark: '#0B0909' },
  matte: { light: '#FBFAF7', dark: '#111111' },
};

function applyAppearance(preference: ThemePreference, palette: PalettePreference): void {
  const dark = preference === 'dark' || (preference === 'system' && darkQuery().matches);
  const root = document.documentElement;
  root.dataset.theme = dark ? 'dark' : 'light';
  root.dataset.palette = palette;
  root.style.colorScheme = dark ? 'dark' : 'light';
  // The browser chrome (and iOS status bar area) follows the page colour.
  for (const meta of document.querySelectorAll<HTMLMetaElement>('meta[name="theme-color"]')) {
    meta.content = dark ? PAGE_COLOR[palette].dark : PAGE_COLOR[palette].light;
    meta.removeAttribute('media');
  }
}

type SettingsState = {
  theme: ThemePreference;
  setTheme: (theme: ThemePreference) => void;
  palette: PalettePreference;
  setPalette: (palette: PalettePreference) => void;
  balancesHidden: boolean;
  toggleBalancesHidden: () => void;
  profile: Profile | null;
  displayName: string;
  currency: string;
  symbol: string;
  updateName: (name: string) => Promise<void>;
  updateCurrency: (code: string) => Promise<void>;
  /** Sign-out: user-scoped preferences go; the theme and palette are the device's and stay. */
  resetUserScoped: () => void;
};

const SettingsContext = createContext<SettingsState | null>(null);

export function SettingsProvider({ children }: { children: ReactNode }) {
  const { userId, metadataName } = useAuth();
  const client = useQueryClient();
  const [theme, setThemeState] = useState<ThemePreference>(readTheme);
  const [palette, setPaletteState] = useState<PalettePreference>(readPalette);
  // Hidden by default: the next person to reach this device must not
  // inherit a reveal the previous account switched on.
  const [balancesHidden, setBalancesHidden] = useState(() => readPref(StorageKeys.hideBalances) !== 'false');
  // The last known currency, so amounts format correctly before the profile loads.
  const [storedCurrency, setStoredCurrency] = useState(() => readPref(StorageKeys.currency) ?? DEFAULT_CURRENCY);
  // Set while a currency change is saving, so every amount re-formats at once.
  const [pendingCurrency, setPendingCurrency] = useState<string | null>(null);

  useEffect(() => {
    applyAppearance(theme, palette);
    if (theme !== 'system') return;
    const query = darkQuery();
    const onChange = () => applyAppearance('system', palette);
    query.addEventListener('change', onChange);
    return () => query.removeEventListener('change', onChange);
  }, [theme, palette]);

  const profileQuery = useQuery({
    queryKey: keys.profile(userId ?? 'anonymous'),
    queryFn: () => fetchOrCreateProfile(userId ?? '', metadataName),
    enabled: userId != null,
    staleTime: 5 * 60_000,
  });
  const profile = profileQuery.data ?? null;

  useEffect(() => {
    if (profile?.currency) writePref(StorageKeys.currency, profile.currency);
  }, [profile?.currency]);

  const mutation = useMutation({
    mutationFn: (patch: { fullName?: string; currency?: string }) => updateProfile(userId ?? '', patch),
    onSuccess: (updated) => client.setQueryData(keys.profile(updated.id), updated),
  });
  const { mutateAsync } = mutation;

  const setTheme = useCallback((next: ThemePreference) => {
    setThemeState(next);
    writePref(StorageKeys.theme, next);
  }, []);

  const setPalette = useCallback((next: PalettePreference) => {
    setPaletteState(next);
    writePref(StorageKeys.palette, next);
  }, []);

  const toggleBalancesHidden = useCallback(() => {
    setBalancesHidden((current) => {
      writePref(StorageKeys.hideBalances, String(!current));
      return !current;
    });
  }, []);

  const updateName = useCallback(async (name: string) => {
    await mutateAsync({ fullName: name });
  }, [mutateAsync]);

  const updateCurrency = useCallback(
    async (code: string) => {
      // Optimistic: amounts re-format immediately, and revert if the save fails.
      setPendingCurrency(code);
      try {
        await mutateAsync({ currency: code });
      } finally {
        setPendingCurrency(null);
      }
    },
    [mutateAsync],
  );

  const resetUserScoped = useCallback(() => {
    setBalancesHidden(true);
    writePref(StorageKeys.hideBalances, 'true');
    writePref(StorageKeys.currency, null);
    setStoredCurrency(DEFAULT_CURRENCY);
  }, []);

  const currency = pendingCurrency ?? profile?.currency ?? storedCurrency;

  const value = useMemo<SettingsState>(
    () => ({
      theme,
      setTheme,
      palette,
      setPalette,
      balancesHidden,
      toggleBalancesHidden,
      profile,
      displayName: profileDisplayName(profile),
      currency,
      symbol: currencySymbol(currency),
      updateName,
      updateCurrency,
      resetUserScoped,
    }),
    [theme, setTheme, palette, setPalette, balancesHidden, toggleBalancesHidden, profile, currency, updateName, updateCurrency, resetUserScoped],
  );

  return <SettingsContext.Provider value={value}>{children}</SettingsContext.Provider>;
}

export function useSettings(): SettingsState {
  const value = useContext(SettingsContext);
  if (!value) throw new Error('useSettings must be used inside SettingsProvider');
  return value;
}
