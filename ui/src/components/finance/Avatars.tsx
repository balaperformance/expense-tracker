import type { CSSProperties } from 'react';

import { CategoryGlyph, Icon, type IconName } from '@/components/ui/Icon';
import { readableOn } from '@/lib/color';
import { useIsDark } from '@/hooks/useIsDark';

import styles from './Finance.module.css';

/** A category's icon on a wash of its own colour, lifted for dark mode. */
export function CategoryAvatar({ icon, color, size = 34 }: { icon: string | null | undefined; color: string | null | undefined; size?: number }) {
  const dark = useIsDark();
  const tint = readableOn(color, dark);
  return (
    <span className={styles.avatar} style={{ width: size, height: size, '--tone': tint } as CSSProperties} aria-hidden>
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

/** The bank's initial on the brand gradient. */
export function BankAvatar({ initial, size = 34 }: { initial: string; size?: number }) {
  return (
    <span className={styles.bankAvatar} style={{ width: size, height: size, fontSize: Math.round(size * 0.42) }} aria-hidden>
      {initial}
    </span>
  );
}
