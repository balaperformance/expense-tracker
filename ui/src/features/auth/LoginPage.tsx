import { useState, type SyntheticEvent } from 'react';
import { useNavigate } from 'react-router';

import { Button } from '@/components/ui/Button';
import { InlineError } from '@/components/ui/Feedback';
import { PasswordField, TextField } from '@/components/ui/Fields';
import { errorMessage } from '@/lib/errors';
import { validateEmail, validatePassword } from '@/lib/validators';
import { signIn } from '@/services/auth';

import styles from './Auth.module.css';
import { AuthLayout } from './AuthLayout';

export function LoginPage() {
  const navigate = useNavigate();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [errors, setErrors] = useState<{ email?: string | null; password?: string | null }>({});
  const [failure, setFailure] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const submit = async (event?: SyntheticEvent) => {
    event?.preventDefault();
    if (busy) return;
    const next = { email: validateEmail(email), password: validatePassword(password) };
    setErrors(next);
    if (next.email || next.password) return;
    setBusy(true);
    setFailure(null);
    try {
      await signIn(email, password);
      // The auth listener moves the app on; nothing else to do here.
    } catch (error) {
      setFailure(errorMessage(error));
      setBusy(false);
    }
  };

  return (
    <AuthLayout title="Welcome back" subtitle="Sign in to pick up where you left off.">
      <form className={styles.form} onSubmit={(e) => void submit(e)} noValidate>
        <TextField
          type="email"
          value={email}
          onChange={setEmail}
          placeholder="Email"
          aria-label="Email"
          icon="email"
          autoComplete="username"
          inputMode="email"
          autoCapitalize="none"
          autoCorrect="off"
          spellCheck={false}
          enterKeyHint="next"
          disabled={busy}
          error={errors.email}
        />
        <PasswordField
          value={password}
          onChange={setPassword}
          label="Password"
          autoComplete="current-password"
          disabled={busy}
          error={errors.password}
          onEnter={() => void submit()}
        />
        {failure ? <InlineError message={failure} /> : null}
        <Button type="submit" label="Sign in" busy={busy} busyLabel="Signing in…" size="lg" block />
      </form>
      <Button label="Register New User" variant="secondary" size="lg" block disabled={busy} onClick={() => void navigate('/register')} />
      <p className={styles.fine}>
        Forgotten your password? It can only be changed from Settings while signed in — ask whoever administers this
        app to reset it for you.
      </p>
    </AuthLayout>
  );
}
