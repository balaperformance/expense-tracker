import { useState } from 'react';

import { Button } from '@/components/ui/Button';
import { InlineError } from '@/components/ui/Feedback';
import { PasswordField } from '@/components/ui/Fields';
import { Sheet } from '@/components/ui/Sheet';
import { errorMessage } from '@/lib/errors';
import { PASSWORD_HINT, validateConfirmPassword, validateNewPassword } from '@/lib/validators';
import { changePassword } from '@/services/auth';
import { useAuth } from '@/state/auth';
import { useFeedback } from '@/state/feedback';

/** Confirm the current password, then set a new one — no email step (ChangePasswordSheet). */
export function ChangePasswordSheet({ open, onClose }: { open: boolean; onClose: () => void }) {
  const { toast } = useFeedback();
  const { email } = useAuth();
  const [current, setCurrent] = useState('');
  const [next, setNext] = useState('');
  const [confirmValue, setConfirmValue] = useState('');
  const [errors, setErrors] = useState<Partial<Record<'current' | 'next' | 'confirm', string | null>>>({});
  const [failure, setFailure] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const submit = async () => {
    const found = {
      current: current ? null : 'Enter your current password',
      next: validateNewPassword(next),
      confirm: validateConfirmPassword(confirmValue, next),
    };
    setErrors(found);
    if (found.current || found.next || found.confirm) return;
    setBusy(true);
    setFailure(null);
    try {
      await changePassword(current, next);
      // Nothing sensitive lingers in memory longer than it must.
      setCurrent('');
      setNext('');
      setConfirmValue('');
      toast('success', 'Password updated.');
      onClose();
    } catch (error) {
      setFailure(errorMessage(error));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Sheet
      open={open}
      onClose={onClose}
      busy={busy}
      title="Change password"
      subtitle="Confirm the password you use now, then choose a new one."
      footer={<Button label="Update password" size="lg" block busy={busy} busyLabel="Updating…" onClick={() => void submit()} />}
    >
      <form
        className="stack gap-md"
        onSubmit={(e) => {
          e.preventDefault();
          void submit();
        }}
      >
        {/* A hidden username lets password managers file the new password correctly. */}
        <input type="text" name="username" autoComplete="username" value={email ?? ''} hidden readOnly />
        <PasswordField value={current} onChange={setCurrent} label="Current password" autoComplete="current-password" disabled={busy} error={errors.current} />
        <PasswordField value={next} onChange={setNext} label="New password" autoComplete="new-password" disabled={busy} error={errors.next} />
        <p className="t-label-sm" style={{ marginTop: -4, paddingLeft: 4 }}>
          {PASSWORD_HINT}
        </p>
        <PasswordField
          value={confirmValue}
          onChange={setConfirmValue}
          label="Confirm new password"
          autoComplete="new-password"
          disabled={busy}
          error={errors.confirm}
          onEnter={() => void submit()}
        />
        {failure ? <InlineError message={failure} /> : null}
        <p className="t-label-sm">You will stay signed in on this device. Sign in with the new password everywhere else.</p>
      </form>
    </Sheet>
  );
}
