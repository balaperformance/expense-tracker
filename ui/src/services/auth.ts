/**
 * All authentication I/O. Port of `repositories/auth_repository.dart`.
 * Neither password is ever stored, logged or put in an error message.
 */
import { AppError, toAppError } from '@/lib/errors';
import { getSupabase } from '@/lib/supabase';

export type SignUpOutcome = { needsEmailConfirmation: boolean; email: string };

export async function signUp(email: string, password: string, fullName: string): Promise<SignUpOutcome> {
  const { data, error } = await getSupabase().auth.signUp({
    email: email.trim(),
    password,
    options: {
      data: { full_name: fullName.trim() },
      // Lands the confirmation link back on this app. Supabase falls back to
      // the project Site URL if this origin is not in its redirect allow-list.
      emailRedirectTo: `${window.location.origin}/`,
    },
  });
  if (error) throw toAppError(error);
  return { needsEmailConfirmation: data.session == null, email: email.trim() };
}

export async function signIn(email: string, password: string): Promise<void> {
  const { error } = await getSupabase().auth.signInWithPassword({ email: email.trim(), password });
  if (error) throw toAppError(error);
}

export async function signOut(): Promise<void> {
  const { error } = await getSupabase().auth.signOut();
  if (error) throw toAppError(error);
}

export async function resendConfirmation(email: string): Promise<void> {
  const { error } = await getSupabase().auth.resend({
    type: 'signup',
    email: email.trim(),
    options: { emailRedirectTo: `${window.location.origin}/` },
  });
  if (error) throw toAppError(error);
}

/** Preconditions that need no network. Null when the change may be attempted. */
export function checkPasswordChange(email: string | null | undefined, current: string, next: string): string | null {
  if (!email) return 'This account has no password to change. Sign in with an email address first.';
  if (!current) return 'Enter your current password.';
  if (!next) return 'Enter a new password.';
  if (current === next) return 'Your new password must be different from the current one.';
  return null;
}

/**
 * Changes the password after proving the current one with a real sign-in —
 * the only way to verify it without a privileged key. A failed sign-in does
 * not disturb the open session, so a wrong current password leaves the user
 * exactly where they were.
 */
export async function changePassword(currentPassword: string, newPassword: string): Promise<void> {
  const auth = getSupabase().auth;
  const { data } = await auth.getUser();
  const email = data.user?.email;
  const problem = checkPasswordChange(email, currentPassword, newPassword);
  if (problem) throw new AppError(problem);

  const proof = await auth.signInWithPassword({ email: email ?? '', password: currentPassword });
  if (proof.error) {
    if (proof.error.message.toLowerCase().includes('invalid login credentials') || proof.error.code === 'invalid_credentials') {
      throw new AppError('Your current password is not correct.');
    }
    throw toAppError(proof.error);
  }

  const { error } = await auth.updateUser({ password: newPassword });
  if (error) throw toAppError(error);
}
