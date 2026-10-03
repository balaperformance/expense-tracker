/**
 * One notification, every device: a user may have browsers (Web Push) and
 * phones (Firebase Cloud Messaging). The event is claimed once (run.ts) and
 * then handed to each channel; their results add up, so it counts as sent
 * when any device took it and is retried only when none could.
 */
import type { PushMessage, PushSender, SendResult } from './run.ts';

export class ChannelSender implements PushSender {
  constructor(private readonly channels: readonly PushSender[]) {}

  async send(userId: string, message: PushMessage): Promise<SendResult> {
    const total: SendResult = { delivered: 0, removed: 0, retryable: 0 };
    for (const channel of this.channels) {
      try {
        const result = await channel.send(userId, message);
        total.delivered += result.delivered;
        total.removed += result.removed;
        total.retryable += result.retryable;
      } catch (error) {
        // One channel's trouble (its database read, its credentials) must not
        // stop the other; counted as a failure that may pass.
        total.retryable += 1;
        console.error('push-notify: a channel failed:', error instanceof Error ? error.message : 'unknown error');
      }
    }
    return total;
  }
}
