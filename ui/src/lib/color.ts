/**
 * Category colours are stored per row as hex strings, so parsing is
 * defensive: a malformed value must never break a list. Port of
 * `AppColors.fromHex` / `AppColors.readableOn`.
 */

export const FALLBACK_CATEGORY_COLOR = '#78909C';

/** Offered when creating a category — spread around the wheel, readable in both themes. */
export const CATEGORY_SWATCHES = [
  '#C2703D',
  '#4F7CAC',
  '#8E6BA8',
  '#3F8F84',
  '#C0587E',
  '#B84A4A',
  '#4A9BB5',
  '#7466B0',
  '#7A6E62',
  '#5E9A5A',
  '#D19A2E',
  '#8C6A43',
] as const;

type Rgb = { r: number; g: number; b: number };

export function parseHex(hex: string | null | undefined): Rgb | null {
  if (!hex) return null;
  let value = hex.trim().replace(/^#/, '');
  if (value.length === 8) value = value.slice(2); // AARRGGBB
  if (!/^[0-9a-fA-F]{6}$/.test(value)) return null;
  const int = parseInt(value, 16);
  return { r: (int >> 16) & 255, g: (int >> 8) & 255, b: int & 255 };
}

function toHex({ r, g, b }: Rgb): string {
  const h = (v: number) => Math.round(Math.min(255, Math.max(0, v))).toString(16).padStart(2, '0');
  return `#${h(r)}${h(g)}${h(b)}`.toUpperCase();
}

function rgbToHsl({ r, g, b }: Rgb): { h: number; s: number; l: number } {
  const rn = r / 255;
  const gn = g / 255;
  const bn = b / 255;
  const max = Math.max(rn, gn, bn);
  const min = Math.min(rn, gn, bn);
  const l = (max + min) / 2;
  if (max === min) return { h: 0, s: 0, l };
  const d = max - min;
  const s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
  let h: number;
  if (max === rn) h = (gn - bn) / d + (gn < bn ? 6 : 0);
  else if (max === gn) h = (bn - rn) / d + 2;
  else h = (rn - gn) / d + 4;
  return { h: h * 60, s, l };
}

function hslToRgb(h: number, s: number, l: number): Rgb {
  const c = (1 - Math.abs(2 * l - 1)) * s;
  const x = c * (1 - Math.abs(((h / 60) % 2) - 1));
  const m = l - c / 2;
  const [r1, g1, b1] =
    h < 60 ? [c, x, 0] : h < 120 ? [x, c, 0] : h < 180 ? [0, c, x] : h < 240 ? [0, x, c] : h < 300 ? [x, 0, c] : [c, 0, x];
  return { r: (r1 + m) * 255, g: (g1 + m) * 255, b: (b1 + m) * 255 };
}

/** A safe `#RRGGBB` for a stored category colour. */
export function categoryColor(hex: string | null | undefined): string {
  const rgb = parseHex(hex) ?? parseHex(FALLBACK_CATEGORY_COLOR);
  return rgb ? toHex(rgb) : FALLBACK_CATEGORY_COLOR;
}

/**
 * Lifts a category colour so it stays legible on a dark surface. Only raises
 * lightness when it has dropped below the contrast floor.
 */
export function readableOn(hex: string | null | undefined, dark: boolean): string {
  const base = categoryColor(hex);
  if (!dark) return base;
  const rgb = parseHex(base);
  if (!rgb) return base;
  const { h, s, l } = rgbToHsl(rgb);
  if (l >= 0.58) return base;
  return toHex(hslToRgb(h, s, 0.68));
}

/** Whether white text reads better than black on [hex]. */
export function prefersLightInk(hex: string): boolean {
  const rgb = parseHex(hex);
  if (!rgb) return true;
  const luminance = (0.299 * rgb.r + 0.587 * rgb.g + 0.114 * rgb.b) / 255;
  return luminance < 0.6;
}
