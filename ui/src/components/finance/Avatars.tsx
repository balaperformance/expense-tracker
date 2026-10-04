import type { CSSProperties } from 'react';

import { CategoryGlyph, Icon, type IconName } from '@/components/ui/Icon';
import { readableOn } from '@/lib/color';
import { useIsDark } from '@/hooks/useIsDark';

import styles from './Finance.module.css';

/**
 * A category's icon on a wash of its own colour, lifted for dark mode. The
 * palette's --category-mute pulls it toward the muted ink (0% leaves it as is).
 */
export function CategoryAvatar({ icon, color, size = 34 }: { icon: string | null | undefined; color: string | null | undefined; size?: number }) {
  const dark = useIsDark();
  const tint = readableOn(color, dark);
  const tone = `color-mix(in srgb, ${tint} calc(100% - var(--category-mute)), var(--muted))`;
  return (
    <span className={styles.avatar} style={{ width: size, height: size, '--tone': tone } as CSSProperties} aria-hidden>
      <CategoryGlyph icon={icon} size={Math.round(size * 0.48)} />
    </span>
  );
}

function ToneAvatar({ icon, tone, size }: { icon: IconName; tone: string; size: number }) {
  return (
    <span className={styles.avatar} style={{ width: size, height: size, '--tone': tone } as CSSProperties} aria-hidden>
      <Icon name={icon} size={Math.round(size * 0.48)} />
    </span>
  );
}

export const IncomeAvatar = ({ size = 34 }: { size?: number }) => <ToneAvatar icon="moneyIn" tone="var(--income)" size={size} />;
export const TransferAvatar = ({ size = 34 }: { size?: number }) => <ToneAvatar icon="transfer" tone="var(--transfer)" size={size} />;
export const LedgerAvatar = ({ credit, size = 34 }: { credit: boolean; size?: number }) => (
  <ToneAvatar icon={credit ? 'moneyIn' : 'moneyOut'} tone={credit ? 'var(--income)' : 'var(--expense)'} size={size} />
);

/** Money lent, or money coming back against a loan or a paid-for purchase — owed, not income or spending. */
export const ClaimAvatar = ({ size = 34 }: { size?: number }) => <ToneAvatar icon="lend" tone="var(--transfer)" size={size} />;

/** A credit card: purchases and fees on it, or its row in a list. */
export const CardAvatar = ({ size = 34, tone = 'var(--accent)' }: { size?: number; tone?: string }) => (
  <ToneAvatar icon="card" tone={tone} size={size} />
);

/** A movement on a card statement that is not a purchase (those carry their category). */
export function CardMovementAvatar({ kind, fromAccount, size = 34 }: { kind: string; fromAccount?: boolean; size?: number }) {
  switch (kind) {
    case 'payment':
      return <ToneAvatar icon={fromAccount ? 'bank' : 'cash'} tone="var(--transfer)" size={size} />;
    case 'refund':
    case 'cashback':
      return <ToneAvatar icon="moneyIn" tone="var(--income)" size={size} />;
    case 'fee':
    case 'interest':
      return <ToneAvatar icon="moneyOut" tone="var(--expense)" size={size} />;
    default:
      return <ToneAvatar icon="edit" tone="var(--muted)" size={size} />;
  }
}

/** The bank's initial on the brand gradient. */
export function BankAvatar({ initial, size = 34 }: { initial: string; size?: number }) {
  return (
    <span className={styles.bankAvatar} style={{ width: size, height: size, fontSize: Math.round(size * 0.42) }} aria-hidden>
      {initial}
    </span>
  );
}
