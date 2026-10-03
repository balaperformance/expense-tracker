/**
 * Calendar dates for the sender, as ISO `yyyy-MM-dd` strings like the rest of
 * the app. The sender runs in UTC on a server, so nothing here reads the
 * machine's time zone: day arithmetic is done in UTC and the user's own clock
 * is read through `Intl` with their IANA zone.
 */
export type IsoDate = string;

const pad = (value: number) => String(value).padStart(2, '0');

export const toIso = (year: number, month: number, day: number): IsoDate => `${year}-${pad(month)}-${pad(day)}`;

export function parts(iso: IsoDate): { year: number; month: number; day: number } {
  const [y, m, d] = iso.slice(0, 10).split('-').map(Number);
  return { year: y ?? 1970, month: m ?? 1, day: d ?? 1 };
}

export const daysInMonth = (year: number, month: number): number => new Date(Date.UTC(year, month, 0)).getUTCDate();

export function addDays(iso: IsoDate, delta: number): IsoDate {
  const { year, month, day } = parts(iso);
  const date = new Date(Date.UTC(year, month - 1, day + delta));
  return toIso(date.getUTCFullYear(), date.getUTCMonth() + 1, date.getUTCDate());
}

/** First day of the month [delta] months from [iso]'s month. */
export function addMonths(iso: IsoDate, delta: number): IsoDate {
  const { year, month } = parts(iso);
  const zeroBased = month - 1 + delta;
  return toIso(year + Math.floor(zeroBased / 12), (((zeroBased % 12) + 12) % 12) + 1, 1);
}

export const firstOfMonth = (iso: IsoDate): IsoDate => `${iso.slice(0, 7)}-01`;

export function lastOfMonth(iso: IsoDate): IsoDate {
  const { year, month } = parts(iso);
  return toIso(year, month, daysInMonth(year, month));
}

/** Day [day] of [anchor]'s month, clamped to that month's length (31 → 28 Feb). */
export function dayInMonth(anchor: IsoDate, day: number): IsoDate {
  const { year, month } = parts(anchor);
  return toIso(year, month, Math.min(Math.max(1, Math.trunc(day)), daysInMonth(year, month)));
}

/** The user's wall clock at one instant. */
export type LocalClock = { date: IsoDate; hour: number; minute: number };

export function isValidTimeZone(timeZone: string): boolean {
  try {
    new Intl.DateTimeFormat('en-US', { timeZone });
    return true;
  } catch {
    return false;
  }
}

/** [now] on the clock of [timeZone]; null when the zone is not a real IANA name. */
export function localClock(now: Date, timeZone: string): LocalClock | null {
  if (!isValidTimeZone(timeZone)) return null;
  const formatted = new Intl.DateTimeFormat('en-US', {
    timeZone,
    hourCycle: 'h23',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  }).formatToParts(now);
  const value = (type: string) => Number(formatted.find((p) => p.type === type)?.value);
  const year = value('year');
  const month = value('month');
  const day = value('day');
  const hour = value('hour');
  const minute = value('minute');
  if ([year, month, day, hour, minute].some((n) => !Number.isFinite(n))) return null;
  return { date: toIso(year, month, day), hour, minute };
}
