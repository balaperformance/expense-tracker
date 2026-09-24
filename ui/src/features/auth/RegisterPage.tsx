import { useState, type SyntheticEvent } from 'react';
import { useNavigate } from 'react-router';

import { Button } from '@/components/ui/Button';
import { InlineError } from '@/components/ui/Feedback';
import { PasswordField, TextField } from '@/components/ui/Fields';
import { errorMessage } from '@/lib/errors';
import {
  PASSWORD_HINT,
  validateConfirmPassword,
  validateEmail,
  validateNewPassword,
  validateRequired,
} from '@/lib/validators';
import { signUp } from '@/services/auth';

import styles from './Auth.module.css';
import { AuthLayout } from './AuthLayout';

type Errors = Partial<Record<'name' | 'email' | 'password' | 'confirm', string | null>>;

export function RegisterPage() {
  const navigate = useNavigate();
  const [name, setName] = useState('');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [confirm, setConfirm] = useState('');
  const [errors, setErrors] = useState<Errors>({});
  const [failure, setFailure] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const submit = async (event?: SyntheticEvent) => {
    event?.preventDefault();
    if (busy) return;
    const next: Errors = {
      name: validateRequired(name, 'Name'),
      email: validateEmail(email),
      password: validateNewPassword(password),
      confirm: validateConfirmPassword(confirm, password),
    };
    setErrors(next);
    if (Object.values(next).some(Boolean)) return;
    setBusy(true);
    setFailure(null);
    try {
      const outcome = await signUp(email, password, name);
      if (outcome.needsEmailConfirmation) {
        void navigate('/verify-email', { replace: true, state: { email: outcome.email } });
      }
      // Otherwise a session exists and the auth listener opens the app.
    } catch (error) {
      setFailure(errorMessage(error));
      setBusy(false);
    }
  };

  return (
    <AuthLayout back="/login" title="Register new user" subtitle="Track spending, set budgets and stay on top of your money.">
      <form className={styles.form} onSubmit={(e) => void submit(e)} noValidate>
        <TextField
          value={name}
          onChange={setName}
          placeholder="Full name"
          aria-label="Full name"
          icon="person"
          autoComplete="name"
          autoCapitalize="words"
          enterKeyHint="next"
          disabled={busy}
          error={errors.name}
        />
        <TextField
          type="email"
          value={email}
          onChange={setEmail}
          placeholder="Email"
          aria-label="Email"
          icon="email"
          autoComplete="email"
          inputMode="email"
          autoCapitalize="none"
          autoCorrect="off"
          spellCheck={false}
          enterKeyHint="next"
          disabled={busy}
          error={errors.email}
        />
        <PasswordField value={password} onChange={setPassword} label="Password" autoComplete="new-password" disabled={busy} error={errors.password} />
        <p className="t-label-sm" style={{ marginTop: -4, paddingLeft: 4 }}>
          {PASSWORD_HINT}
        </p>
        <PasswordField
          value={confirm}
          onChange={setConfirm}
          label="Confirm password"
          autoComplete="new-password"
          disabled={busy}
          error={errors.confirm}
          onEnter={() => void submit()}
        />
        {failure ? <InlineError message={failure} /> : null}
        <Button type="submit" label="Create account" busy={busy} busyLabel="Creating…" size="lg" block />
      </form>
      <p className={styles.fine}>By continuing you agree to keep your financial data on your own Supabase project.</p>
    </AuthLayout>
  );
}
