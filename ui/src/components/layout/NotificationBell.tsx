import { useState } from 'react';
import { useNavigate } from 'react-router';

import { Button, IconButton } from '@/components/ui/Button';
import { EmptyState, ErrorView, ListSkeleton } from '@/components/ui/Feedback';
import type { IconName } from '@/components/ui/Icon';
import { Sheet } from '@/components/ui/Sheet';
import { CardList, IconWell } from '@/components/ui/Surface';
import { badgeLabel, isKnownKind, sentLabel, type InboxItem, type KnownKind } from '@/domain/notifications/inbox';
import { useNotificationInbox } from '@/hooks/notificationInbox';

import styles from './Notifications.module.css';

const KIND_STYLE: Record<KnownKind, { icon: IconName; tone: string }> = {
  daily: { icon: 'time', tone: 'var(--primary)' },
  summary: { icon: 'insights', tone: 'var(--accent)' },
  lowBalance: { icon: 'bank', tone: 'var(--warning)' },
  cardDue: { icon: 'card', tone: 'var(--expense)' },
};

const kindStyle = (kind: string) => (isKnownKind(kind) ? KIND_STYLE[kind] : { icon: 'bell' as const, tone: 'var(--muted)' });

/**
 * The header bell: an unread count on the app's glass icon button, and the
 * notification history in the app's sheet. Hidden until migration 010 exists.
 */
export function NotificationBell() {
  const inbox = useNotificationInbox();
  const [open, setOpen] = useState(false);
  const navigate = useNavigate();
  if (!inbox.available) return null;

  const show = () => {
    setOpen(true);
    void inbox.refetch();
  };
  const choose = (item: InboxItem) => {
    if (!item.read) inbox.markRead(item.key);
    if (!item.path) return;
    setOpen(false);
    void navigate(item.path);
  };

  const subtitle = inbox.unread > 0 ? `${inbox.unread} unread` : inbox.items.length ? 'You’re all caught up' : undefined;

  return (
    <>
      <IconButton
        icon="bell"
        label={inbox.unread > 0 ? `Notifications, ${inbox.unread} unread` : 'Notifications'}
        glass
        badge={badgeLabel(inbox.unread)}
        className={styles.bell}
        onClick={show}
      />
      <Sheet
        open={open}
        onClose={() => setOpen(false)}
        title="Notifications"
        subtitle={subtitle}
        action={inbox.unread > 0 ? <Button label="Mark all as read" variant="ghost" size="sm" onClick={inbox.markAllRead} /> : undefined}
      >
        {inbox.isPending ? (
          <ListSkeleton rows={4} />
        ) : inbox.isError && !inbox.items.length ? (
          <ErrorView message="Notifications could not be loaded." onRetry={() => void inbox.refetch()} compact />
        ) : !inbox.items.length ? (
          <EmptyState
            icon="bell"
            title="No notifications yet"
            message="Daily reminders, spending summaries, low balance alerts and card due dates will appear here."
            compact
          />
        ) : (
          <CardList>
            {inbox.items.map((item) => (
              <NotificationRow key={item.key} item={item} onChoose={choose} />
            ))}
          </CardList>
        )}
      </Sheet>
    </>
  );
}

function NotificationRow({ item, onChoose }: { item: InboxItem; onChoose: (item: InboxItem) => void }) {
  const { icon, tone } = kindStyle(item.kind);
  return (
    <button
      type="button"
      className={[styles.item, !item.read && styles.itemUnread].filter(Boolean).join(' ')}
      onClick={() => onChoose(item)}
      aria-label={`${item.read ? '' : 'Unread. '}${item.title}. ${item.body}`}
    >
      <IconWell icon={icon} tone={tone} />
      <span className={styles.text}>
        <span className={styles.head}>
          <span className={styles.title}>{item.title}</span>
          {item.read ? null : <span className={styles.dot} aria-hidden />}
        </span>
        {item.body ? <span className={styles.body}>{item.body}</span> : null}
        <span className={styles.time}>{sentLabel(item.sentAt)}</span>
      </span>
    </button>
  );
}
