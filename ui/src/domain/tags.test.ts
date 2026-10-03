import { describe, expect, it } from 'vitest';

import {
  addTag,
  MAX_TAG_LENGTH,
  MAX_TAGS_PER_TRANSACTION,
  newTagFor,
  normaliseTagName,
  removeTag,
  splitTyped,
  tagNames,
  tagSuggestions,
  type Tag,
} from './tags';

const known: Tag[] = [
  { id: 't1', name: 'carspending' },
  { id: 't2', name: 'myfamfood' },
  { id: 't3', name: 'bikespending' },
  { id: 't4', name: 'MyOwnSpending' },
];

describe('tag names', () => {
  it('drops a leading #, collapses spaces and trims', () => {
    expect(normaliseTagName('  #  car   spending ')).toBe('car spending');
    expect(normaliseTagName('##fuel')).toBe('fuel');
    expect(normaliseTagName('   ')).toBe('');
  });
});

describe('adding and removing', () => {
  it('adds a new tag as typed', () => {
    expect(addTag(['a'], 'fuel')).toEqual(['a', 'fuel']);
  });

  it('reuses the spelling of an existing tag, whatever case was typed', () => {
    expect(addTag([], 'MYOWNSPENDING', known)).toEqual(['MyOwnSpending']);
    expect(addTag([], 'CarSpending', known)).toEqual(['carspending']);
  });

  it('never adds a tag twice, ignoring case', () => {
    expect(addTag(['carspending'], 'CARSPENDING', known)).toEqual(['carspending']);
  });

  it('ignores blanks and respects the limits', () => {
    expect(addTag(['a'], '  # ')).toEqual(['a']);
    expect(addTag([], 'x'.repeat(MAX_TAG_LENGTH + 10))).toEqual(['x'.repeat(MAX_TAG_LENGTH)]);
    const full = Array.from({ length: MAX_TAGS_PER_TRANSACTION }, (_, i) => `t${i}`);
    expect(addTag(full, 'one more')).toEqual(full);
  });

  it('removes a tag ignoring case', () => {
    expect(removeTag(['carspending', 'fuel'], 'CarSpending')).toEqual(['fuel']);
  });
});

describe('typing with commas', () => {
  it('finishes the tags before the last comma and keeps the rest as typed', () => {
    expect(splitTyped('fuel, tolls,par')).toEqual({ done: ['fuel', 'tolls'], rest: 'par' });
    expect(splitTyped('fuel')).toEqual({ done: [], rest: 'fuel' });
    expect(splitTyped(',,')).toEqual({ done: [], rest: '' });
  });
});

describe('suggestions', () => {
  it('offers every existing tag when nothing is typed', () => {
    expect(tagSuggestions(known, [], '').map((t) => t.name)).toEqual(['bikespending', 'carspending', 'myfamfood', 'MyOwnSpending']);
  });

  it('hides tags already on the transaction', () => {
    expect(tagSuggestions(known, ['MYFAMFOOD'], '').map((t) => t.id)).not.toContain('t2');
  });

  it('narrows as you type, prefix matches first, ignoring case', () => {
    expect(tagSuggestions(known, [], 'SPEND').map((t) => t.name)).toEqual(['bikespending', 'carspending', 'MyOwnSpending']);
    expect(tagSuggestions(known, [], 'my').map((t) => t.name)).toEqual(['myfamfood', 'MyOwnSpending']);
    expect(tagSuggestions(known, [], 'zzz')).toEqual([]);
  });
});

describe('creating a tag', () => {
  it('offers to create a name that does not exist', () => {
    expect(newTagFor(known, [], '  #holiday ')).toBe('holiday');
  });

  it('does not offer a name that exists, is chosen, or is blank', () => {
    expect(newTagFor(known, [], 'CARSPENDING')).toBeNull();
    expect(newTagFor(known, ['holiday'], 'Holiday')).toBeNull();
    expect(newTagFor(known, [], '   ')).toBeNull();
  });
});

describe('reading a transaction’s tags', () => {
  it('maps ids to names in order and skips unknown ids', () => {
    expect(tagNames(known, ['t3', 'gone', 't1'])).toEqual(['bikespending', 'carspending']);
  });
});
