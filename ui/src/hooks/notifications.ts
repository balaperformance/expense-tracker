/**
 * What the Settings page needs to run the notification switches: the four
 * saved preferences (account-wide) and the state of this device (permission
 * and subscription).
 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useCallback, useState } from 'react';

import {
  currentSubscription,
  DEFAULT_NOTIFICATION_PREFS,
  disablePush,
  enablePush,
  fetchNotificationPrefs,
  notificationPermission,
  pushSupport,
  saveNotificationPref,
  type EnableResult,
  type NotificationPref,
  type NotificationPrefs,
  type PermissionState,
  type PushSupport,
} from '@/services/push';
import { useUserId } from '@/state/auth';
import { keys } from '@/state/queryClient';

import { useCapabilities } from './data';

export function useNotificationPrefs() {
  const userId = useUserId();
  const enabled = useCapabilities().notifications;
  const client = useQueryClient();
  const queryKey = keys.notificationPrefs(userId);

  const query = useQuery({ queryKey, queryFn: () => fetchNotificationPrefs(userId), enabled });

  const save = useMutation({
    mutationFn: ({ pref, value }: { pref: NotificationPref; value: boolean }) => saveNotificationPref(userId, pref, value),
    // The switch moves at once and goes back if the save fails.
    onMutate: async ({ pref, value }) => {
      await client.cancelQueries({ queryKey });
      const before = client.getQueryData<NotificationPrefs>(queryKey);
      client.setQueryData<NotificationPrefs>(queryKey, { ...(before ?? DEFAULT_NOTIFICATION_PREFS), [pref]: value });
      return { before };
    },
    onError: (_error, _vars, context) => {
      if (context?.before) client.setQueryData(queryKey, context.before);
    },
    onSettled: () => client.invalidateQueries({ queryKey }),
  });

  return {
    available: enabled,
    prefs: query.data ?? DEFAULT_NOTIFICATION_PREFS,
    isPending: enabled && query.isPending,
    set: save.mutateAsync,
  };
}

export type DevicePush = {
  support: PushSupport;
  permission: PermissionState;
  /** This device has a live subscription, so it will receive what the server sends. */
  subscribed: boolean;
  busy: boolean;
  enable: () => Promise<EnableResult>;
  disable: () => Promise<void>;
};

/** Push state of this browser. Reading it never prompts; only [enable] can. */
export function useDevicePush(): DevicePush {
  const support = pushSupport();
  const [busy, setBusy] = useState(false);

  // What the browser says right now. Reading it never prompts; it is read again when the window regains focus,
  // so a change made in the browser's own settings shows up.
  const device = useQuery({
    queryKey: ['devicePush'],
    queryFn: async () => ({ permission: notificationPermission(), subscribed: (await currentSubscription().catch(() => null)) != null }),
    enabled: support !== 'unsupported',
    staleTime: 0,
  });
  const { refetch } = device;

  const enable = useCallback(async () => {
    setBusy(true);
    try {
      return await enablePush();
    } finally {
      await refetch();
      setBusy(false);
    }
  }, [refetch]);

  const disable = useCallback(async () => {
    setBusy(true);
    try {
      await disablePush();
    } finally {
      await refetch();
      setBusy(false);
    }
  }, [refetch]);

  return {
    support,
    permission: device.data?.permission ?? notificationPermission(),
    subscribed: device.data?.subscribed ?? false,
    busy,
    enable,
    disable,
  };
}
