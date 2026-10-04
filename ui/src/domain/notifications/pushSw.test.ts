/**
 * public/push-sw.js is plain script loaded by the service worker. It is run
 * here against a stand-in `self`, to hold the two behaviours that matter: a
 * push always shows a notification, and a click only ever opens this app.
 */
import { describe, expect, it, vi } from 'vitest';

import source from '../../../public/push-sw.js?raw';

type Listener = (event: unknown) => void;

type FakeWindow = { url: string; navigate?: (url: string) => Promise<void>; focus: () => Promise<void>; postMessage?: (message: unknown) => void };

function loadWorker(windows: FakeWindow[] = [], matchAll: () => Promise<FakeWindow[]> = () => Promise.resolve(windows)) {
  const listeners: Record<string, Listener> = {};
  const showNotification = vi.fn<(title: string, options?: unknown) => Promise<void>>(() => Promise.resolve());
  const openWindow = vi.fn(() => Promise.resolve());
  const self = {
    location: { origin: 'https://app.example' },
    registration: { showNotification },
    clients: { matchAll, openWindow },
    addEventListener: (type: string, listener: Listener) => {
      listeners[type] = listener;
    },
  };
  // The worker is a plain script that reads `self`; running it against a stand-in is the whole point of this test.
  // eslint-disable-next-line @typescript-eslint/no-implied-eval, @typescript-eslint/no-unsafe-call
  new Function('self', source)(self);
  return { listeners, showNotification, openWindow };
}

/** Runs a handler and waits for the promise it hands to waitUntil. */
async function dispatch(listener: Listener | undefined, event: Record<string, unknown>) {
  let pending: Promise<unknown> = Promise.resolve();
  listener?.({ ...event, waitUntil: (promise: Promise<unknown>) => (pending = promise) });
  await pending;
}

const pushEvent = (payload: unknown) => ({ data: { json: () => payload } });

describe('the push handler', () => {
  it('shows what the server sent', async () => {
    const { listeners, showNotification } = loadWorker();
    await dispatch(listeners.push, pushEvent({ title: 'Expense Tracker', body: 'Low balance: HDFC Savings is ₹420.', url: '/accounts/a1', tag: 'low-a1' }));
    expect(showNotification).toHaveBeenCalledWith(
      'Expense Tracker',
      expect.objectContaining({ body: 'Low balance: HDFC Savings is ₹420.', tag: 'low-a1', data: { path: '/accounts/a1' } }),
    );
  });

  it('still shows something when the payload is empty or unreadable', async () => {
    const unreadable: Array<Record<string, unknown>> = [
      { data: null },
      {
        data: {
          json: () => {
            throw new Error('bad');
          },
        },
      },
      pushEvent({}),
    ];
    for (const event of unreadable) {
      const { listeners, showNotification } = loadWorker();
      await dispatch(listeners.push, event);
      expect(showNotification).toHaveBeenCalledTimes(1);
      expect(showNotification.mock.calls[0]?.[0]).toBe('Expense Tracker');
    }
  });

  it('tells an open app window, so its notification bell refreshes', async () => {
    const postMessage = vi.fn();
    const elsewhere = vi.fn();
    const { listeners } = loadWorker([
      { url: 'https://app.example/', focus: vi.fn(), postMessage },
      { url: 'https://other.example/', focus: vi.fn(), postMessage: elsewhere },
    ]);
    await dispatch(listeners.push, pushEvent({ title: 'Expense Tracker', body: 'x' }));
    expect(postMessage).toHaveBeenCalledWith({ type: 'push-received' });
    expect(elsewhere).not.toHaveBeenCalled();
  });

  it('still shows the notification when the open windows cannot be listed', async () => {
    const { listeners, showNotification } = loadWorker([], () => Promise.reject(new Error('no clients')));
    await dispatch(listeners.push, pushEvent({ title: 'Expense Tracker', body: 'x' }));
    expect(showNotification).toHaveBeenCalledTimes(1);
  });

  it('ignores a link that leaves the app', async () => {
    for (const url of ['https://evil.example/x', '//evil.example/x', 'javascript:alert(1)', 42]) {
      const { listeners, showNotification } = loadWorker();
      await dispatch(listeners.push, pushEvent({ title: 'x', url }));
      expect(showNotification).toHaveBeenCalledWith('x', expect.objectContaining({ data: { path: '/' } }));
    }
  });
});

describe('the notification click handler', () => {
  const click = (path: unknown) => ({ notification: { close: vi.fn(), data: { path } } });

  it('opens a new window on the page named, when the app is not open', async () => {
    const { listeners, openWindow } = loadWorker([]);
    const event = click('/reports');
    await dispatch(listeners.notificationclick, event);
    expect(event.notification.close).toHaveBeenCalled();
    expect(openWindow).toHaveBeenCalledWith('https://app.example/reports');
  });

  it('steers and focuses a window that is already open', async () => {
    const navigate = vi.fn(() => Promise.resolve());
    const focus = vi.fn(() => Promise.resolve());
    const { listeners, openWindow } = loadWorker([{ url: 'https://app.example/expenses', navigate, focus }]);
    await dispatch(listeners.notificationclick, click('/cards/c1'));
    expect(navigate).toHaveBeenCalledWith('https://app.example/cards/c1');
    expect(focus).toHaveBeenCalled();
    expect(openWindow).not.toHaveBeenCalled();
  });

  it('never opens anything outside the app', async () => {
    const { listeners, openWindow } = loadWorker([]);
    await dispatch(listeners.notificationclick, click('//evil.example'));
    expect(openWindow).toHaveBeenCalledWith('https://app.example/');
  });
});
