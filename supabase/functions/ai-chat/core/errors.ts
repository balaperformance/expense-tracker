/**
 * The only error type the HTTP layer turns into a response.
 *
 * Every failure that reaches the user is deliberately reduced to a `kind` and
 * a `publicMessage` written for a person, never a stack trace, a Postgres
 * message or a provider payload. Anything that is not a ChatError is treated
 * as internal and reported as a generic failure.
 */
export type ChatErrorKind =
  | "unauthenticated"
  | "bad_request"
  | "payload_too_large"
  | "rate_limited"
  | "not_configured"
  | "provider_unavailable"
  | "action_rejected"
  | "internal";

export class ChatError extends Error {
  readonly kind: ChatErrorKind;
  readonly publicMessage: string;
  readonly status: number;
  readonly retryAfterSeconds?: number;

  constructor(
    kind: ChatErrorKind,
    publicMessage: string,
    status: number,
    retryAfterSeconds?: number,
  ) {
    super(`${kind}: ${publicMessage}`);
    this.name = "ChatError";
    this.kind = kind;
    this.publicMessage = publicMessage;
    this.status = status;
    this.retryAfterSeconds = retryAfterSeconds;
  }

  static unauthenticated(): ChatError {
    return new ChatError(
      "unauthenticated",
      "You need to be signed in to use the assistant.",
      401,
    );
  }

  static badRequest(message: string): ChatError {
    return new ChatError("bad_request", message, 400);
  }

  static tooLarge(): ChatError {
    return new ChatError(
      "payload_too_large",
      "That message is too long. Try asking in fewer words.",
      413,
    );
  }

  static rateLimited(retryAfterSeconds: number): ChatError {
    return new ChatError(
      "rate_limited",
      "You are sending messages quickly. Give it a moment and try again.",
      429,
      retryAfterSeconds,
    );
  }

  static notConfigured(): ChatError {
    return new ChatError(
      "not_configured",
      "The assistant is not set up yet. Ask whoever runs this app to add " +
        "the AI provider keys.",
      503,
    );
  }

  static providerUnavailable(): ChatError {
    return new ChatError(
      "provider_unavailable",
      "The assistant is busy right now. Please try again in a moment.",
      503,
    );
  }

  static actionRejected(message: string): ChatError {
    return new ChatError("action_rejected", message, 422);
  }

  static internal(): ChatError {
    return new ChatError(
      "internal",
      "Something went wrong. Please try again.",
      500,
    );
  }
}

/** Narrows an unknown thrown value to a ChatError, hiding anything else. */
export function toChatError(error: unknown): ChatError {
  if (error instanceof ChatError) return error;
  return ChatError.internal();
}
