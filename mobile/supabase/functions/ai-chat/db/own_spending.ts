import type {
  AccountRow,
  BudgetRow,
  Capabilities,
  CardPaymentRow,
  CardRow,
  CategoryRow,
  DbPort,
  ExpenseRow,
  IncomeRow,
  LedgerRow,
  LedgerTotalRow,
  NewCardPayment,
  NewExpense,
  NewIncome,
  NewLedgerRow,
  PaymentMethodRow,
  TagKind,
  TagLinkRow,
  TagRow,
} from "./port.ts";

/**
 * The port as the tools see it: every expense read leaves out what is not
 * the user's spending, exactly as both apps do (`personalSpending` with the
 * paid-for / EMI / converted-purchase ids). Rows kept for someone else
 * (is_personal = false) are already left out by the adapter.
 *
 * One wrapper instead of a filter in each tool, so no read can forget it and
 * a figure the assistant quotes is the figure the screen shows. The list is
 * read once per request.
 */
export class OwnSpendingDb implements DbPort {
  private excluded: Promise<ReadonlySet<string>> | null = null;

  constructor(private readonly db: DbPort) {}

  private excludedIds(userId: string): Promise<ReadonlySet<string>> {
    this.excluded ??= this.db.spendingExcludedExpenseIds(userId).then((ids) => new Set(ids));
    return this.excluded;
  }

  private async own(userId: string, rows: Promise<ExpenseRow[]>): Promise<ExpenseRow[]> {
    const [list, excluded] = await Promise.all([rows, this.excludedIds(userId)]);
    return excluded.size === 0 ? list : list.filter((e) => !excluded.has(e.id));
  }

  expensesInRange(userId: string, fromInclusive: string, toExclusive: string, limit: number): Promise<ExpenseRow[]> {
    return this.own(userId, this.db.expensesInRange(userId, fromInclusive, toExclusive, limit));
  }

  recentExpenses(userId: string, limit: number): Promise<ExpenseRow[]> {
    return this.own(userId, this.db.recentExpenses(userId, limit));
  }

  expensesByIds(userId: string, ids: string[], fromInclusive: string | null, toExclusive: string | null): Promise<ExpenseRow[]> {
    return this.own(userId, this.db.expensesByIds(userId, ids, fromInclusive, toExclusive));
  }

  // Everything else passes straight through.
  capabilities(): Promise<Capabilities> {
    return this.db.capabilities();
  }
  profileCurrency(userId: string): Promise<string | null> {
    return this.db.profileCurrency(userId);
  }
  listCategories(userId: string): Promise<CategoryRow[]> {
    return this.db.listCategories(userId);
  }
  listPaymentMethods(userId: string): Promise<PaymentMethodRow[]> {
    return this.db.listPaymentMethods(userId);
  }
  listAccounts(userId: string): Promise<AccountRow[]> {
    return this.db.listAccounts(userId);
  }
  ledgerTotals(userId: string): Promise<LedgerTotalRow[]> {
    return this.db.ledgerTotals(userId);
  }
  incomeInRange(userId: string, fromInclusive: string, toExclusive: string, limit: number): Promise<IncomeRow[]> {
    return this.db.incomeInRange(userId, fromInclusive, toExclusive, limit);
  }
  recentIncome(userId: string, limit: number): Promise<IncomeRow[]> {
    return this.db.recentIncome(userId, limit);
  }
  ledgerForAccount(
    userId: string,
    accountId: string,
    fromInclusive: string | null,
    toExclusive: string | null,
    limit: number,
  ): Promise<LedgerRow[]> {
    return this.db.ledgerForAccount(userId, accountId, fromInclusive, toExclusive, limit);
  }
  ledgerNet(userId: string, accountId: string, before: string | null): Promise<number> {
    return this.db.ledgerNet(userId, accountId, before);
  }
  budgetsForMonth(userId: string, monthFirstDay: string): Promise<BudgetRow[]> {
    return this.db.budgetsForMonth(userId, monthFirstDay);
  }
  listTags(userId: string): Promise<TagRow[]> {
    return this.db.listTags(userId);
  }
  tagLinks(userId: string, kind: TagKind, tagIds: string[] | null): Promise<TagLinkRow[]> {
    return this.db.tagLinks(userId, kind, tagIds);
  }
  incomeByIds(userId: string, ids: string[], fromInclusive: string | null, toExclusive: string | null): Promise<IncomeRow[]> {
    return this.db.incomeByIds(userId, ids, fromInclusive, toExclusive);
  }
  spendingExcludedExpenseIds(userId: string): Promise<string[]> {
    return this.excludedIds(userId).then((ids) => [...ids]);
  }
  listCards(userId: string): Promise<CardRow[]> {
    return this.db.listCards(userId);
  }
  cardPaymentsBetween(userId: string, cardId: string, fromInclusive: string, toInclusive: string): Promise<CardPaymentRow[]> {
    return this.db.cardPaymentsBetween(userId, cardId, fromInclusive, toInclusive);
  }
  recordCardPayment(userId: string, payment: NewCardPayment): Promise<{ id: string }> {
    return this.db.recordCardPayment(userId, payment);
  }
  insertExpense(userId: string, row: NewExpense): Promise<{ id: string }> {
    return this.db.insertExpense(userId, row);
  }
  insertIncome(userId: string, row: NewIncome): Promise<{ id: string }> {
    return this.db.insertIncome(userId, row);
  }
  insertLedgerRows(userId: string, rows: NewLedgerRow[]): Promise<void> {
    return this.db.insertLedgerRows(userId, rows);
  }
}
