/**
 * Moving money between two accounts the user already owns.
 * Port of `models/money_transfer.dart`.
 *
 * A transfer writes two ledger rows and nothing else — never an expense or an
 * income row — which is why it cannot reach the Dashboard, Reports, budgets
 * or any spending figure.
 */
import { MAX_AMOUNT } from '@/lib/validators';

export type TransferProblem =
  | 'noSource'
  | 'noDestination'
  | 'sameAccount'
  | 'invalidAmount'
  | 'amountTooLarge'
  | 'insufficientFunds';

export function transferProblemMessage(
  problem: TransferProblem,
  { sourceLabel, availableText }: { sourceLabel?: string; availableText?: string } = {},
): string {
  switch (problem) {
    case 'noSource':
      return 'Choose the account to transfer from.';
    case 'noDestination':
      return 'Choose the account to transfer to.';
    case 'sameAccount':
      return 'Pick two different accounts. Money cannot move to the account it came from.';
    case 'invalidAmount':
      return 'Enter an amount greater than 0.';
    case 'amountTooLarge':
      return 'That amount is too large.';
    case 'insufficientFunds':
      return availableText == null
        ? `Not enough money in ${sourceLabel ?? 'that account'}.`
        : `${sourceLabel ?? 'That account'} only has ${availableText} available.`;
  }
}

export type TransferDraft = {
  fromAccountId: string | null;
  toAccountId: string | null;
  amount: number | null;
  date: string;
  note?: string | null;
};

const cents = (value: number) => Math.round(value * 100);

/**
 * Validates a transfer. [availableBalance] is compared in whole cents: amounts
 * are `numeric(14,2)`, and a float comparison could otherwise reject a
 * transfer of exactly the full balance. Pass null to check only the rules
 * that need no balance.
 */
export function checkTransfer(draft: TransferDraft, availableBalance: number | null): TransferProblem | null {
  const { fromAccountId: from, toAccountId: to, amount } = draft;
  if (!from) return 'noSource';
  if (!to) return 'noDestination';
  if (from === to) return 'sameAccount';
  if (amount == null || Number.isNaN(amount) || amount <= 0) return 'invalidAmount';
  if (amount > MAX_AMOUNT) return 'amountTooLarge';
  if (availableBalance != null && Number.isFinite(availableBalance) && cents(amount) > cents(availableBalance)) {
    return 'insufficientFunds';
  }
  return null;
}

/**
 * The description stored on each leg: the user's note when they wrote one,
 * otherwise the leg describes itself so it still reads correctly if the other
 * account is later deleted.
 */
export function transferDescription({
  note,
  isOutgoing,
  counterpartyLabel,
}: {
  note: string | null | undefined;
  isOutgoing: boolean;
  counterpartyLabel: string;
}): string {
  const text = note?.trim();
  if (text) return text;
  return isOutgoing ? `Transfer to ${counterpartyLabel}` : `Transfer from ${counterpartyLabel}`;
}
