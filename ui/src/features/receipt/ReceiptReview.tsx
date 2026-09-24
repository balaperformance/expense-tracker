import { useState } from 'react';

import { Page } from '@/components/layout/Page';
import { Money } from '@/components/finance/Money';
import { CategoryChips, PaymentMethodChips } from '@/components/finance/Pickers';
import { Button } from '@/components/ui/Button';
import { Badge, Notice } from '@/components/ui/Feedback';
import { AmountField, DateField, FieldLabel, TextArea, TextField } from '@/components/ui/Fields';
import { Card, SectionHeader } from '@/components/ui/Surface';
import { receiptPrefill, type ExpensePrefill } from '@/domain/prefill';
import { CONFIDENCE_LABEL, fieldsToVerify, hasUsableTotal, type ReceiptConfidence, type ReceiptResult } from '@/domain/receipt/result';
import { useCategories, usePaymentMethods } from '@/hooks/data';
import { today } from '@/lib/dates';
import { amountToInput, parseAmount } from '@/lib/validators';
import { useSettings } from '@/state/settings';

function ConfidencePill({ confidence }: { confidence: ReceiptConfidence }) {
  if (confidence === 'high') return null;
  return (
    <Badge
      label={CONFIDENCE_LABEL[confidence]}
      icon={confidence === 'none' ? 'close' : 'help'}
      tone={confidence === 'none' ? undefined : 'var(--warning)'}
    />
  );
}

const joinWords = (words: string[]) =>
  words.length <= 1 ? (words[0] ?? '') : `${words.slice(0, -1).join(', ')} and ${words[words.length - 1] ?? ''}`;

/** Check what the scan read before it fills the expense form (ReceiptReviewScreen). */
export function ReceiptReview({ result, onCancel, onContinue }: { result: ReceiptResult; onCancel: () => void; onContinue: (prefill: ExpensePrefill) => void }) {
  const { symbol, currency } = useSettings();
  const categories = useCategories().data ?? [];
  const methods = usePaymentMethods().data ?? [];
  const [seed] = useState(() => receiptPrefill(result, categories, methods));
  const [amount, setAmount] = useState(seed.prefill.amount == null ? '' : amountToInput(seed.prefill.amount));
  const [merchant, setMerchant] = useState(seed.prefill.merchant ?? '');
  const [description, setDescription] = useState(seed.prefill.description ?? '');
  const [date, setDate] = useState(seed.prefill.date ?? today());
  const [categoryId, setCategoryId] = useState<string | null>(seed.prefill.categoryId ?? null);
  const [categoryReason, setCategoryReason] = useState(seed.categoryReason);
  const [paymentMethodId, setPaymentMethodId] = useState<string | null>(seed.prefill.paymentMethodId ?? null);
  const [touched, setTouched] = useState(false);

  const parsed = parseAmount(amount);
  const amountReady = parsed != null && parsed > 0;
  const unsure = fieldsToVerify(result);

  const submit = () => {
    if (!amountReady) {
      setTouched(true);
      return;
    }
    onContinue({
      amount: parsed,
      merchant: merchant.trim() || null,
      date,
      description: description.trim() || null,
      categoryId,
      paymentMethodId,
      source: 'receiptScan',
    });
  };

  return (
    <Page
      title="Check the receipt"
      actions={<Button label="Cancel" variant="ghost" size="sm" onClick={onCancel} />}
      narrow
      bar={<Button label="Continue" icon="arrowForward" size="lg" block disabled={!amountReady} onClick={submit} />}
    >
      {unsure.length ? (
        <Notice
          icon="factCheck"
          tone="var(--warning)"
          message={`Check the ${joinWords(unsure)} — the scan was not sure about ${unsure.length === 1 ? 'it' : 'them'}.`}
        />
      ) : (
        <Notice icon="checkCircle" tone="var(--income)" message="Read the amount, merchant and date. Check them and continue." />
      )}

      <div>
        <div className="row">
          <div className="grow">
            <FieldLabel text="Amount" required />
          </div>
          <ConfidencePill confidence={result.total.confidence} />
        </div>
        <AmountField
          value={amount}
          onChange={(v) => {
            setAmount(v);
            setTouched(true);
          }}
          symbol={symbol}
          tone="var(--expense)"
          autoFocus={!hasUsableTotal(result)}
          error={touched && !amountReady ? 'Enter the amount you paid.' : null}
        />
      </div>

      <div>
        <div className="row">
          <div className="grow">
            <FieldLabel text="Merchant" />
          </div>
          <ConfidencePill confidence={result.merchant.confidence} />
        </div>
        <TextField value={merchant} onChange={setMerchant} placeholder="Who you paid" aria-label="Merchant" icon="store" autoCapitalize="words" />
      </div>

      <div>
        <div className="row">
          <div className="grow">
            <FieldLabel text="Date" required />
          </div>
          <ConfidencePill confidence={result.date.confidence} />
        </div>
        <DateField value={date} onChange={setDate} />
      </div>

      <div>
        <FieldLabel text="Category" hint={categoryReason ? `Suggested, ${categoryReason}` : null} />
        <CategoryChips
          categories={categories}
          isSelected={(id) => id === categoryId}
          onToggle={(id) => {
            setCategoryId((current) => (current === id ? null : id));
            setCategoryReason(null);
          }}
          emptyMessage="No categories yet. You can pick one on the next step."
        />
      </div>

      <div>
        <FieldLabel text="Description" hint="Optional" />
        <TextArea value={description} onChange={setDescription} placeholder="What this was for" aria-label="Description" icon="text" />
      </div>

      {methods.length ? (
        <div>
          <FieldLabel text="Payment method" hint="Optional" />
          <PaymentMethodChips methods={methods} selectedId={paymentMethodId} onSelect={setPaymentMethodId} />
        </div>
      ) : null}

      {result.lineItems.length ? (
        <div>
          <SectionHeader title="Items read" caption={`${result.lineItems.length} lines`} />
          <Card>
            <div className="stack gap-sm">
              {result.lineItems.map((item, i) => (
                <div key={i} className="row gap-sm t-body-md">
                  <span className="grow t-ellipsis">{item.quantity && item.quantity !== 1 ? `${item.quantity} x ${item.description}` : item.description}</span>
                  <Money amount={item.amount} currency={currency} />
                </div>
              ))}
            </div>
          </Card>
        </div>
      ) : null}
    </Page>
  );
}
