import { ProviderError } from "./provider.ts";

/** Injectable fetch so adapters are testable without a network. */
export type FetchLike = (
  input: string,
  init: RequestInit,
) => Promise<Response>;

/**
 * POSTs JSON to a provider with a hard timeout and classifies the outcome.
 *
 * The outer `signal` is the request's overall budget; the inner timer is the
 * per-call ceiling. Either one aborting is reported as a timeout, which the
 * chain treats as grounds for fallback.
 */
export async function postJson(
  provider: string,
  fetchImpl: FetchLike,
  url: string,
  headers: Record<string, string>,
  body: unknown,
  timeoutMs: number,
  outer: AbortSignal,
): Promise<unknown> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  const onOuterAbort = () => controller.abort();
  if (outer.aborted) controller.abort();
  else outer.addEventListener("abort", onOuterAbort, { once: true });

  let response: Response;
  try {
    response = await fetchImpl(url, {
      method: "POST",
      headers: { "content-type": "application/json", ...headers },
      body: JSON.stringify(body),
      signal: controller.signal,
    });
  } catch (error) {
    if (controller.signal.aborted) {
      throw new ProviderError(provider, "timeout", "aborted");
    }
    throw new ProviderError(provider, "unavailable", describe(error));
  } finally {
    clearTimeout(timer);
    outer.removeEventListener("abort", onOuterAbort);
  }

  const text = await response.text();
  if (!response.ok) {
    throw ProviderError.fromStatus(provider, response.status, text);
  }

  try {
    return JSON.parse(text);
  } catch {
    throw new ProviderError(provider, "malformed_response", "non-JSON body");
  }
}

function describe(error: unknown): string {
  if (error instanceof Error) return `${error.name}: ${error.message}`.slice(0, 200);
  return String(error).slice(0, 200);
}

/**
 * Removes validation-only keywords a provider may reject.
 *
 * Gemini accepts an OpenAPI subset and errors on keywords outside it, and
 * the model does not need them anyway — every argument is validated
 * server-side against the full schema before a tool runs.
 */
export function providerSchema(schema: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(schema)) {
    if (key === "maxLength" || key === "minimum" || key === "maximum" || key === "pattern") {
      continue;
    }
    if (key === "properties" && value && typeof value === "object") {
      const props: Record<string, unknown> = {};
      for (const [name, sub] of Object.entries(value as Record<string, unknown>)) {
        props[name] = providerSchema(sub as Record<string, unknown>);
      }
      out[key] = props;
      continue;
    }
    out[key] = value;
  }
  return out;
}
