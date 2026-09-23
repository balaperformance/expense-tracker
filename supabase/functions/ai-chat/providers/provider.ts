import type { Completion, CompletionRequest } from "../core/messages.ts";

/** Why a provider call failed, in terms the chain can act on. */
export type ProviderFailure =
  | "rate_limited"
  | "unavailable"
  | "timeout"
  | "model_not_found"
  | "auth"
  | "invalid_request"
  | "malformed_response";

/**
 * Failures that mean *this provider is misconfigured* rather than busy.
 *
 * The distinction drives what the user is told, not whether the chain
 * continues — the chain always continues. Reported only when **every**
 * provider failed this way, because that is the only situation in which
 * "the assistant is not set up" is true.
 *
 * `invalid_request` has to be in here, and it is the reason this set exists:
 * Google's Generative Language API answers a bad, restricted or unrecognised
 * API key with **HTTP 400 INVALID_ARGUMENT**, not 401. Any classification
 * that assumes "400 means our request was malformed" therefore mislabels the
 * commonest key problem there is.
 */
const CONFIGURATION_FAILURES: ReadonlySet<ProviderFailure> =
  new Set<ProviderFailure>([
    "auth",
    "invalid_request",
    "model_not_found",
  ]);

export class ProviderError extends Error {
  readonly provider: string;
  readonly failure: ProviderFailure;
  readonly status?: number;

  constructor(
    provider: string,
    failure: ProviderFailure,
    detail: string,
    status?: number,
  ) {
    // The detail is for server logs only; it never reaches a user.
    super(`${provider}: ${failure} (${detail})`);
    this.name = "ProviderError";
    this.provider = provider;
    this.failure = failure;
    this.status = status;
  }

  /** True when this failure points at configuration rather than load. */
  get isConfiguration(): boolean {
    return CONFIGURATION_FAILURES.has(this.failure);
  }

  /** Maps an HTTP status from a provider to a failure class. */
  static fromStatus(provider: string, status: number, body: string): ProviderError {
    const detail = body.slice(0, 200);
    if (status === 429) return new ProviderError(provider, "rate_limited", detail, status);
    if (status === 401 || status === 403) return new ProviderError(provider, "auth", detail, status);
    if (status === 404) return new ProviderError(provider, "model_not_found", detail, status);
    if (status === 400 || status === 422) {
      return new ProviderError(provider, "invalid_request", detail, status);
    }
    if (status >= 500) return new ProviderError(provider, "unavailable", detail, status);
    return new ProviderError(provider, "unavailable", detail, status);
  }
}

export interface AIProvider {
  readonly name: string;
  readonly model: string;
  complete(request: CompletionRequest): Promise<Completion>;
}

export type ChainOutcome = {
  completion: Completion;
  provider: string;
};

/**
 * Called when one provider hands off to the next.
 *
 * Carries the HTTP status as well as the failure class, because a provider
 * that fails on *every* request while the fallback quietly covers for it is
 * invisible unless the log says whether it was a 429 (quota, fixes itself)
 * or a 400 (a key or model that needs attention).
 */
export type OnFallback = (
  from: string,
  to: string,
  why: ProviderFailure,
  status?: number,
) => void;

/** Every provider refused. Carries each failure so the caller can diagnose. */
export class ProviderChainError extends Error {
  readonly failures: readonly ProviderError[];

  constructor(failures: readonly ProviderError[]) {
    super(`all providers failed: ${failures.map((f) => f.message).join("; ")}`);
    this.name = "ProviderChainError";
    this.failures = failures;
  }

  /**
   * True when *every* provider failed for a configuration reason.
   *
   * Only then is "the assistant is not set up" an honest thing to tell the
   * user. One bad key among two providers is an operator problem to fix, not
   * a reason to deny service.
   */
  get allConfiguration(): boolean {
    return this.failures.length > 0 &&
      this.failures.every((failure) => failure.isConfiguration);
  }

  get last(): ProviderError | undefined {
    return this.failures[this.failures.length - 1];
  }
}

/**
 * Primary then fallback. One request, one pass down the list, no retries of
 * the same provider.
 *
 * **Every provider is tried, whatever the first one's failure was.** An
 * earlier version stopped the chain on an `auth` or `invalid_request`
 * failure, on the reasoning that a bad key is a deployment problem and
 * falling back would hide it behind a working provider. That reasoning
 * traded the user's working assistant for the operator's convenience, and it
 * was wrong twice over:
 *
 *  * Google reports a bad key as HTTP 400, which classified as
 *    `invalid_request` — so a single unhealthy Gemini key stopped the chain
 *    dead and the healthy Groq fallback was never called.
 *  * The misconfiguration is not hidden either way: every failure is logged
 *    with its provider and status, and the user is only told "not set up"
 *    when all providers failed that way.
 *
 * Built per request. Once a provider has answered it stays preferred for the
 * rest of that request, so a conversation does not ping-pong between two
 * models mid-thought.
 */
export class ProviderChain {
  private preferred = 0;
  private readonly onFallback?: OnFallback;

  constructor(
    private readonly providers: readonly AIProvider[],
    onFallback?: OnFallback,
  ) {
    this.onFallback = onFallback;
  }

  get isEmpty(): boolean {
    return this.providers.length === 0;
  }

  async complete(request: CompletionRequest): Promise<ChainOutcome> {
    if (this.providers.length === 0) {
      throw new ProviderChainError([
        new ProviderError("none", "unavailable", "no providers configured"),
      ]);
    }

    const failures: ProviderError[] = [];

    for (let i = this.preferred; i < this.providers.length; i++) {
      const provider = this.providers[i];
      try {
        const completion = await provider.complete(request);
        this.preferred = i;
        return { completion, provider: provider.name };
      } catch (error) {
        const failure = error instanceof ProviderError
          ? error
          : new ProviderError(provider.name, "unavailable", String(error));
        failures.push(failure);

        const next = this.providers[i + 1];
        if (next) {
          this.onFallback?.(provider.name, next.name, failure.failure, failure.status);
        }
      }
    }

    throw new ProviderChainError(failures);
  }
}
