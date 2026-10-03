/**
 * Firebase Cloud Messaging (HTTP v1) — how the phone app receives the same
 * notifications browsers get over Web Push.
 *
 * Plain TypeScript over `fetch` and WebCrypto, both of which Deno and the test
 * runner provide, so everything here is unit-tested without a network: the
 * service-account login (an RS256-signed assertion exchanged for an access
 * token), the message, and what each failure means for the token.
 *
 * The message is data-only. The app draws the notification itself, so a phone
 * shows it only while the account it was sent to is the one signed in there
 * (the `audience` field) — a phone that signed out, or changed hands while
 * offline, stays quiet.
 */
import type { PushMessage, PushSender, SendResult } from './run.ts';

/** The fields of a Firebase service-account key the sender needs. */
export type ServiceAccount = { projectId: string; clientEmail: string; privateKey: string };

const TOKEN_URL = 'https://oauth2.googleapis.com/token';
const SCOPE = 'https://www.googleapis.com/auth/firebase.messaging';
/** A reminder that arrives hours late is worse than none (the Web Push sender uses the same). */
export const FCM_TTL_SECONDS = 3 * 60 * 60;

/**
 * The key file Firebase hands out (Project settings → Service accounts →
 * Generate new private key), as stored in the FCM_SERVICE_ACCOUNT secret.
 * Null when it is not one.
 */
export function parseServiceAccount(json: string): ServiceAccount | null {
  try {
    const parsed = JSON.parse(json) as Record<string, unknown>;
    const projectId = parsed.project_id;
    const clientEmail = parsed.client_email;
    const privateKey = parsed.private_key;
    if (typeof projectId !== 'string' || typeof clientEmail !== 'string' || typeof privateKey !== 'string') return null;
    if (!projectId || !clientEmail.includes('@') || !privateKey.includes('PRIVATE KEY')) return null;
    return { projectId, clientEmail, privateKey };
  } catch {
    return null;
  }
}

const base64Url = (bytes: Uint8Array): string => {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
};

const utf8 = (text: string): Uint8Array<ArrayBuffer> => new TextEncoder().encode(text);

/** The DER bytes of a PEM-encoded PKCS #8 private key. */
function pemToDer(pem: string): Uint8Array<ArrayBuffer> {
  const body = pem
    .replace(/-----BEGIN [A-Z ]+-----/, '')
    .replace(/-----END [A-Z ]+-----/, '')
    .replace(/\\n/g, '')
    .replace(/\s+/g, '');
  const binary = atob(body);
  const der = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) der[i] = binary.charCodeAt(i);
  return der;
}

/** The signed assertion Google's token endpoint accepts for a service account (RFC 7523). */
export async function serviceAccountAssertion(account: ServiceAccount, now: Date): Promise<string> {
  const iat = Math.floor(now.getTime() / 1000);
  const header = base64Url(utf8(JSON.stringify({ alg: 'RS256', typ: 'JWT' })));
  const claims = base64Url(utf8(JSON.stringify({ iss: account.clientEmail, scope: SCOPE, aud: TOKEN_URL, iat, exp: iat + 3600 })));
  const key = await crypto.subtle.importKey('pkcs8', pemToDer(account.privateKey), { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']);
  const signature = new Uint8Array(await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, utf8(`${header}.${claims}`)));
  return `${header}.${claims}.${base64Url(signature)}`;
}

/**
 * Who a message is for, as the phone checks it: the first 32 hex digits of
 * SHA-256(user id). The phone stores the signed-in user's id and compares;
 * the id itself never travels in the message.
 */
export async function audienceOf(userId: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', utf8(userId)));
  return [...digest].map((b) => b.toString(16).padStart(2, '0')).join('').slice(0, 32);
}

/**
 * One FCM v1 message: data only (every value a string, as FCM requires),
 * high priority so a sleeping phone wakes for it, and collapsed per tag so an
 * offline phone gets only the latest of each.
 */
export function fcmMessage(token: string, message: PushMessage, audience: string): Record<string, unknown> {
  return {
    message: {
      token,
      data: { title: message.title, body: message.body, path: message.url, tag: message.tag, audience },
      android: { priority: 'HIGH', ttl: `${FCM_TTL_SECONDS}s`, collapse_key: message.tag },
    },
  };
}

export type FcmFailure = 'gone' | 'retry' | 'reject';

/**
 * What a refused send means for the token (FCM v1 error codes):
 *   gone    UNREGISTERED (404), SENDER_ID_MISMATCH (403), an invalid token
 *           (400 naming the registration token) — it will never work again
 *   retry   no answer, throttling (429) or a server error (5xx)
 *   reject  anything else — this message or our credentials, not the device
 */
export function classifyFcmFailure(status: number | null, body: unknown): FcmFailure {
  if (status == null || status === 429 || status >= 500) return 'retry';
  const error = (body as { error?: { message?: unknown; details?: unknown } } | null)?.error;
  const details = Array.isArray(error?.details) ? (error.details as Record<string, unknown>[]) : [];
  const codes = details.map((d) => d.errorCode).filter((c): c is string => typeof c === 'string');
  const text = typeof error?.message === 'string' ? error.message.toLowerCase() : '';
  if (status === 404 || codes.includes('UNREGISTERED')) return 'gone';
  if (status === 403 && codes.includes('SENDER_ID_MISMATCH')) return 'gone';
  if (status === 400 && (text.includes('registration token') || text.includes('not a valid fcm'))) return 'gone';
  return 'reject';
}

type Fetch = (input: string, init: RequestInit) => Promise<Response>;

/** Logs in as the service account and sends messages; one access token serves a whole run. */
export class FcmClient {
  private accessToken: { value: string; expiresAt: number } | null = null;

  constructor(
    private readonly account: ServiceAccount,
    private readonly fetcher: Fetch = (input, init) => fetch(input, init),
    private readonly clock: () => Date = () => new Date(),
  ) {}

  private async token(): Promise<string> {
    const now = this.clock();
    if (this.accessToken && this.accessToken.expiresAt - 60_000 > now.getTime()) return this.accessToken.value;
    const assertion = await serviceAccountAssertion(this.account, now);
    const response = await this.fetcher(TOKEN_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion }).toString(),
    });
    const body = (await response.json().catch(() => null)) as { access_token?: unknown; expires_in?: unknown } | null;
    if (!response.ok || typeof body?.access_token !== 'string') {
      throw new Error(`the Firebase service account could not sign in (${response.status})`);
    }
    const lifetime = typeof body.expires_in === 'number' ? body.expires_in : 3600;
    this.accessToken = { value: body.access_token, expiresAt: now.getTime() + lifetime * 1000 };
    return body.access_token;
  }

  /** Sends one message; resolves to null when FCM accepted it, else how it failed. */
  async send(token: string, message: PushMessage, audience: string): Promise<FcmFailure | null> {
    let access: string;
    try {
      access = await this.token();
    } catch (error) {
      // A credentials problem is ours, not the device's: never disable a token for it.
      console.error('push-notify:', error instanceof Error ? error.message : 'FCM sign-in failed');
      return 'reject';
    }
    let response: Response;
    try {
      response = await this.fetcher(`https://fcm.googleapis.com/v1/projects/${encodeURIComponent(this.account.projectId)}/messages:send`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${access}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(fcmMessage(token, message, audience)),
      });
    } catch {
      return 'retry';
    }
    if (response.ok) return null;
    if (response.status === 401) this.accessToken = null;
    return classifyFcmFailure(response.status, await response.json().catch(() => null));
  }
}

/** The phone tokens of one user, and switching off one that is gone. */
export interface MobileTokenStore {
  activeTokens(userId: string): Promise<{ id: string; token: string }[]>;
  disableToken(id: string): Promise<void>;
}

/** Delivers a message to every phone a user has registered. */
export class FcmPushSender implements PushSender {
  constructor(
    private readonly client: Pick<FcmClient, 'send'>,
    private readonly tokens: MobileTokenStore,
  ) {}

  async send(userId: string, message: PushMessage): Promise<SendResult> {
    const result: SendResult = { delivered: 0, removed: 0, retryable: 0 };
    const devices = await this.tokens.activeTokens(userId);
    if (!devices.length) return result;
    const audience = await audienceOf(userId);
    for (const device of devices) {
      const failure = await this.client.send(device.token, message, audience);
      if (failure == null) result.delivered += 1;
      else if (failure === 'gone') {
        await this.tokens.disableToken(device.id);
        result.removed += 1;
      } else if (failure === 'retry') result.retryable += 1;
    }
    return result;
  }
}
