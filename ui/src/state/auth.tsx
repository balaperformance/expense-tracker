/**
 * Authentication state. Port of `providers/auth_provider.dart`.
 *
 * The Supabase SDK persists and refreshes the session itself; this mirrors
 * its stream so the UI has one synchronous source of truth.
 */
import type { User } from '@supabase/supabase-js';
import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';

import { getSupabase } from '@/lib/supabase';

export type AuthStage = 'initialising' | 'signedOut' | 'signedIn';

type AuthState = {
  stage: AuthStage;
  user: User | null;
  userId: string | null;
  email: string | null;
  /** Best-effort name from sign-up metadata, before the profile row loads. */
  metadataName: string | null;
};

const AuthContext = createContext<AuthState | null>(null);

function metadataName(user: User | null): string | null {
  const name: unknown = user?.user_metadata.full_name;
  return typeof name === 'string' && name.trim() ? name.trim() : null;
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [stage, setStage] = useState<AuthStage>('initialising');
  const [user, setUser] = useState<User | null>(null);

  useEffect(() => {
    const auth = getSupabase().auth;
    let active = true;

    void auth.getSession().then(({ data }) => {
      if (!active) return;
      setUser(data.session?.user ?? null);
      setStage(data.session ? 'signedIn' : 'signedOut');
    });

    const { data } = auth.onAuthStateChange((_event, session) => {
      if (!active) return;
      setUser(session?.user ?? null);
      setStage(session ? 'signedIn' : 'signedOut');
    });

    return () => {
      active = false;
      data.subscription.unsubscribe();
    };
  }, []);

  const value = useMemo<AuthState>(
    () => ({
      stage,
      user,
      userId: user?.id ?? null,
      email: user?.email ?? null,
      metadataName: metadataName(user),
    }),
    [stage, user],
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

/**
 * A fixed signed-in state, for the development preview only (src/dev) —
 * production code always goes through [AuthProvider] and the real session.
 */
export function StaticAuthProvider({ user, children }: { user: User; children: ReactNode }) {
  const value = useMemo<AuthState>(
    () => ({ stage: 'signedIn', user, userId: user.id, email: user.email ?? null, metadataName: metadataName(user) }),
    [user],
  );
  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthState {
  const value = useContext(AuthContext);
  if (!value) throw new Error('useAuth must be used inside AuthProvider');
  return value;
}

/** The signed-in user's id. Only call below the signed-in boundary. */
export function useUserId(): string {
  const { userId } = useAuth();
  if (!userId) throw new Error('useUserId called while signed out');
  return userId;
}
