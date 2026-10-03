/**
 * Tags on expenses and income. A tag is a short label the user types once and
 * reuses; names are unique per user ignoring case, so typing "CarSpending"
 * when "carspending" exists picks the existing tag rather than adding another.
 * The database applies the same rules (migration 006); this keeps the form's
 * list honest before anything is saved.
 */

export const MAX_TAG_LENGTH = 40;
export const MAX_TAGS_PER_TRANSACTION = 20;

export type Tag = { id: string; name: string };

export type TagKind = 'expense' | 'income';

/** A typed tag as it is stored: no leading #, single spaces, trimmed. */
export function normaliseTagName(raw: string): string {
  return raw.replace(/^\s*#+/, '').replace(/\s+/g, ' ').trim();
}

/** What two spellings of the same tag have in common. */
export const tagKey = (name: string): string => normaliseTagName(name).toLowerCase();

/**
 * [tags] with [raw] added. A name that matches an existing tag takes that
 * tag's spelling; a repeat, a blank or anything past the limit changes nothing.
 */
export function addTag(tags: readonly string[], raw: string, known: readonly Tag[] = []): string[] {
  const name = normaliseTagName(raw).slice(0, MAX_TAG_LENGTH).trim();
  if (!name || tags.length >= MAX_TAGS_PER_TRANSACTION) return [...tags];
  const key = tagKey(name);
  if (tags.some((t) => tagKey(t) === key)) return [...tags];
  const existing = known.find((t) => tagKey(t.name) === key);
  return [...tags, existing?.name ?? name];
}

export function removeTag(tags: readonly string[], name: string): string[] {
  const key = tagKey(name);
  return tags.filter((t) => tagKey(t) !== key);
}

/** Splits text containing commas into the finished tags before the last comma and what is still being typed. */
export function splitTyped(text: string): { done: string[]; rest: string } {
  const pieces = text.split(',');
  const rest = pieces.pop() ?? '';
  return { done: pieces.map(normaliseTagName).filter(Boolean), rest };
}

/**
 * Existing tags to offer: those not already on the transaction that contain
 * what is typed, the ones that start with it first. Everything when nothing is typed.
 */
export function tagSuggestions(known: readonly Tag[], selected: readonly string[], typed: string): Tag[] {
  const query = tagKey(typed);
  const chosen = new Set(selected.map(tagKey));
  const open = known.filter((t) => !chosen.has(tagKey(t.name)) && (!query || tagKey(t.name).includes(query)));
  const rank = (t: Tag) => (query && tagKey(t.name).startsWith(query) ? 0 : 1);
  return [...open].sort((a, b) => rank(a) - rank(b) || a.name.localeCompare(b.name));
}

/** The typed text as a brand-new tag, or null when it is blank, already chosen, or already exists. */
export function newTagFor(known: readonly Tag[], selected: readonly string[], typed: string): string | null {
  const name = normaliseTagName(typed).slice(0, MAX_TAG_LENGTH).trim();
  if (!name) return null;
  const key = tagKey(name);
  if (selected.some((t) => tagKey(t) === key) || known.some((t) => tagKey(t.name) === key)) return null;
  return name;
}

/** The names of the tags with these ids, in the order of [ids]; ids that are not known are skipped. */
export function tagNames(known: readonly Tag[], ids: readonly string[]): string[] {
  const byId = new Map(known.map((t) => [t.id, t.name]));
  return ids.flatMap((id) => {
    const name = byId.get(id);
    return name ? [name] : [];
  });
}
