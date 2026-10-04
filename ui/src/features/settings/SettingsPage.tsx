import { useState, type ReactNode } from 'react';
import { useNavigate } from 'react-router';

import { Page } from '@/components/layout/Page';
import { Button } from '@/components/ui/Button';
import { ChoiceSheet } from '@/components/ui/ChoiceSheet';
import { Segmented } from '@/components/ui/Chip';
import { Badge, InlineError, Notice } from '@/components/ui/Feedback';
import { TextField } from '@/components/ui/Fields';
import { Icon, type IconName } from '@/components/ui/Icon';
import { Dialog } from '@/components/ui/Sheet';
import { Card, CardList, IconWell, ListRow, SectionHeader } from '@/components/ui/Surface';
import { APP_NAME, APP_VERSION } from '@/domain/defaults';
import { profileInitial } from '@/domain/models';
import { useInstallPrompt } from '@/hooks/useInstallPrompt';
import { errorMessage } from '@/lib/errors';
import { SUPPORTED_CURRENCIES } from '@/lib/format';
import { signOut } from '@/services/auth';
import { useAuth } from '@/state/auth';
import { useFeedback } from '@/state/feedback';
import { useSettings, type PalettePreference, type ThemePreference } from '@/state/settings';

import { ChangePasswordSheet } from './ChangePasswordSheet';
import { NotificationsSection } from './NotificationsSection';
import styles from './Settings.module.css';

type Overlay = 'name' | 'currency' | 'password' | 'about' | 'install' | null;

export function SettingsPage() {
  const navigate = useNavigate();
  const settings = useSettings();
  const { email } = useAuth();
  const { toast, confirm } = useFeedback();
  const install = useInstallPrompt();
  const [overlay, setOverlay] = useState<Overlay>(null);
  const [passwordKey, setPasswordKey] = useState(0);
  const [name, setName] = useState('');
  const [nameError, setNameError] = useState<string | null>(null);
  const [savingName, setSavingName] = useState(false);

  const row = (icon: IconName, title: string, subtitle: string, onClick: () => void, options?: { trailing?: ReactNode; destructive?: boolean }) => (
    <ListRow
      leading={<IconWell icon={icon} size={30} tone={options?.destructive ? 'var(--error)' : 'var(--primary)'} />}
      title={title}
      subtitle={subtitle}
      tone={options?.destructive ? 'var(--error)' : undefined}
      trailing={options?.trailing}
      chevron={!options?.trailing}
      onClick={onClick}
    />
  );

  const saveName = async () => {
    if (!name.trim()) {
      setOverlay(null);
      return;
    }
    setSavingName(true);
    setNameError(null);
    try {
      await settings.updateName(name);
      toast('success', 'Name updated');
      setOverlay(null);
    } catch (error) {
      setNameError(errorMessage(error, 'Could not update your name.'));
    } finally {
      setSavingName(false);
    }
  };

  const chooseCurrency = async (code: string) => {
    setOverlay(null);
    try {
      await settings.updateCurrency(code);
    } catch (error) {
      toast('error', errorMessage(error, 'Could not change the currency.'));
    }
  };

  const confirmSignOut = async () => {
    const ok = await confirm({
      title: 'Sign out?',
      message: 'You will need your email and password to sign back in.',
      confirmLabel: 'Sign out',
      destructive: false,
    });
    if (!ok) return;
    try {
      await signOut();
    } catch (error) {
      toast('error', errorMessage(error));
    }
  };

  return (
    <Page title="Settings">
      <Card
        radius="xl"
        padding="roomy"
        onClick={() => {
          setName(settings.profile?.fullName ?? '');
          setNameError(null);
          setOverlay('name');
        }}
        ariaLabel="Edit your name"
      >
        <div className={styles.profile}>
          <span className={styles.avatar}>
            <span>{profileInitial(settings.profile)}</span>
          </span>
          <span className="grow stack gap-xs" style={{ minWidth: 0 }}>
            <span className="t-headline-sm t-ellipsis">{settings.profile?.fullName ?? 'Add your name'}</span>
            <span className="t-body-sm t-ellipsis">{email ?? 'Signed in'}</span>
          </span>
          <span className={styles.editBadge}>
            <Icon name="edit" size={16} />
          </span>
        </div>
      </Card>

      <div className={styles.columns}>
        <div className="stack gap-section">
          {email ? (
            <div>
              <SectionHeader title="Security" />
              <CardList indent={54}>
                {row('password', 'Change password', 'Confirm your current password, then set a new one', () => {
                  setPasswordKey((k) => k + 1);
                  setOverlay('password');
                })}
              </CardList>
            </div>
          ) : null}

          <div>
            <SectionHeader title="Assistant" />
            <CardList indent={54}>
              {row('assistant', 'Ask the assistant', 'Totals, balances, budgets — or record an entry', () => void navigate('/assistant'))}
            </CardList>
          </div>

          <NotificationsSection />

          <div>
            <SectionHeader title="Money" />
            <CardList indent={54}>
              {row('bank', 'Bank accounts', 'Balances, statements and transfers', () => void navigate('/accounts'))}
              {row('cardSolid', 'Credit cards', 'Outstanding, bills, due dates and statements', () => void navigate('/cards'))}
              {row('budget', 'Budgets', 'Monthly limits', () => void navigate('/budgets'))}
              {row('category', 'Categories', 'Organise your spending', () => void navigate('/categories'))}
              {row('card', 'Payment methods', 'Cash, cards, UPI and more', () => void navigate('/payment-methods'))}
              {row('currency', 'Currency', 'Used for every amount in the app', () => setOverlay('currency'), {
                trailing: <Badge label={`${settings.currency}  ${settings.symbol}`} />,
              })}
            </CardList>
          </div>
        </div>

        <div className="stack gap-section">
          <div>
            <SectionHeader title="Data & Export" />
            <CardList indent={54}>
              {row('export', 'Export a report', 'Statements, expenses, income and summaries', () => void navigate('/export?type=spendingReport'))}
              {row('document', 'Export bank statement', 'One account, with a running balance', () => void navigate('/export?type=bankStatement'))}
              {row('table', 'Export transactions', 'Every expense or income entry as CSV or PDF', () => void navigate('/export?type=expenses'))}
            </CardList>
            <div style={{ marginTop: 'var(--sp-sm)' }}>
              <Notice icon="download" message="Exports are generated on this device and handed straight to the share sheet or a download. Nothing is uploaded." />
            </div>
          </div>

          <div>
            <SectionHeader title="Appearance" />
            <Card>
              <div className="stack gap-md">
                <div className="stack gap-sm">
                  <span className="t-label-md">Palette</span>
                  <Segmented<PalettePreference>
                    label="Palette"
                    value={settings.palette}
                    onChange={settings.setPalette}
                    options={[
                      { value: 'matte', label: 'Matte & Sand' },
                      { value: 'current', label: 'Current' },
                    ]}
                  />
                </div>
                <div className="stack gap-sm">
                  <span className="t-label-md">Mode</span>
                  <Segmented<ThemePreference>
                    label="Mode"
                    value={settings.theme}
                    onChange={settings.setTheme}
                    options={[
                      { value: 'system', label: 'System', icon: 'themeAuto' },
                      { value: 'light', label: 'Light', icon: 'themeLight' },
                      { value: 'dark', label: 'Dark', icon: 'themeDark' },
                    ]}
                  />
                </div>
              </div>
            </Card>
          </div>

          <div>
            <SectionHeader title="About" />
            <CardList indent={54}>
              {install.mode === 'prompt'
                ? row('download', 'Install the app', 'Add Expense Tracker to this device', () => void install.install())
                : install.mode === 'ios'
                  ? row('download', 'Add to Home Screen', 'Use it full-screen, like an app', () => setOverlay('install'))
                  : null}
              {row('info', APP_NAME, `Version ${APP_VERSION}`, () => setOverlay('about'))}
              {row('logout', 'Sign out', 'You will need to sign in again', () => void confirmSignOut(), { destructive: true })}
            </CardList>
          </div>
        </div>
      </div>

      <Dialog
        open={overlay === 'name'}
        onClose={() => setOverlay(null)}
        title="Your name"
        actions={
          <>
            <Button label="Cancel" variant="ghost" onClick={() => setOverlay(null)} />
            <Button label="Save" busy={savingName} onClick={() => void saveName()} />
          </>
        }
      >
        <form
          className="stack gap-sm"
          onSubmit={(e) => {
            e.preventDefault();
            void saveName();
          }}
        >
          <TextField value={name} onChange={setName} placeholder="Full name" aria-label="Full name" autoCapitalize="words" autoComplete="name" autoFocus />
          {nameError ? <InlineError message={nameError} /> : null}
        </form>
      </Dialog>

      <ChoiceSheet
        open={overlay === 'currency'}
        onClose={() => setOverlay(null)}
        title="Currency"
        subtitle="Applies to every amount in the app"
        options={SUPPORTED_CURRENCIES.map(([code, symbol]) => ({ value: code, label: code, detail: symbol }))}
        value={settings.currency}
        onChoose={(code) => void chooseCurrency(code)}
      />

      <ChangePasswordSheet key={passwordKey} open={overlay === 'password'} onClose={() => setOverlay(null)} />

      <Dialog open={overlay === 'about'} onClose={() => setOverlay(null)} title={APP_NAME} actions={<Button label="Close" variant="ghost" onClick={() => setOverlay(null)} />}>
        <p>Version {APP_VERSION}</p>
        <p style={{ marginTop: 8 }}>
          A private expense tracker. Your data lives in your own Supabase project and is protected by row-level security.
        </p>
      </Dialog>

      <Dialog open={overlay === 'install'} onClose={() => setOverlay(null)} title="Add to Home Screen" actions={<Button label="Got it" onClick={() => setOverlay(null)} />}>
        <ol className={styles.steps}>
          <li>
            Tap <strong>Share</strong> <Icon name="export" size={16} style={{ display: 'inline', verticalAlign: '-3px' }} /> in Safari’s toolbar.
          </li>
          <li>
            Choose <strong>Add to Home Screen</strong>.
          </li>
          <li>Open Expense Tracker from your Home Screen — it runs full-screen, like an app.</li>
        </ol>
      </Dialog>
    </Page>
  );
}
