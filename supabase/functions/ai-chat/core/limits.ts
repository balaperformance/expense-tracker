/**
 * Every hard limit in one place.
 *
 * These exist because the function is callable by any signed-in user and
 * talks to a metered third party. Each number is a ceiling the code enforces,
 * not a tuning suggestion, and each is tested.
 */
export const LIMITS = {
  /** A chat message from the user. Enough for a paragraph, not an essay. */
  maxMessageChars: 1000,

  /** Turns of prior conversation the client may send back. */
  maxHistoryMessages: 12,

  /** Total characters across the history, so twelve long turns cannot
   * smuggle in a novel. */
  maxHistoryChars: 6000,

  /** Whole request body. Generous for the fields above, far below anything
   * that would strain the function. */
  maxBodyBytes: 32 * 1024,

  /** Model → tool → model round trips per user message. A real question
   * takes one or two; six means the model is looping. */
  maxToolIterations: 6,

  /** One call to one provider. */
  providerTimeoutMs: 25_000,

  /** The whole request, across every provider call and fallback. */
  requestBudgetMs: 60_000,

  /** Per-user sliding window. */
  rateLimitWindowMs: 5 * 60_000,
  rateLimitMaxRequests: 20,

  /** Rows one aggregate may read. Matches the app's own monthly cap. */
  maxRowsPerAggregate: 2000,

  /** Rows a "show me" style tool may hand to the model. */
  maxListedRows: 20,

  /** Characters of any single tool result passed to the model. */
  maxToolResultChars: 6000,

  /** How long a prepared write may sit unconfirmed. */
  pendingActionTtlMs: 10 * 60_000,
} as const;

/**
 * Sliding-window limiter keyed by user id.
 *
 * In-memory, so it is per isolate: a burst that lands on two isolates gets
 * two windows. That is acceptable for what this protects — a runaway client
 * or a user hammering the free-tier quota — and it costs no database table.
 * A shared limiter would be the first thing to add if quotas ever bind.
 */
export class RateLimiter {
  private readonly hits = new Map<string, number[]>();

  constructor(
    private readonly max: number,
    private readonly windowMs: number,
    private readonly now: () => number = () => Date.now(),
  ) {}

  /** Records a hit and says whether it was within the limit. */
  check(key: string): { allowed: boolean; retryAfterSeconds: number } {
    const current = this.now();
    const floor = current - this.windowMs;
    const recent = (this.hits.get(key) ?? []).filter((t) => t > floor);

    if (recent.length >= this.max) {
      this.hits.set(key, recent);
      const oldest = recent[0];
      const retryAfterMs = Math.max(0, oldest + this.windowMs - current);
      return {
        allowed: false,
        retryAfterSeconds: Math.max(1, Math.ceil(retryAfterMs / 1000)),
      };
    }

    recent.push(current);
    this.hits.set(key, recent);

    // Keep the map from growing without bound across a long-lived isolate.
    if (this.hits.size > 10_000) this.prune(floor);

    return { allowed: true, retryAfterSeconds: 0 };
  }

  private prune(floor: number): void {
    for (const [key, times] of this.hits) {
      if (times.every((t) => t <= floor)) this.hits.delete(key);
    }
  }
}
