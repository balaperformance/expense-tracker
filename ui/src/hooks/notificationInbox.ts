/**
 * The header bell's data: the in-app notification history, its unread count,
 * and marking items read. Available once migration 010 is in the database.
 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useEffect } from 'react';

import { unreadCount, withRead, type InboxItem } from '@/domain/notifications/inbox';
import { fetchInbox, markAllInboxRead, markInboxRead } from '@/services/notificationInbox';
import { useUserId } from '@/state/auth';
import { keys } from '@/state/queryClient';

import { useCapabilities } from './data';

/** Notifications are written by the server on a 15-minute schedule; a few minutes' lag is plenty fresh. */
const REFRESH_MS = 5 * 60_000;

/** Posted by public/push-sw.js when a push arrives while the app is open. */
export const PUSH_RECEIVED_MESSAGE = 'push-received';

export function useNotificationInbox() {
  const userId = useUserId();
  const available = useCapabilities().notificationInbox;
  const client = useQueryClient();
  const queryKey = keys.notificationInbox(userId);

  const query = useQuery({ queryKey, queryFn: () => fetchInbox(userId), enabled: available, refetchInterval: REFRESH_MS });

  // A push that lands while the app is open shows in the list at once.
  useEffect(() => {
    if (!available || !('serviceWorker' in navigator)) return;
    const onMessage = (event: MessageEvent) => {
      const data: unknown = event.data;
      if (typeof data === 'object' && data !== null && (data as { type?: unknown }).type === PUSH_RECEIVED_MESSAGE) {
        void client.invalidateQueries({ queryKey: keys.notificationInbox(userId) });
      }
    };
    navigator.serviceWorker.addEventListener('message', onMessage);
    return () => navigator.serviceWorker.removeEventListener('message', onMessage);
  }, [available, client, userId]);

  // Both marks show at once and go back if the save fails.
  const optimistic = async (keysRead?: ReadonlySet<string>) => {
    await client.cancelQueries({ queryKey });
    const before = client.getQueryData<InboxItem[]>(queryKey);
    if (before) client.setQueryData<InboxItem[]>(queryKey, withRead(before, keysRead));
    return { before };
  };
  const rollback = (_error: unknown, _vars: unknown, context?: { before?: InboxItem[] }) => {
    if (context?.before) client.setQueryData(queryKey, context.before);
  };
  const settle = () => client.invalidateQueries({ queryKey });

  const markOne = useMutation({
    mutationFn: (key: string) => markInboxRead(userId, key),
    onMutate: (key) => optimistic(new Set([key])),
    onError: rollback,
    onSettled: settle,
  });
  const markAll = useMutation({
    mutationFn: () => markAllInboxRead(userId),
    onMutate: () => optimistic(),
    onError: rollback,
    onSettled: settle,
  });

  const items = query.data ?? [];
  return {
    available,
    items,
    unread: unreadCount(items),
    isPending: available && query.isPending,
    isError: query.isError,
    refetch: query.refetch,
    markRead: markOne.mutate,
    markAllRead: () => markAll.mutate(),
  };
}
