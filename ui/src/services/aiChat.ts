/**
 * The app's entire knowledge of the AI: one authenticated Edge Function.
 * Port of `services/ai/ai_chat_service.dart`.
 *
 * There is no Gemini or Groq code, key, model name or endpoint anywhere in
 * the web app. The request carries the user's own session token (added by
 * the Supabase client); the function verifies it and runs every tool as that
 * user under RLS.
 */
import { FunctionsFetchError, FunctionsHttpError, FunctionsRelayError } from '@supabase/supabase-js';

import { today as todayIso } from '@/lib/dates';
import { getSupabase } from '@/lib/supabase';
import {
  AiChatError,
  MAX_MERCHANT_CHARS,
  parseReply,
  pendingActionToJson,
  type AiChatReply,
  type ChatRole,
  type PendingAction,
} from '@/domain/aiChat';

const FUNCTION_NAME = 'ai-chat';
/** A little over the server's own 60 s budget, so a slow answer is the server's to report. */
const CHAT_TIMEOUT_MS = 75_000;
/** Shorter: this runs while the user waits on an SMS parse. */
const CLASSIFY_TIMEOUT_MS = 20_000;

/** Only the calendar date is sent — "this month" is decided in the user's own time zone. */
const clientContext = () => ({ today: todayIso() });

async function hasSession(): Promise<boolean> {
  const { data } = await getSupabase().auth.getSession();
  return data.session != null;
}

async function readErrorBody(error: FunctionsHttpError): Promise<{ status: number; body: Record<string, unknown>; retryAfter: number | null }> {
  const response = error.context as Response | undefined;
  const status = response?.status ?? 0;
  let body: Record<string, unknown> = {};
  try {
    const parsed: unknown = await response?.clone().json();
    if (typeof parsed === 'object' && parsed !== null) body = parsed as Record<string, unknown>;
  } catch {
    // Not JSON: a gateway error, handled by status alone.
  }
  const header = Number(response?.headers.get('retry-after'));
  const retryAfter = Number.isFinite(header) && header > 0 ? header : typeof body.retry_after === 'number' ? body.retry_after : null;
  return { status, body, retryAfter };
}

/**
 * Turns an HTTP failure into something the user can read. The function
 * writes its `message` for people and never puts internals in it, so that
 * text is trusted for the statuses it owns.
 */
async function mapError(error: unknown): Promise<AiChatError> {
  if (error instanceof AiChatError) return error;
  if (error instanceof FunctionsHttpError) {
    const { status, body, retryAfter } = await readErrorBody(error);
    const serverMessage = typeof body.message === 'string' ? body.message : null;
    switch (status) {
      case 401:
        return new AiChatError('unauthenticated', 'Your session has expired. Please sign in again.');
      case 413:
        return new AiChatError('tooLong', serverMessage ?? 'That message is too long. Try asking in fewer words.');
      case 422:
        return new AiChatError('rejected', serverMessage ?? 'That could not be done. Please ask again.');
      case 429:
        return new AiChatError('rateLimited', serverMessage ?? 'You are sending messages quickly. Give it a moment.', retryAfter);
      case 503:
        return body.error === 'not_configured'
          ? new AiChatError('notConfigured', serverMessage ?? 'The assistant is not set up yet.')
          : new AiChatError('unavailable', serverMessage ?? 'The assistant is busy right now. Please try again in a moment.');
      case 400:
        return new AiChatError('rejected', serverMessage ?? 'That request could not be understood.');
      default:
        return new AiChatError('unknown', 'Something went wrong. Please try again.');
    }
  }
  if (error instanceof DOMException && (error.name === 'AbortError' || error.name === 'TimeoutError')) {
    return new AiChatError('unavailable', 'The assistant took too long to answer. Please try again.');
  }
  if (error instanceof FunctionsFetchError || error instanceof FunctionsRelayError || !navigator.onLine) {
    return new AiChatError('network', 'No internet connection. Check your network and try again.');
  }
  return new AiChatError('unknown', 'Something went wrong. Please try again.');
}

async function invoke(body: Record<string, unknown>, timeoutMs: number): Promise<unknown> {
  const controller = new AbortController();
  const timer = setTimeout(() => {
    controller.abort(new DOMException('The assistant took too long to answer.', 'TimeoutError'));
  }, timeoutMs);
  try {
    const result = await getSupabase().functions.invoke<unknown>(FUNCTION_NAME, { body, signal: controller.signal });
    const failure: unknown = result.error;
    if (failure instanceof Error) throw failure;
    if (failure) throw new Error('The assistant request failed.');
    return result.data;
  } catch (error) {
    if (controller.signal.aborted) {
      throw new AiChatError('unavailable', 'The assistant took too long to answer. Please try again.');
    }
    throw error;
  } finally {
    clearTimeout(timer);
  }
}

async function call(body: Record<string, unknown>): Promise<AiChatReply> {
  if (!(await hasSession())) {
    throw new AiChatError('unauthenticated', 'You are signed out. Sign in again to use the assistant.');
  }
  try {
    return parseReply(await invoke(body, CHAT_TIMEOUT_MS));
  } catch (error) {
    throw await mapError(error);
  }
}

export function sendChat(message: string, history: { role: ChatRole; content: string }[]): Promise<AiChatReply> {
  return call({ action: 'chat', message, history, client_context: clientContext() });
}

/** Executes a write the server prepared and the user approved; the server re-checks everything. */
export function confirmAction(action: PendingAction): Promise<AiChatReply> {
  return call({ action: 'confirm', pending_action: pendingActionToJson(action), client_context: clientContext() });
}

/**
 * A category name for one merchant (bank-SMS import). Only the payee is sent —
 * never the message, amount, account or reference. Never throws: a failed
 * suggestion simply means none.
 */
export async function suggestCategory(merchant: string): Promise<string | null> {
  const payee = merchant.trim();
  if (!payee || !(await hasSession())) return null;
  try {
    const data = await invoke({ action: 'classify', merchant: payee.slice(0, MAX_MERCHANT_CHARS) }, CLASSIFY_TIMEOUT_MS);
    if (typeof data !== 'object' || data === null) return null;
    const category = (data as { category?: unknown }).category;
    return typeof category === 'string' && category.trim() ? category.trim() : null;
  } catch {
    return null;
  }
}
