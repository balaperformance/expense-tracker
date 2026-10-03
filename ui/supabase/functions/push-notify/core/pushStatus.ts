/** How to treat what a push service answered when a message was refused. */

/** True for failures that may pass: no answer at all, throttling, or a server error. */
export const isRetryableStatus = (status: number | null): boolean => status == null || status === 429 || status >= 500;

/** True when the subscription no longer exists and will never work again (RFC 8030: 404 and 410). */
export const isGoneStatus = (status: number | null): boolean => status === 404 || status === 410;
