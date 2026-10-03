/**
 * When a credit card's bill is due — src/domain/creditCards.ts: the billing
 * cycle (`cycleContaining`, `dueDateAfter`) and the last statement's
 * remaining amount (`summariseCard`'s `lastStatement`), over the card's
 * movements. Only direction, amount and date of a movement matter here.
 */
import { addDays, addMonths, dayInMonth, type IsoDate } from './dates.ts';
import { toCents } from './money.ts';

export type CardRow = {
  id: string;
  name: string;
  statementDay: number;
  paymentDueDay: number;
  openingOutstanding: number;
  isActive: boolean;
};

/** A purchase, bill payment, refund, fee… from the card's side: debit raises the outstanding. */
export type CardEntryRow = { cardId: string; direction: 'debit' | 'credit'; amount: number; date: IsoDate };

export type BillingCycle = { start: IsoDate; end: IsoDate; dueDate: IsoDate };

/** The first [dueDay] strictly after the statement date. */
export function dueDateAfter(statementDate: IsoDate, dueDay: number): IsoDate {
  const sameMonth = dayInMonth(statementDate, dueDay);
  return sameMonth > statementDate ? sameMonth : dayInMonth(addMonths(statementDate, 1), dueDay);
}

export function cycleContaining(date: IsoDate, statementDay: number, dueDay: number): BillingCycle {
  const closesThisMonth = dayInMonth(date, statementDay);
  const end = date <= closesThisMonth ? closesThisMonth : dayInMonth(addMonths(date, 1), statementDay);
  const start = addDays(dayInMonth(addMonths(end, -1), statementDay), 1);
  return { start, end, dueDate: dueDateAfter(end, dueDay) };
}

export type LastStatement = {
  dueDate: IsoDate;
  remainingCents: number;
  /** 'due' only while some of the bill is still unpaid and the due date has not passed. */
  status: 'nothingDue' | 'paid' | 'due' | 'overdue';
};

/** The last closed statement's cycle on [today]; needs only the card's two days, not its movements. */
function lastClosedCycle(card: Pick<CardRow, 'statementDay' | 'paymentDueDay'>, today: IsoDate): BillingCycle {
  const currentCycle = cycleContaining(today, card.statementDay, card.paymentDueDay);
  return cycleContaining(addDays(currentCycle.start, -1), card.statementDay, card.paymentDueDay);
}

/** When the last statement's bill is due — known without reading any movements. */
export const lastStatementDueDate = (card: Pick<CardRow, 'statementDay' | 'paymentDueDay'>, today: IsoDate): IsoDate =>
  lastClosedCycle(card, today).dueDate;

export function lastStatement(card: CardRow, entries: readonly CardEntryRow[], today: IsoDate): LastStatement {
  const own = entries.filter((e) => e.cardId === card.id);
  const cycle = lastClosedCycle(card, today);

  let balance = toCents(card.openingOutstanding);
  let credited = 0;
  for (const entry of own) {
    const cents = toCents(entry.amount);
    if (entry.date <= cycle.end) balance += entry.direction === 'debit' ? cents : -cents;
    else if (entry.direction === 'credit') credited += cents;
  }
  const remainingCents = balance > 0 ? Math.max(0, balance - credited) : 0;
  let status: LastStatement['status'];
  if (balance <= 0) status = 'nothingDue';
  else if (remainingCents <= 0) status = 'paid';
  else status = today > cycle.dueDate ? 'overdue' : 'due';
  return { dueDate: cycle.dueDate, remainingCents, status };
}

export type CardDue = { cardId: string; name: string; dueDate: IsoDate };

/**
 * Cards whose bill is due tomorrow and still unpaid. A bill that is already
 * paid, or that is nothing, is not worth a reminder.
 */
export function cardsDueTomorrow(cards: readonly CardRow[], entries: readonly CardEntryRow[], today: IsoDate): CardDue[] {
  const tomorrow = addDays(today, 1);
  return cards.flatMap((card) => {
    const last = lastStatement(card, entries, today);
    return last.status === 'due' && last.dueDate === tomorrow ? [{ cardId: card.id, name: card.name, dueDate: last.dueDate }] : [];
  });
}
