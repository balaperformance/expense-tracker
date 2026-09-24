/**
 * What happens between "signed in" and "home screen". Port of `AuthGate`'s
 * bootstrap: probe the optional schema, fetch-or-create the profile, and seed
 * the default categories and payment methods — idempotently.
 */
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useEffect, useRef, type ReactNode } from 'react';

import { BrandLockup } from '@/components/layout/Brand';
import layout from '@/components/layout/Layout.module.css';
import { Button } from '@/components/ui/Button';
import { ErrorView, ProgressBar } from '@/components/ui/Feedback';
import { errorMessage } from '@/lib/errors';
import { signOut } from '@/services/auth';
import { resetCapabilities, resolveCapabilities } from '@/services/capabilities';
import { ensureDefaultCategories, ensureDefaultPaymentMethods } from '@/services/catalog';
import { fetchOrCreateProfile } from '@/services/profile';

import { useAiChat } from './aiChat';
import { useAuth } from './auth';
import { resetListState } from './listState';
import { keys } from './queryClient';
import { useSettings } from './settings';

export function Splash({ message }: { message?: string }) {
  return (
    <div className={layout.splash}>
      <div className={layout.splashInner}>
        <BrandLockup tagline="Spend with intention" />
        <ProgressBar />
        {message ? <p className="t-body-sm">{message}</p> : null}
      </div>
    </div>
  );
}

/** Blocks the signed-in app until its reference data exists. */
export function SessionBootstrap({ children }: { children: ReactNode }) {
  const { userId, metadataName } = useAuth();
  const client = useQueryClient();

  const bootstrap = useQuery({
    queryKey: ['bootstrap', userId],
    enabled: userId != null,
    staleTime: Infinity,
    gcTime: Infinity,
    retry: 1,
    queryFn: async () => {
      const id = userId ?? '';
      const capabilities = await resolveCapabilities(true);
      client.setQueryData(keys.capabilities(id), capabilities);
      const profile = await fetchOrCreateProfile(id, metadataName);
      client.setQueryData(keys.profile(id), profile);
      const [categories, methods] = await Promise.all([ensureDefaultCategories(id), ensureDefaultPaymentMethods(id)]);
      client.setQueryData(keys.categories(id), categories);
      client.setQueryData(keys.paymentMethods(id), methods);
      return true;
    },
  });

  if (bootstrap.isPending) return <Splash message="Setting things up…" />;
  if (bootstrap.isError) {
    return (
      <div className={layout.splash}>
        <div className="stack gap-md" style={{ alignItems: 'center' }}>
          <ErrorView message={errorMessage(bootstrap.error)} onRetry={() => void bootstrap.refetch()} />
          <Button label="Sign out" variant="ghost" onClick={() => void signOut()} />
        </div>
      </div>
    );
  }
  return children;
}

/**
 * Clears everything user-scoped when the signed-in user changes or signs out,
 * so nothing from one account is ever shown to the next.
 */
export function SessionCleanup() {
  const { userId, stage } = useAuth();
  const client = useQueryClient();
  const chat = useAiChat();
  const settings = useSettings();
  const previous = useRef<string | null>(null);
  const { reset: resetChat } = chat;
  const { resetUserScoped } = settings;

  useEffect(() => {
    if (stage === 'initialising') return;
    const before = previous.current;
    previous.current = userId;
    if (before != null && before !== userId) {
      client.clear();
      resetCapabilities();
      resetListState();
      resetChat();
      if (userId == null) resetUserScoped();
    }
  }, [userId, stage, client, resetChat, resetUserScoped]);

  return null;
}
