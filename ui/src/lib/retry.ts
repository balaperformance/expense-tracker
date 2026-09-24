import { isPostgrestCode } from './errors';

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/**
 * Retries a request that failed for a transient, self-correcting reason.
 * Port of `core/errors/retry.dart`.
 *
 * `PGRST303 — JWT issued at future` happens when the very first request after
 * signing in reaches PostgREST within the same second the token was stamped.
 * Waiting a moment and asking again resolves it.
 */
export async function retryOnTransientAuth<T>(
  action: () => Promise<T>,
  { attempts = 3, stepMs = 700 }: { attempts?: number; stepMs?: number } = {},
): Promise<T> {
  for (let attempt = 0; ; attempt++) {
    try {
      return await action();
    } catch (error) {
      if (!isPostgrestCode(error, 'PGRST303') || attempt >= attempts - 1) throw error;
      await sleep(stepMs * (attempt + 1));
    }
  }
}
