/**
 * Calendar-date helpers. Port of `core/utils/date_utils.dart`.
 *
 * Every date in the domain is an ISO `yyyy-MM-dd` string — the wire format of
 * a Postgres `date` column. Keeping dates as strings means no time zone ever
 * shifts an expense onto the wrong day, and they sort and compare as text.
 */

export type IsoDate = string;

const pad = (value: number) => String(value).padStart(2, '0');

export function toIso(date: Date): IsoDate {
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}

export function fromParts(year: number, month: number, day: number): IsoDate {
  return toIso(new Date(year, month - 1, day));
}

export function parts(iso: IsoDate): { year: number; month: number; day: number } {
  const [y, m, d] = iso.slice(0, 10).split('-').map(Number);
  return { year: y ?? 1970, month: m ?? 1, day: d ?? 1 };
}

/** Local midnight of [iso]. */
export function toDate(iso: IsoDate): Date {
  const { year, month, day } = parts(iso);
  return new Date(year, month - 1, day);
}

export function isValidIso(value: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const { year, month, day } = parts(value);
  const date = new Date(year, month - 1, day);
  return date.getFullYear() === year && date.getMonth() === month - 1 && date.getDate() === day;
}

export function today(now: Date = new Date()): IsoDate {
  return toIso(now);
}

export function firstOfMonth(iso: IsoDate): IsoDate {
  return `${iso.slice(0, 7)}-01`;
}

/** First day of the month [delta] months from [iso]'s month. */
export function addMonths(iso: IsoDate, delta: number): IsoDate {
  const { year, month } = parts(iso);
  const zeroBased = month - 1 + delta;
  const y = year + Math.floor(zeroBased / 12);
  const m = ((zeroBased % 12) + 12) % 12;
  return `${y}-${pad(m + 1)}-01`;
}

export function addDays(iso: IsoDate, delta: number): IsoDate {
  const { year, month, day } = parts(iso);
  return toIso(new Date(year, month - 1, day + delta));
}

export type MonthRange = {
  /** First day of the month. */
  start: IsoDate;
  /** First day of the following month. */
  endExclusive: IsoDate;
  /** Last day of the month. */
  endInclusive: IsoDate;
};

export function monthRange(anchor: IsoDate): MonthRange {
  const start = firstOfMonth(anchor);
  const endExclusive = addMonths(anchor, 1);
  return { start, endExclusive, endInclusive: addDays(endExclusive, -1) };
}

/** The last [count] months ending with [anchor]'s month, oldest first. */
export function trailingMonths(anchor: IsoDate, count: number): IsoDate[] {
  return Array.from({ length: count }, (_, i) => addMonths(anchor, i - (count - 1)));
}

/** Whole days from [from] to [to] (positive when [to] is later). */
export function daysBetween(from: IsoDate, to: IsoDate): number {
  const ms = toDate(to).getTime() - toDate(from).getTime();
  return Math.round(ms / 86_400_000);
}
