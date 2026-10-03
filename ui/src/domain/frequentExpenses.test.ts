import { describe, expect, it } from 'vitest';

import fixture from './frequentExpenses.fixture.json';
import { FREQUENT_LIMIT, frequentExpenses, type FrequentExpenseContext } from './frequentExpenses';

type FixtureCase = (typeof fixture.cases)[number];

const contextOf = (c: FixtureCase): FrequentExpenseContext => ({
  today: c.today,
  excludeIds: new Set(c.context.excludeIds),
  categoryIds: new Set(c.context.categoryIds),
  paymentMethodIds: new Set(c.context.paymentMethodIds),
  accountIds: new Set(c.context.accountIds),
  cardIds: new Set(c.context.cardIds),
});

describe('frequentExpenses (shared fixture with the mobile app)', () => {
  for (const c of fixture.cases) {
    it(c.name, () => {
      expect(frequentExpenses(c.expenses, contextOf(c), c.limit)).toEqual(c.expected);
    });
  }

  const [main] = fixture.cases;
  if (!main) throw new Error('The fixture has no cases.');

  it('offers the six most frequent by default', () => {
    expect(frequentExpenses(main.expenses, contextOf(main))).toEqual(main.expected.slice(0, FREQUENT_LIMIT));
  });

  it('does not depend on the order the purchases arrive in', () => {
    expect(frequentExpenses([...main.expenses].reverse(), contextOf(main), main.limit)).toEqual(main.expected);
  });

  it('counts purchases paid for someone else once they are no longer marked', () => {
    const unmarked = { ...contextOf(main), excludeIds: new Set<string>() };
    const lunch = frequentExpenses(main.expenses, unmarked, main.limit).find((s) => s.key === 'catFood|team lunch');
    expect(lunch).toMatchObject({ count: 3, amount: 400, source: { kind: 'account', id: 'accMain' } });
  });
});
