/**
 * Defensive readers for PostgREST rows.
 *
 * The client is untyped on purpose — its select strings are built at runtime
 * from the schema probe — so every row is read field by field here, the way
 * the Dart models' `fromMap` constructors do. A malformed value degrades to
 * the documented fallback instead of crashing a list.
 */

export type Row = Record<string, unknown>;

export function asRows(data: unknown): Row[] {
  if (!Array.isArray(data)) return [];
  return data.filter((item): item is Row => typeof item === 'object' && item !== null);
}

export function asRow(data: unknown): Row | null {
  return typeof data === 'object' && data !== null && !Array.isArray(data) ? (data as Row) : null;
}

export function str(row: Row, key: string): string {
  const value = row[key];
  return typeof value === 'string' ? value : '';
}

export function optStr(row: Row, key: string): string | null {
  const value = row[key];
  return typeof value === 'string' ? value : null;
}

export function num(row: Row, key: string): number {
  const value = row[key];
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value === 'string') {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

export function bool(row: Row, key: string, fallback: boolean): boolean {
  const value = row[key];
  return typeof value === 'boolean' ? value : fallback;
}

export function nested(row: Row, key: string): Row | null {
  return asRow(row[key]);
}
