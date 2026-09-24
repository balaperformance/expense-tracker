/**
 * Chart colours — the muted jewel palette (`app_chart_colors.dart`), read
 * through CSS variables so a chart never needs to know which theme is on.
 */
export const SEGMENT_COLORS = [
  'var(--chart-1)',
  'var(--chart-2)',
  'var(--chart-3)',
  'var(--chart-4)',
  'var(--chart-5)',
  'var(--chart-6)',
] as const;

export const MAX_SLICES = 6;

/**
 * Colour for the category ranked [rank] (0 = largest) out of [count]. The
 * donut and its ranked list both call this, so a category is the same colour
 * in the ring and in the legend — including those folded into "Other".
 */
export function segmentColor(rank: number, count: number, maxSlices = MAX_SLICES): string {
  if (count > maxSlices && rank >= maxSlices - 1) return 'var(--chart-other)';
  return SEGMENT_COLORS[rank % SEGMENT_COLORS.length] ?? 'var(--chart-other)';
}
