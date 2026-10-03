/**
 * The phone channel of the push sender (supabase/functions/push-notify/core/fcm.ts):
 * the service-account login, the message the phone receives, and what each
 * FCM answer means for the device. Everything runs offline: the key is
 * generated here, and `fetch` is a stand-in that records every request.
 */
import { describe, expect, it } from 'vitest';

import { ChannelSender } from '../../../supabase/functions/push-notify/core/channels.ts';
import {
  audienceOf,
  classifyFcmFailure,
  FcmClient,
  fcmMessage,
  FcmPushSender,
  parseServiceAccount,
  serviceAccountAssertion,
  type FcmFailure,
  type MobileTokenStore,
  type ServiceAccount,
} from '../../../supabase/functions/push-notify/core/fcm.ts';
import type { PushMessage, PushSender, SendResult } from '../../../supabase/functions/push-notify/core/run.ts';

const message: PushMessage = {
  title: 'Expense Tracker',
  body: "Today's spending: ₹370.50. Don't forget to add any missing expenses.",
  url: '/expenses/new',
  tag: 'daily',
};

/** A throwaway RSA key, PEM-encoded the way a Firebase key file carries it. */
async function testAccount(): Promise<{ account: ServiceAccount; publicKey: CryptoKey }> {
  const pair = await crypto.subtle.generateKey(
    { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
    true,
    ['sign', 'verify'],
  );
  const der = new Uint8Array(await crypto.subtle.exportKey('pkcs8', pair.privateKey));
  let binary = '';
  for (const byte of der) binary += String.fromCharCode(byte);
  const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(binary).replace(/(.{64})/g, '$1\n')}\n-----END PRIVATE KEY-----\n`;
  return {
    account: { projectId: 'expense-tracker-test', clientEmail: 'sender@expense-tracker-test.iam.gserviceaccount.com', privateKey: pem },
    publicKey: pair.publicKey,
  };
}

const fromBase64Url = (text: string) => Uint8Array.from(atob(text.replace(/-/g, '+').replace(/_/g, '/')), (c) => c.charCodeAt(0));

type Call = { url: string; init: RequestInit };

/** A fetch that answers from a script and records each request. */
function scriptedFetch(answer: (url: string, init: RequestInit) => Response | Promise<Response>) {
  const calls: Call[] = [];
  const fetcher = async (url: string, init: RequestInit) => {
    calls.push({ url, init });
    return answer(url, init);
  };
  return { calls, fetcher };
}

const tokenReply = () => Response.json({ access_token: 'access-1', expires_in: 3600, token_type: 'Bearer' });
const fcmError = (status: number, code: string, text = 'Requested entity was not found.') =>
  Response.json(
    { error: { code: status, message: text, status: code, details: [{ '@type': 'type.googleapis.com/google.firebase.fcm.v1.FcmError', errorCode: code }] } },
    { status },
  );

describe('the Firebase service account', () => {
  it('is read from the key file Firebase hands out', () => {
    const json = JSON.stringify({
      type: 'service_account',
      project_id: 'p1',
      client_email: 'x@p1.iam.gserviceaccount.com',
      private_key: '-----BEGIN PRIVATE KEY-----\nMII\n-----END PRIVATE KEY-----\n',
    });
    expect(parseServiceAccount(json)).toEqual({
      projectId: 'p1',
      clientEmail: 'x@p1.iam.gserviceaccount.com',
      privateKey: '-----BEGIN PRIVATE KEY-----\nMII\n-----END PRIVATE KEY-----\n',
    });
  });

  it('is nothing when the secret holds something else', () => {
    expect(parseServiceAccount('not json')).toBeNull();
    expect(parseServiceAccount('{}')).toBeNull();
    expect(parseServiceAccount(JSON.stringify({ project_id: 'p1', client_email: 'x', private_key: 'k' }))).toBeNull();
  });

  it('signs in with an RS256 assertion Google can verify', async () => {
    const { account, publicKey } = await testAccount();
    const assertion = await serviceAccountAssertion(account, new Date('2026-10-03T16:30:00Z'));
    const [header, claims, signature] = assertion.split('.');
    expect(JSON.parse(new TextDecoder().decode(fromBase64Url(header ?? '')))).toEqual({ alg: 'RS256', typ: 'JWT' });
    expect(JSON.parse(new TextDecoder().decode(fromBase64Url(claims ?? '')))).toEqual({
      iss: account.clientEmail,
      scope: 'https://www.googleapis.com/auth/firebase.messaging',
      aud: 'https://oauth2.googleapis.com/token',
      iat: 1791045000,
      exp: 1791048600,
    });
    const valid = await crypto.subtle.verify(
      'RSASSA-PKCS1-v1_5',
      publicKey,
      fromBase64Url(signature ?? ''),
      new TextEncoder().encode(`${header}.${claims}`),
    );
    expect(valid).toBe(true);
  });
});

describe('the message a phone receives', () => {
  it('is data only, wakes the phone, and names no user', async () => {
    const audience = await audienceOf('user-123');
    expect(audience).toMatch(/^[0-9a-f]{32}$/);
    expect(await audienceOf('user-123')).toBe(audience);
    expect(await audienceOf('user-124')).not.toBe(audience);

    const body = fcmMessage('device-token', message, audience);
    expect(body).toEqual({
      message: {
        token: 'device-token',
        data: { title: message.title, body: message.body, path: '/expenses/new', tag: 'daily', audience },
        android: { priority: 'HIGH', ttl: '10800s', collapse_key: 'daily' },
      },
    });
    expect(JSON.stringify(body)).not.toContain('user-123');
  });

  it('carries the audience the phone computes: SHA-256 of the user id', async () => {
    // Pinned so the Android side (PushStore.kt) can be checked against it.
    expect(await audienceOf('abc')).toBe('ba7816bf8f01cfea414140de5dae2223');
  });
});

describe('what FCM’s answer means for the device', () => {
  it.each<[number | null, unknown, FcmFailure]>([
    [404, { error: { details: [{ errorCode: 'UNREGISTERED' }] } }, 'gone'],
    [403, { error: { details: [{ errorCode: 'SENDER_ID_MISMATCH' }] } }, 'gone'],
    [400, { error: { message: 'The registration token is not a valid FCM registration token' } }, 'gone'],
    [400, { error: { message: 'Invalid JSON payload received.' } }, 'reject'],
    [401, null, 'reject'],
    [429, null, 'retry'],
    [503, null, 'retry'],
    [null, null, 'retry'],
  ])('%s → %s', (status, body, expected) => {
    expect(classifyFcmFailure(status, body)).toBe(expected);
  });
});

describe('sending to a phone', () => {
  it('signs in once, then sends with the access token', async () => {
    const { account } = await testAccount();
    const { calls, fetcher } = scriptedFetch((url) => (url.includes('oauth2') ? tokenReply() : Response.json({ name: 'projects/p/messages/1' })));
    const client = new FcmClient(account, fetcher);

    expect(await client.send('t1', message, 'aud')).toBeNull();
    expect(await client.send('t2', message, 'aud')).toBeNull();

    expect(calls.map((c) => c.url)).toEqual([
      'https://oauth2.googleapis.com/token',
      'https://fcm.googleapis.com/v1/projects/expense-tracker-test/messages:send',
      'https://fcm.googleapis.com/v1/projects/expense-tracker-test/messages:send',
    ]);
    expect(calls[0]?.init.body as string).toContain('grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer');
    expect((calls[1]?.init.headers as Record<string, string>).Authorization).toBe('Bearer access-1');
  });

  it('signs in again once the access token is about to expire', async () => {
    const { account } = await testAccount();
    let now = new Date('2026-10-03T16:30:00Z');
    const { calls, fetcher } = scriptedFetch((url) => (url.includes('oauth2') ? tokenReply() : Response.json({})));
    const client = new FcmClient(account, fetcher, () => now);

    await client.send('t1', message, 'aud');
    now = new Date(now.getTime() + 3600_000 - 30_000);
    await client.send('t1', message, 'aud');
    expect(calls.filter((c) => c.url.includes('oauth2'))).toHaveLength(2);
  });

  it('never blames a device for the server’s own credentials', async () => {
    const { account } = await testAccount();
    const { fetcher } = scriptedFetch(() => Response.json({ error: 'invalid_grant' }, { status: 400 }));
    expect(await new FcmClient(account, fetcher).send('t1', message, 'aud')).toBe('reject');
  });

  it('switches off a gone token, retries a passing failure, and keeps a good one', async () => {
    const disabled: string[] = [];
    const tokens: MobileTokenStore = {
      activeTokens: () =>
        Promise.resolve([
          { id: 'd1', token: 'good' },
          { id: 'd2', token: 'gone' },
          { id: 'd3', token: 'busy' },
        ]),
      disableToken: (id) => {
        disabled.push(id);
        return Promise.resolve();
      },
    };
    const { account } = await testAccount();
    const { fetcher } = scriptedFetch((url, init) => {
      if (url.includes('oauth2')) return tokenReply();
      const token = (JSON.parse(init.body as string) as { message: { token: string } }).message.token;
      if (token === 'gone') return fcmError(404, 'UNREGISTERED');
      if (token === 'busy') return fcmError(503, 'UNAVAILABLE');
      return Response.json({});
    });

    const result = await new FcmPushSender(new FcmClient(account, fetcher), tokens).send('user-1', message);
    expect(result).toEqual({ delivered: 1, removed: 1, retryable: 1 });
    expect(disabled).toEqual(['d2']);
  });

  it('does nothing for a user with no phone', async () => {
    const client = { send: () => Promise.reject(new Error('must not be called')) };
    const tokens: MobileTokenStore = { activeTokens: () => Promise.resolve([]), disableToken: () => Promise.resolve() };
    expect(await new FcmPushSender(client, tokens).send('user-1', message)).toEqual({ delivered: 0, removed: 0, retryable: 0 });
  });
});

describe('one notification, every device', () => {
  const channel = (result: SendResult): PushSender => ({ send: () => Promise.resolve(result) });

  it('adds up what each channel did', async () => {
    const sender = new ChannelSender([channel({ delivered: 1, removed: 0, retryable: 0 }), channel({ delivered: 2, removed: 1, retryable: 1 })]);
    expect(await sender.send('u1', message)).toEqual({ delivered: 3, removed: 1, retryable: 1 });
  });

  it('keeps going when one channel fails, and counts that as a failure that may pass', async () => {
    const broken: PushSender = { send: () => Promise.reject(new Error('database down')) };
    const sender = new ChannelSender([broken, channel({ delivered: 1, removed: 0, retryable: 0 })]);
    expect(await sender.send('u1', message)).toEqual({ delivered: 1, removed: 0, retryable: 1 });
  });
});
