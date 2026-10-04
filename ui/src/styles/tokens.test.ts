/// <reference types="node" />
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

import { describe, expect, it } from 'vitest';

/*
 * Matte & Sand must redefine every colour token the current palette sets,
 * or a screen would show a leftover Gothic Noir colour under data-palette="matte".
 * (Vitest stubs CSS imports, so the file is read from disk.)
 */
const css = readFileSync(fileURLToPath(new URL('./tokens.css', import.meta.url)), 'utf8').replace(/\r\n/g, '\n');

/** The declarations of the rule whose selector list ends exactly with `selector {`. */
function block(selector: string): Map<string, string> {
  const start = css.indexOf(`${selector} {\n`);
  if (start < 0) throw new Error(`No rule for ${selector}`);
  const body = css.slice(start, css.indexOf('\n}', start));
  const declarations = new Map<string, string>();
  for (const [, name = '', value = ''] of body.matchAll(/^\s*(--[\w-]+):\s*([^;]+);/gm)) declarations.set(name, value.trim());
  return declarations;
}

/** Layout, type and motion tokens are shared by both palettes. */
const SHARED = /^--(sp-|r-|dur-|ease-|safe-|font-|touch$|button-h|field-h$|avatar|appbar-h$|nav-h$|content-max$|gutter$|section$|card-gap$|card-pad$)/;

/** A token whose current value is another token follows that token into the new palette. */
const colourTokens = (rule: Map<string, string>) =>
  [...rule].filter(([name, value]) => !SHARED.test(name) && !value.startsWith('var(')).map(([name]) => name);

describe('Matte & Sand tokens', () => {
  const currentLight = block(':root');
  const currentDark = block(":root[data-theme='dark'],\n.theme-dark");
  const derived = block(':root,\n.theme-dark');
  const matteLight = block(":root[data-palette='matte']");
  const matteDark = block(":root[data-palette='matte'] .theme-dark");
  const matteDarkRoot = block(":root[data-palette='matte'][data-theme='dark']");

  it('redefines every light colour token', () => {
    const missing = [...colourTokens(currentLight), ...derived.keys()].filter((name) => !matteLight.has(name));
    expect(missing).toEqual([]);
  });

  it('redefines every dark colour token', () => {
    const missing = [...colourTokens(currentDark), ...derived.keys()].filter(
      (name) => !matteDark.has(name) && !matteDarkRoot.has(name),
    );
    expect(missing).toEqual([]);
  });

  it('keeps layout, type and motion tokens out of the palette', () => {
    expect([...matteLight.keys()].filter((name) => SHARED.test(name))).toEqual([]);
  });
});
