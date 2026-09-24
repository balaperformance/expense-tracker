/**
 * `public.categories` and `public.payment_methods`. Ports of
 * `category_repository.dart` and `payment_method_repository.dart`.
 */
import { AppError } from '@/lib/errors';
import { DEFAULT_CATEGORIES, DEFAULT_PAYMENT_METHODS } from '@/domain/defaults';
import { categoryFromRow, paymentMethodFromRow, type ExpenseCategory, type PaymentMethod } from '@/domain/models';

import { db, ensureOk, rowOf, rowsOf } from './db';

// ---------------------------------------------------------------------------
// Categories
// ---------------------------------------------------------------------------

export async function fetchCategories(userId: string): Promise<ExpenseCategory[]> {
  const result = await db().from('categories').select().eq('user_id', userId).order('name', { ascending: true });
  return rowsOf(result).map(categoryFromRow);
}

/**
 * Inserts any missing default categories and returns the full list.
 * Case-insensitive on name, so re-running it (or a seeding trigger having
 * run already) never produces duplicates.
 */
export async function ensureDefaultCategories(userId: string): Promise<ExpenseCategory[]> {
  const existing = await fetchCategories(userId);
  const taken = new Set(existing.map((c) => c.name.toLowerCase()));
  const missing = DEFAULT_CATEGORIES.filter((d) => !taken.has(d.name.toLowerCase())).map((d) => ({
    user_id: userId,
    name: d.name,
    icon: d.icon,
    color: d.color,
    is_default: true,
  }));
  if (!missing.length) return existing;
  ensureOk(await db().from('categories').insert(missing));
  return fetchCategories(userId);
}

/** Rejects a duplicate name before the database would, with a precise message. */
async function assertCategoryNameFree(userId: string, name: string, excludeId?: string): Promise<void> {
  const matches = rowsOf(
    await db().from('categories').select('id, name').eq('user_id', userId).ilike('name', name.trim()),
  );
  if (matches.some((row) => row.id !== excludeId)) {
    throw new AppError('A category with that name already exists.');
  }
}

export type CategoryDraft = { name: string; icon: string; color: string };

export async function createCategory(userId: string, draft: CategoryDraft): Promise<ExpenseCategory> {
  await assertCategoryNameFree(userId, draft.name);
  const row = rowOf(
    await db()
      .from('categories')
      .insert({ user_id: userId, name: draft.name.trim(), icon: draft.icon, color: draft.color, is_default: false })
      .select()
      .single(),
  );
  return categoryFromRow(row);
}

export async function updateCategory(userId: string, id: string, draft: CategoryDraft): Promise<ExpenseCategory> {
  await assertCategoryNameFree(userId, draft.name, id);
  const row = rowOf(
    await db()
      .from('categories')
      .update({ name: draft.name.trim(), icon: draft.icon, color: draft.color })
      .eq('id', id)
      .eq('user_id', userId)
      .select()
      .single(),
  );
  return categoryFromRow(row);
}

/** Detaches expenses first so a foreign-key restriction cannot block the delete. */
export async function deleteCategory(userId: string, id: string): Promise<void> {
  ensureOk(await db().from('expenses').update({ category_id: null }).eq('category_id', id).eq('user_id', userId));
  ensureOk(await db().from('categories').delete().eq('id', id).eq('user_id', userId));
}

// ---------------------------------------------------------------------------
// Payment methods
// ---------------------------------------------------------------------------

export async function fetchPaymentMethods(userId: string): Promise<PaymentMethod[]> {
  const result = await db().from('payment_methods').select().eq('user_id', userId).order('name', { ascending: true });
  return rowsOf(result).map(paymentMethodFromRow);
}

export async function ensureDefaultPaymentMethods(userId: string): Promise<PaymentMethod[]> {
  const existing = await fetchPaymentMethods(userId);
  const taken = new Set(existing.map((m) => m.name.toLowerCase()));
  const missing = DEFAULT_PAYMENT_METHODS.filter((name) => !taken.has(name.toLowerCase())).map((name) => ({
    user_id: userId,
    name,
  }));
  if (!missing.length) return existing;
  ensureOk(await db().from('payment_methods').insert(missing));
  return fetchPaymentMethods(userId);
}

export async function createPaymentMethod(userId: string, name: string): Promise<PaymentMethod> {
  const clash = rowsOf(await db().from('payment_methods').select('id').eq('user_id', userId).ilike('name', name.trim()));
  if (clash.length) throw new AppError('That payment method already exists.');
  const row = rowOf(
    await db().from('payment_methods').insert({ user_id: userId, name: name.trim() }).select().single(),
  );
  return paymentMethodFromRow(row);
}

export async function deletePaymentMethod(userId: string, id: string): Promise<void> {
  ensureOk(
    await db().from('expenses').update({ payment_method_id: null }).eq('payment_method_id', id).eq('user_id', userId),
  );
  ensureOk(await db().from('payment_methods').delete().eq('id', id).eq('user_id', userId));
}
