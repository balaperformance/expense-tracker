import { useState } from 'react';
import { Navigate, useLocation, useNavigate } from 'react-router';

import { Button } from '@/components/ui/Button';
import { InlineError } from '@/components/ui/Feedback';
import { Icon } from '@/components/ui/Icon';
import { errorMessage } from '@/lib/errors';
import { resendConfirmation } from '@/services/auth';
import { useFeedback } from '@/state/feedback';

import styles from './Auth.module.css';
import { AuthLayout } from './AuthLayout';

export function VerifyEmailPage() {
  const location = useLocation();
  const navigate = useNavigate();
  const { toast } = useFeedback();
  const email = (location.state as { email?: string } | null)?.email;
  const [busy, setBusy] = useState(false);
  const [failure, setFailure] = useState<string | null>(null);

  if (!email) return <Navigate to="/login" replace />;

  const resend = async () => {
    setBusy(true);
    setFailure(null);
    try {
      await resendConfirmation(email);
      toast('success', 'Verification email sent.');
    } catch (error) {
      setFailure(errorMessage(error));
    } finally {
      setBusy(false);
    }
  };

  return (
    <AuthLayout
      back="/login"
      icon="mailUnread"
      title="Confirm your email"
      subtitle={`We sent a verification link to ${email}. Open it, then come back and sign in.`}
    >
      <div className={styles.tip}>
        <Icon name="lightbulb" size={18} />
        <span>Not seeing it? Check your spam folder, or resend the link below.</span>
      </div>
      {failure ? <InlineError message={failure} /> : null}
      <Button label="Back to sign in" size="lg" block onClick={() => void navigate('/login', { replace: true })} />
      <Button label="Resend email" variant="secondary" size="lg" block busy={busy} busyLabel="Sending…" onClick={() => void resend()} />
    </AuthLayout>
  );
}
