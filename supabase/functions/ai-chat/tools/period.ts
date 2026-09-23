/**
 * Date arithmetic on `YYYY-MM-DD` strings.
 *
 * Everything is done on calendar strings rather than Date objects so the
 * server's time zone can never shift a transaction into the wrong month. A
 * date column in Postgres is a calendar date; this keeps it one.
 */

export const DATE_PATTERN = "^\\d{4}-\\d{2}-\\d{2}$";
export const MONTH_PATTERN = "^\\d{4}-\\d{2}$";

const MONTH_NAMES = [
  "January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December",
];

export function isValidDate(value: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const [y, m, d] = value.split("-").map(Number);
  if (m < 1 || m > 12 || d < 1) return false;
  return d <= daysInMonth(y, m);
}

export function isValidMonth(value: string): boolean {
  if (!/^\d{4}-\d{2}$/.test(value)) return false;
  const m = Number(value.slice(5, 7));
  return m >= 1 && m <= 12;
}

export function daysInMonth(year: number, month: number): number {
  return new Date(Date.UTC(year, month, 0)).getUTCDate();
}

export function pad2(n: number): string {
  return n < 10 ? `0${n}` : String(n);
}

/** `YYYY-MM` of a `YYYY-MM-DD`. */
export function monthOf(date: string): string {
  return date.slice(0, 7);
}

export function firstDayOf(month: string): string {
  return `${month}-01`;
}

export function addMonths(month: string, delta: number): string {
  const [y, m] = month.split("-").map(Number);
  const zero = m - 1 + delta;
  const year = y + Math.floor(zero / 12);
  const mon = ((zero % 12) + 12) % 12 + 1;
  return `${year}-${pad2(mon)}`;
}

/** Half-open range covering one calendar month. */
export function monthRange(month: string): { from: string; toExclusive: string } {
  return { from: firstDayOf(month), toExclusive: firstDayOf(addMonths(month, 1)) };
}

/** Half-open range covering an inclusive `from..to` day range. */
export function dayRange(from: string, toInclusive: string): { from: string; toExclusive: string } {
  return { from, toExclusive: addDays(toInclusive, 1) };
}

export function addDays(date: string, delta: number): string {
  const [y, m, d] = date.split("-").map(Number);
  const t = new Date(Date.UTC(y, m - 1, d + delta));
  return `${t.getUTCFullYear()}-${pad2(t.getUTCMonth() + 1)}-${pad2(t.getUTCDate())}`;
}

export function compareDates(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

/** "September 2026" */
export function monthLabel(month: string): string {
  const [y, m] = month.split("-").map(Number);
  return `${MONTH_NAMES[m - 1]} ${y}`;
}

/** "22 Sep 2026" */
export function dateLabel(date: string): string {
  const [y, m, d] = date.split("-").map(Number);
  return `${d} ${MONTH_NAMES[m - 1].slice(0, 3)} ${y}`;
}

/** Server-side calendar date in UTC, the fallback when the client sends none. */
export function utcToday(now: Date = new Date()): string {
  return `${now.getUTCFullYear()}-${pad2(now.getUTCMonth() + 1)}-${pad2(now.getUTCDate())}`;
}

/**
 * Accepts the client's idea of "today" only when it is plausible.
 *
 * The phone knows its own time zone and the function does not, so the client
 * value is preferred — but only within a day either side of the server's
 * date. Anything else is a bug or a spoof and falls back to the server.
 */
export function resolveToday(clientToday: unknown, now: Date = new Date()): string {
  const server = utcToday(now);
  if (typeof clientToday !== "string" || !isValidDate(clientToday)) return server;
  const diff = Math.abs(
    (Date.parse(`${clientToday}T00:00:00Z`) - Date.parse(`${server}T00:00:00Z`)) / 86_400_000,
  );
  return diff <= 1 ? clientToday : server;
}
