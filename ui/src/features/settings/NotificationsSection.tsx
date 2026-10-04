import type { ReactNode } from 'react';

import { Button } from '@/components/ui/Button';
import { Badge } from '@/components/ui/Feedback';
import type { IconName } from '@/components/ui/Icon';
import { Switch } from '@/components/ui/Switch';
import { CardList, IconWell, ListRow, SectionHeader } from '@/components/ui/Surface';
import { useDevicePush, useNotificationPrefs } from '@/hooks/notifications';
import { errorMessage } from '@/lib/errors';
import { currencySymbol } from '@/lib/format';
import type { NotificationPref } from '@/services/push';
import { useFeedback } from '@/state/feedback';
import { useSettings } from '@/state/settings';

/** The fixed threshold the server watches (supabase/functions/push-notify/core/run.ts LOW_BALANCE_CENTS). */
const LOW_BALANCE_THRESHOLD = 500;

const SWITCHES: ReadonlyArray<{ pref: NotificationPref; icon: IconName; title: string; subtitle: (symbol: string) => string }> = [
  { pref: 'daily', icon: 'time', title: 'Daily expense reminder', subtitle: () => 'Today’s spending, around 10 PM' },
  { pref: 'summary', icon: 'insights', title: 'Spending summary', subtitle: () => 'On the 16th and the last day of the month' },
  { pref: 'lowBalance', icon: 'bank', title: 'Low bank balance', subtitle: (symbol) => `When an account is below ${symbol}${LOW_BALANCE_THRESHOLD}` },
  { pref: 'cardDue', icon: 'cardSolid', title: 'Credit card due reminder', subtitle: () => 'The day before a bill is due' },
];

/**
 * Push notifications: whether this device receives them, and the four
 * on/off switches. Nothing else is configurable — the times, the threshold
 * and the days are fixed. Hidden until migration 008 exists.
 */
export function NotificationsSection() {
  const { available, prefs, isPending, set } = useNotificationPrefs();
  const device = useDevicePush();
  const { toast } = useFeedback();
  const { currency } = useSettings();

  if (!available) return null;

  const turnOn = async () => {
    try {
      const result = await device.enable();
      if (result === 'enabled') toast('success', 'Notifications are on for this device');
      else if (result === 'denied') toast('error', 'Notifications are blocked. Allow them for this site in your browser settings.');
      else if (result === 'unavailable') toast('error', 'Notifications are not available in this build of the app.');
    } catch (error) {
      toast('error', errorMessage(error, 'Could not turn on notifications.'));
    }
  };

  const turnOff = async () => {
    try {
      await device.disable();
      toast('success', 'Notifications are off for this device');
    } catch (error) {
      toast('error', errorMessage(error, 'Could not turn off notifications.'));
    }
  };

  const change = async (pref: NotificationPref, value: boolean) => {
    try {
      await set({ pref, value });
    } catch (error) {
      toast('error', errorMessage(error, 'Could not save that setting.'));
    }
  };

  const deviceRow = (title: string, subtitle: string, trailing?: ReactNode) => (
    <ListRow leading={<IconWell icon="bell" size={30} tone="var(--primary)" />} title={title} subtitle={subtitle} trailing={trailing} />
  );

  let status: ReactNode;
  if (device.support === 'unsupported') {
    status = deviceRow('Not available here', 'This browser can’t receive notifications. On iPhone or iPad, add Expense Tracker to your Home Screen first.');
  } else if (device.support === 'notConfigured') {
    status = deviceRow('Not set up yet', 'This build of the app has no push key yet');
  } else if (device.permission === 'denied') {
    status = deviceRow('Blocked in this browser', 'Allow notifications for this site in your browser settings, then come back.');
  } else if (device.subscribed && device.permission === 'granted') {
    status = deviceRow(
      'Notifications on this device',
      'Sent by the server, even when the app is closed',
      <>
        <Badge label="On" />
        <Button label="Turn off" variant="ghost" size="sm" busy={device.busy} onClick={() => void turnOff()} />
      </>,
    );
  } else {
    status = deviceRow(
      'Turn on notifications',
      'Reminders and updates on this device',
      <Button label="Turn on" size="sm" busy={device.busy} onClick={() => void turnOn()} />,
    );
  }

  return (
    <div>
      <SectionHeader title="Notifications" />
      <CardList indent={54}>
        {status}
        {SWITCHES.map(({ pref, icon, title, subtitle }) => (
          <ListRow
            key={pref}
            leading={<IconWell icon={icon} size={30} tone="var(--primary)" />}
            title={title}
            subtitle={subtitle(currencySymbol(currency))}
            trailing={<Switch checked={prefs[pref]} onChange={(value) => void change(pref, value)} label={title} disabled={isPending} />}
          />
        ))}
      </CardList>
    </div>
  );
}
