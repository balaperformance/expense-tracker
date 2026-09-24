/**
 * `public.profiles` (id = auth user id). Port of `repositories/profile_repository.dart`.
 */
import { DEFAULT_CURRENCY } from '@/lib/format';
import { retryOnTransientAuth } from '@/lib/retry';
import { asRow } from '@/lib/row';
import { profileFromRow, type Profile } from '@/domain/models';

import { db, nowIso, rowOf } from './db';

/**
 * Reads the signed-in user's profile, creating it if no trigger has. Falls
 * back to a transient in-memory profile if the row cannot be created, so the
 * app still renders instead of blocking the user at launch.
 */
export async function fetchOrCreateProfile(userId: string, fallbackName: string | null): Promise<Profile> {
  const existing = await retryOnTransientAuth(async () => {
    const result = await db().from('profiles').select().eq('id', userId).maybeSingle();
    if (result.error) throw result.error;
    return asRow(result.data);
  });
  if (existing) return profileFromRow(existing);

  const inserted = await db()
    .from('profiles')
    .insert({ id: userId, full_name: fallbackName, currency: DEFAULT_CURRENCY })
    .select()
    .single();
  const row = inserted.error ? null : asRow(inserted.data);
  return row ? profileFromRow(row) : { id: userId, fullName: fallbackName, currency: DEFAULT_CURRENCY };
}

export async function updateProfile(
  userId: string,
  patch: { fullName?: string; currency?: string },
): Promise<Profile> {
  const body: Record<string, unknown> = { updated_at: nowIso() };
  if (patch.fullName != null) body.full_name = patch.fullName.trim();
  if (patch.currency != null) body.currency = patch.currency;
  const row = rowOf(await db().from('profiles').update(body).eq('id', userId).select().single());
  return profileFromRow(row);
}
