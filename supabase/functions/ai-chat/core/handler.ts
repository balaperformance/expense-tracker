import type { DbPort } from "../db/port.ts";
import {
  type AIProvider,
  ProviderChain,
  ProviderChainError,
  ProviderError,
} from "../providers/provider.ts";
import { accountLabel, type PendingAction, type ToolContext } from "../tools/common.ts";
import { resolveToday } from "../tools/period.ts";
import { executeWrite, WRITE_TOOLS } from "../tools/write_tools.ts";
import { runAgent } from "./agent.ts";
import { CLASSIFY_BUDGET_MS, classifyMerchant, MAX_MERCHANT_CHARS } from "./classify.ts";
import { ChatError, toChatError } from "./errors.ts";
import { LIMITS, RateLimiter } from "./limits.ts";
import type { HistoryTurn } from "./messages.ts";
import { buildSystemPrompt } from "./prompt.ts";

/** An authenticated caller: identity from the token, database as that user. */
export type Session = { userId: string; db: DbPort };

export type HandlerDeps = {
  /**
   * Verifies the Authorization header with the auth server and returns a
   * session, or null when the token is missing, malformed, expired or forged.
   * The user id it returns is the only user id the rest of the request knows.
   */
  openSession(authorizationHeader: string | null): Promise<Session | null>;
  /** Configured providers, primary first. Empty means not configured. */
  providers(): AIProvider[];
  rateLimiter: RateLimiter;
  now?: () => Date;
  /** Operational logging. Receives no message text and no financial data. */
  log?: (event: string, fields?: Record<string, unknown>) => void;
};

const CORS_HEADERS: Record<string, string> = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers":
    "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, " +
    "x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
  "access-control-allow-methods": "POST, OPTIONS",
};

export type ChatResponseBody = {
  reply: string;
  pending_action: PendingAction | null;
  provider: string | null;
  data_changed: boolean;
};

/** Reply to a `classify` request: a category name, or nothing. */
export type ClassifyResponseBody = {
  category: string | null;
  provider: string | null;
};

/** Builds the fetch handler. Pure with respect to its dependencies. */
export function createHandler(deps: HandlerDeps): (request: Request) => Promise<Response> {
  const log = deps.log ?? (() => {});
  const now = deps.now ?? (() => new Date());

  return async (request: Request): Promise<Response> => {
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }
    if (request.method !== "POST") {
      return json({ error: "method_not_allowed", message: "Use POST." }, 405);
    }

    try {
      // Authenticate before reading the body: an anonymous caller should not
      // even get to make the function parse JSON.
      const authorization = request.headers.get("authorization");
      if (!authorization) throw ChatError.unauthenticated();
      const session = await deps.openSession(authorization);
      if (!session) throw ChatError.unauthenticated();

      const limit = deps.rateLimiter.check(session.userId);
      if (!limit.allowed) throw ChatError.rateLimited(limit.retryAfterSeconds);

      const body = await readBody(request);
      const action = body.action ?? "chat";

      if (action === "chat") return json(await handleChat(session, body, deps, now, log), 200);
      if (action === "confirm") return json(await handleConfirm(session, body, now), 200);
      if (action === "classify") return json(await handleClassify(session, body, deps, log), 200);
      throw ChatError.badRequest("Unknown action.");
    } catch (error) {
      const chatError = toChatError(error);
      if (chatError.kind === "internal") {
        log("internal_error", { name: describeError(error) });
      }
      const headers: Record<string, string> = {};
      if (chatError.retryAfterSeconds) {
        headers["retry-after"] = String(chatError.retryAfterSeconds);
      }
      return json(
        { error: chatError.kind, message: chatError.publicMessage },
        chatError.status,
        headers,
      );
    }
  };
}

// ---------------------------------------------------------------------------
// chat
// ---------------------------------------------------------------------------

async function handleChat(
  session: Session,
  body: Record<string, unknown>,
  deps: HandlerDeps,
  now: () => Date,
  log: NonNullable<HandlerDeps["log"]>,
): Promise<ChatResponseBody> {
  const message = readMessage(body.message);
  const history = readHistory(body.history);
  const clientContext = isRecord(body.client_context) ? body.client_context : {};
  const today = resolveToday(clientContext.today, now());

  const providers = deps.providers();
  if (providers.length === 0) throw ChatError.notConfigured();

  const [currency, categories, accounts, methods] = await Promise.all([
    session.db.profileCurrency(session.userId).catch(() => null),
    session.db.listCategories(session.userId),
    session.db.listAccounts(session.userId).catch(() => []),
    session.db.listPaymentMethods(session.userId),
  ]);

  const ctx: ToolContext = {
    userId: session.userId,
    db: session.db,
    today,
    currency: currency ?? "INR",
  };

  const system = buildSystemPrompt({
    today,
    currency: ctx.currency,
    categoryNames: categories.map((c) => c.name),
    accountLabels: accounts.filter((a) => a.is_active).map(accountLabel),
    paymentMethodNames: methods.map((m) => m.name),
  });

  const chain = new ProviderChain(providers, (from, to, why, status) => log("fallback", { from, to, why, status }));
  const controller = new AbortController();
  const deadline = setTimeout(() => controller.abort(), LIMITS.requestBudgetMs);

  try {
    const result = await runAgent({
      chain,
      system,
      history,
      message,
      ctx,
      signal: controller.signal,
      onToolError: (tool, error) => log("tool_error", { tool, name: describeError(error) }),
    });
    return {
      reply: result.reply,
      pending_action: result.pendingAction,
      provider: result.provider,
      data_changed: false,
    };
  } catch (error) {
    throw describeProviderFailure(error, log);
  } finally {
    clearTimeout(deadline);
  }
}

/**
 * Turns a chain failure into the right thing to tell the user.
 *
 * Every provider's failure is logged with its status, so a misconfiguration
 * is always visible to whoever runs the app. What the *user* is told depends
 * on whether anything could have worked: "not set up" only when every
 * provider rejected us for a configuration reason, and "busy" whenever at
 * least one was merely rate limited, timing out or down.
 *
 * Getting this the wrong way round is what produced "the assistant is not set
 * up yet" on a deployment whose keys were fine — one provider answered 400
 * and the message blamed the keys for both.
 */
function describeProviderFailure(
  error: unknown,
  log: NonNullable<HandlerDeps["log"]>,
): unknown {
  if (error instanceof ProviderChainError) {
    for (const failure of error.failures) {
      log("provider_failed", {
        provider: failure.provider,
        failure: failure.failure,
        status: failure.status,
      });
    }
    return error.allConfiguration
      ? ChatError.notConfigured()
      : ChatError.providerUnavailable();
  }

  if (error instanceof ProviderError) {
    log("provider_failed", {
      provider: error.provider,
      failure: error.failure,
      status: error.status,
    });
    return error.isConfiguration
      ? ChatError.notConfigured()
      : ChatError.providerUnavailable();
  }

  return error;
}

// ---------------------------------------------------------------------------
// confirm
// ---------------------------------------------------------------------------

async function handleConfirm(
  session: Session,
  body: Record<string, unknown>,
  now: () => Date,
): Promise<ChatResponseBody> {
  const pending = body.pending_action;
  if (!isRecord(pending)) throw ChatError.badRequest("Nothing to confirm.");

  const tool = pending.tool;
  if (typeof tool !== "string" || !WRITE_TOOLS.some((t) => t.name === tool)) {
    throw ChatError.badRequest("That action is not available.");
  }
  if (!isRecord(pending.args)) throw ChatError.badRequest("That action is incomplete.");

  // The expiry is client-echoed and therefore advisory: it stops a stale
  // card from a long-backgrounded app firing by accident. The real guard is
  // that every argument is re-verified against live data in executeWrite.
  if (typeof pending.expires_at === "string") {
    const expires = Date.parse(pending.expires_at);
    if (Number.isFinite(expires) && expires < now().getTime()) {
      throw ChatError.actionRejected("That request has expired. Please ask again.");
    }
  }

  const clientContext = isRecord(body.client_context) ? body.client_context : {};
  const currency = await session.db.profileCurrency(session.userId).catch(() => null);
  const ctx: ToolContext = {
    userId: session.userId,
    db: session.db,
    today: resolveToday(clientContext.today, now()),
    currency: currency ?? "INR",
  };

  const result = await executeWrite(ctx, tool, pending.args);
  if (!result.ok) throw ChatError.actionRejected(result.error);

  return { reply: result.reply, pending_action: null, provider: null, data_changed: true };
}

// ---------------------------------------------------------------------------
// classify
// ---------------------------------------------------------------------------

/**
 * Suggests a spending category for one merchant name.
 *
 * Shares this function's authentication and rate limit rather than getting an
 * endpoint of its own, so there is exactly one door into the AI and one place
 * where the user's identity is established.
 *
 * The reply carries a category name and nothing else — no tools ran, no rows
 * were read beyond the caller's own category list, and nothing was written.
 */
async function handleClassify(
  session: Session,
  body: Record<string, unknown>,
  deps: HandlerDeps,
  log: NonNullable<HandlerDeps["log"]>,
): Promise<ClassifyResponseBody> {
  const merchant = readMerchant(body.merchant);

  const providers = deps.providers();
  if (providers.length === 0) throw ChatError.notConfigured();

  const categories = await session.db.listCategories(session.userId);
  if (categories.length === 0) return { category: null, provider: null };

  const chain = new ProviderChain(providers, (from, to, why, status) => log("fallback", { from, to, why, status }));
  const controller = new AbortController();
  const deadline = setTimeout(() => controller.abort(), CLASSIFY_BUDGET_MS);

  try {
    return await classifyMerchant({
      chain,
      merchant,
      categories: categories.map((c) => c.name),
      signal: controller.signal,
    });
  } catch (error) {
    throw describeProviderFailure(error, log);
  } finally {
    clearTimeout(deadline);
  }
}

function readMerchant(raw: unknown): string {
  if (typeof raw !== "string") throw ChatError.badRequest("A merchant name is required.");
  const merchant = raw.trim();
  if (merchant.length === 0) throw ChatError.badRequest("A merchant name is required.");
  if (merchant.length > MAX_MERCHANT_CHARS) throw ChatError.tooLarge();
  return merchant;
}

// ---------------------------------------------------------------------------
// Request parsing
// ---------------------------------------------------------------------------

async function readBody(request: Request): Promise<Record<string, unknown>> {
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (declared > LIMITS.maxBodyBytes) throw ChatError.tooLarge();

  const text = await request.text();
  if (text.length > LIMITS.maxBodyBytes) throw ChatError.tooLarge();
  if (text.trim().length === 0) throw ChatError.badRequest("The request had no body.");

  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw ChatError.badRequest("The request was not valid JSON.");
  }
  if (!isRecord(parsed)) throw ChatError.badRequest("The request must be a JSON object.");
  return parsed;
}

function readMessage(raw: unknown): string {
  if (typeof raw !== "string") throw ChatError.badRequest("A message is required.");
  const message = raw.trim();
  if (message.length === 0) throw ChatError.badRequest("A message is required.");
  if (message.length > LIMITS.maxMessageChars) throw ChatError.tooLarge();
  return message;
}

/**
 * Accepts only what a conversation transcript legitimately contains: user
 * and assistant text. A "system" turn, a tool turn, or anything else the
 * client tries to slip in is dropped, and the whole history is capped.
 */
function readHistory(raw: unknown): HistoryTurn[] {
  if (!Array.isArray(raw)) return [];
  const turns: HistoryTurn[] = [];
  for (const item of raw) {
    if (!isRecord(item)) continue;
    const role = item.role;
    const content = item.content;
    if ((role !== "user" && role !== "assistant") || typeof content !== "string") continue;
    const trimmed = content.trim();
    if (trimmed.length === 0) continue;
    turns.push({ role, content: trimmed.slice(0, LIMITS.maxMessageChars) });
  }

  const recent = turns.slice(-LIMITS.maxHistoryMessages);
  let budget = LIMITS.maxHistoryChars;
  const kept: HistoryTurn[] = [];
  for (let i = recent.length - 1; i >= 0; i--) {
    budget -= recent[i].content.length;
    if (budget < 0) break;
    kept.unshift(recent[i]);
  }
  return kept;
}

// ---------------------------------------------------------------------------

function json(body: unknown, status: number, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...CORS_HEADERS, ...extra },
  });
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Error class plus a bounded message — enough to debug, never a payload. */
function describeError(error: unknown): string {
  if (error instanceof Error) return `${error.name}: ${error.message}`.slice(0, 160);
  return typeof error;
}
