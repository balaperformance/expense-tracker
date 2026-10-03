/**
 * Turns the name a person typed into the row it refers to.
 *
 * Names arrive from a language model paraphrasing a user, so "hdfc", "HDFC
 * Bank", "my salary account" and "the 4821 one" all have to land on the same
 * row — but "Food" must never silently become "Food Delivery" when both
 * exist. Exact wins, then unique prefix, then unique containment, then a
 * unique token overlap. Anything still ambiguous is reported as ambiguous so
 * the model asks instead of guessing.
 */
export type Named = { id: string; labels: string[] };

export type Resolution<T extends Named> =
  | { kind: "found"; item: T }
  | { kind: "ambiguous"; candidates: T[] }
  | { kind: "none" };

export function resolveByName<T extends Named>(items: T[], query: string): Resolution<T> {
  const q = normalise(query);
  if (!q) return { kind: "none" };

  const passes: Array<(label: string) => boolean> = [
    (label) => label === q,
    (label) => label.startsWith(q),
    (label) => label.includes(q),
    (label) => tokensOverlap(label, q),
    // Last resort: a one-word label that appears as a word in the query —
    // "the 4821 one", "hdfc please". Two accounts hit this way come back as
    // ambiguous, which is the right answer for "hdfc savings".
    (label) => !label.includes(" ") && q.split(" ").includes(label),
  ];

  for (const pass of passes) {
    const hits = items.filter((item) => item.labels.some((l) => pass(normalise(l))));
    if (hits.length === 1) return { kind: "found", item: hits[0] };
    if (hits.length > 1) return { kind: "ambiguous", candidates: hits };
  }
  return { kind: "none" };
}

function tokensOverlap(label: string, query: string): boolean {
  const labelTokens = new Set(label.split(" ").filter(Boolean));
  const queryTokens = query.split(" ").filter((t) => t.length > 1);
  if (queryTokens.length === 0) return false;
  // Every meaningful word of the query must appear in the label, otherwise
  // "HDFC savings" would match a plain "Savings" account at another bank.
  return queryTokens.every((t) => labelTokens.has(t));
}

export function normalise(value: string): string {
  return value
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s]/gu, " ")
    .replace(/\b(the|my|account|acct|bank|a|an)\b/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}
