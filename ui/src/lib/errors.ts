/**
 * Translates low-level Supabase / network failures into user-safe messages.
 * Port of `core/errors/app_exception.dart`.
 *
 * Raw error text can embed query fragments and identifiers, so the UI only
 * ever shows a mapped message. Financial values and credentials never appear
 * in one.
 */
import { isAuthError, type AuthError } from '@supabase/supabase-js';

import { PASSWORD_HINT } from './validators';

export class AppError extends Error {
  override readonly name = 'AppError';
  readonly isAuthExpired: boolean;

  constructor(message: string, options?: { isAuthExpired?: boolean }) {
    super(message);
    this.isAuthExpired = options?.isAuthExpired ?? false;
  }
}

type PostgrestLike = { code?: unknown; message?: unknown; details?: unknown; hint?: unknown };

function isPostgrestError(error: unknown): error is PostgrestLike & { code: string; message: string } {
  if (typeof error !== 'object' || error === null) return false;
  const candidate = error as PostgrestLike;
  return (
    typeof candidate.code === 'string' &&
    typeof candidate.message === 'string' &&
    ('details' in candidate || 'hint' in candidate)
  );
}

export function isPostgrestCode(error: unknown, code: string): boolean {
  return isPostgrestError(error) && error.code === code;
}

function mapAuth(error: AuthError): string {
  const raw = error.message.toLowerCase();
  const code = (error.code ?? '').toLowerCase();

  if (raw.includes('email not confirmed') || raw.includes('not confirmed') || code === 'email_not_confirmed') {
    return 'Please confirm your email address first. Check your inbox for the verification link.';
  }
  if (raw.includes('invalid login credentials') || code === 'invalid_credentials') {
    return 'Incorrect email or password.';
  }
  if (raw.includes('user already registered') || raw.includes('already been registered') || code === 'user_already_exists') {
    return 'An account with this email already exists. Try signing in.';
  }
  if (raw.includes('password should be at least')) {
    return 'Password is too short. Use at least 6 characters.';
  }
  if (code === 'weak_password' || raw.includes('weak password')) {
    return `That password is too weak. ${PASSWORD_HINT}`;
  }
  if (raw.includes('should be different from the old password') || code === 'same_password') {
    return 'Your new password must be different from the current one.';
  }
  if (raw.includes('reauthentication') || raw.includes('not authenticated')) {
    return 'Please sign in again and retry.';
  }
  if (raw.includes('rate limit') || raw.includes('too many') || code.includes('rate_limit')) {
    return 'Too many attempts. Please wait a moment and try again.';
  }
  if (raw.includes('invalid email') || code === 'email_address_invalid') {
    return 'That email address does not look valid.';
  }
  if (error.name === 'AuthRetryableFetchError') {
    return 'No internet connection. Check your network and try again.';
  }
  return 'Authentication failed. Please try again.';
}

function mapPostgrest(error: { code: string; message: string }): AppError {
  switch (error.code) {
    case '23505':
      return new AppError('That entry already exists.');
    case '23503':
      return new AppError('This item is still linked to other records.');
    case '23502':
      return new AppError('A required field is missing.');
    case '42501':
      return new AppError('You do not have permission to do that.');
    case 'PGRST301':
      return new AppError('Your session expired. Please sign in again.', { isAuthExpired: true });
    case 'PGRST303':
      return new AppError('Your device clock looks out of sync. Retrying usually fixes it.');
  }
  const raw = error.message.toLowerCase();
  if (raw.includes('row-level security') || raw.includes('policy')) {
    return new AppError('You do not have permission to do that.');
  }
  if (raw.includes('jwt expired')) {
    return new AppError('Your session expired. Please sign in again.', { isAuthExpired: true });
  }
  if (raw.includes('merchant')) {
    return new AppError(
      'The database is missing the "merchant" column on expenses. Run the migration provided in the setup notes.',
    );
  }
  if (raw.includes('failed to fetch') || raw.includes('network')) {
    return new AppError('No internet connection. Check your network and try again.');
  }
  return new AppError('Could not reach the database. Please try again.');
}

export function toAppError(error: unknown): AppError {
  if (error instanceof AppError) return error;
  if (isAuthError(error)) return new AppError(mapAuth(error));
  if (isPostgrestError(error)) return mapPostgrest(error);
  if (error instanceof TypeError && /fetch|network|load failed/i.test(error.message)) {
    return new AppError('No internet connection. Check your network and try again.');
  }
  if (typeof navigator !== 'undefined' && !navigator.onLine) {
    return new AppError('No internet connection. Check your network and try again.');
  }
  return new AppError('Something went wrong. Please try again.');
}

/** The message for any failure, for places that only display text. */
export function errorMessage(error: unknown, fallback?: string): string {
  if (error == null) return fallback ?? 'Something went wrong. Please try again.';
  const mapped = toAppError(error);
  return mapped.message;
}

/** Runs [action] and rethrows anything as an [AppError]. */
export async function guarded<T>(action: () => Promise<T>): Promise<T> {
  try {
    return await action();
  } catch (error) {
    throw toAppError(error);
  }
}
