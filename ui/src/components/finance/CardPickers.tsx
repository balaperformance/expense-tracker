import { Chip, ChipGroup, Segmented } from '@/components/ui/Chip';
import { Notice } from '@/components/ui/Feedback';
import type { IconName } from '@/components/ui/Icon';
import type { CardSummary } from '@/domain/creditCards';
import { cardLabel, type CreditCard } from '@/domain/models';
import { formatCurrency } from '@/lib/format';

/** What an expense is paid with: cash or a bank account, or a credit card. */
export type FundingMode = 'account' | 'card';

const FUNDING_OPTIONS: ReadonlyArray<{ value: FundingMode; label: string; icon: IconName }> = [
  { value: 'account', label: 'Cash or account', icon: 'bank' },
  { value: 'card', label: 'Credit card', icon: 'card' },
];

/** "Cash or account" / "Credit card": the first choice under "Paid from". */
export function FundingToggle({ value, onChange, disabled }: { value: FundingMode; onChange: (mode: FundingMode) => void; disabled?: boolean }) {
  return <Segmented label="Paid with" value={value} options={FUNDING_OPTIONS} onChange={onChange} disabled={disabled} />;
}

/** One chip per card. */
export function CardChips({
  cards,
  selectedId,
  onSelect,
  disabled,
  error,
}: {
  cards: readonly CreditCard[];
  selectedId: string | null;
  onSelect: (id: string) => void;
  disabled?: boolean;
  error?: boolean;
}) {
  return (
    <ChipGroup label="Credit card" error={error}>
      {cards.map((card) => (
        <Chip key={card.id} label={cardLabel(card)} icon="card" selected={selectedId === card.id} disabled={disabled} onClick={() => onSelect(card.id)} />
      ))}
    </ChipGroup>
  );
}

/**
 * The selected card's headroom, and a warning (never a block) when the amount
 * is more than it — a card can go over its limit. [alreadyCounted] is the part
 * of the amount already in the outstanding (the saved amount when editing a
 * purchase on this card).
 */
export function AvailableCredit({
  card,
  summary,
  amount,
  alreadyCounted = 0,
  currency,
}: {
  card: CreditCard;
  summary: CardSummary;
  amount: number | null;
  alreadyCounted?: number;
  currency: string;
}) {
  if (card.creditLimit <= 0) {
    return <p className="t-label-sm" style={{ paddingInline: 2 }}>Adds to the card's outstanding, not to any bank balance</p>;
  }
  const headroom = card.creditLimit - summary.outstanding + alreadyCounted;
  if (amount != null && amount > 0 && Math.round(amount * 100) > Math.round(headroom * 100)) {
    return (
      <Notice
        icon="warning"
        tone="var(--warning)"
        message={`That is more than the ${formatCurrency(Math.max(headroom, 0), currency)} of credit left on this card. It is still recorded — the card will show as over its limit.`}
      />
    );
  }
  return (
    <p className="t-label-sm" style={{ paddingInline: 2 }}>
      {formatCurrency(Math.max(headroom, 0), currency)} available · adds to the card's outstanding, not to any bank balance
    </p>
  );
}
