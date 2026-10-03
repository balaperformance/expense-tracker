/**
 * Delivers a message to every device a user has subscribed, over Web Push
 * (RFC 8030) signed with the project's VAPID key (RFC 8292). The payload is
 * encrypted for the device by the library; the push service sees none of it.
 *
 * A subscription the push service reports gone (404/410) is switched off at
 * once. Everything else that goes wrong is classified, never thrown, so one
 * dead device cannot stop the others.
 */
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';
import webpush from 'npm:web-push@3.6.7';

import { isGoneStatus, isRetryableStatus } from './core/pushStatus.ts';
import type { PushMessage, PushSender, SendResult } from './core/run.ts';

/** A reminder that arrives hours late is worse than none: let the push service drop it after three. */
const TTL_SECONDS = 3 * 60 * 60;

export type Vapid = { subject: string; publicKey: string; privateKey: string };

/** The status the push service answered with, if the failure came from it. */
function statusOf(error: unknown): number | null {
  const status = (error as { statusCode?: unknown } | null)?.statusCode;
  return typeof status === 'number' ? status : null;
}

export class WebPushSender implements PushSender {
  constructor(
    private readonly client: SupabaseClient,
    vapid: Vapid,
  ) {
    webpush.setVapidDetails(vapid.subject, vapid.publicKey, vapid.privateKey);
  }

  async send(userId: string, message: PushMessage): Promise<SendResult> {
    const { data, error } = await this.client
      .from('push_subscriptions')
      .select('id, endpoint, p256dh, auth')
      .eq('user_id', userId)
      .is('disabled_at', null);
    if (error) throw new Error(`could not read subscriptions (${error.code ?? 'unknown'})`);

    const result: SendResult = { delivered: 0, removed: 0, retryable: 0 };
    const payload = JSON.stringify(message);
    for (const row of (data ?? []) as Record<string, unknown>[]) {
      try {
        await webpush.sendNotification(
          { endpoint: String(row.endpoint), keys: { p256dh: String(row.p256dh), auth: String(row.auth) } },
          payload,
          { TTL: TTL_SECONDS, urgency: 'normal' },
        );
        result.delivered += 1;
      } catch (failure) {
        const status = statusOf(failure);
        if (isGoneStatus(status)) {
          await this.client.from('push_subscriptions').update({ disabled_at: new Date().toISOString() }).eq('id', String(row.id));
          result.removed += 1;
        } else if (isRetryableStatus(status)) {
          result.retryable += 1;
        } else {
          // 400/401/403/413…: this device will not take the message however often it is retried.
          console.error('push-notify: a device rejected a message with status', status);
        }
      }
    }
    return result;
  }
}
