import { useEffect, useState } from 'react';
import { useNavigate } from 'react-router';

import { Page } from '@/components/layout/Page';
import { AccountChips, CategoryChips } from '@/components/finance/Pickers';
import { Button } from '@/components/ui/Button';
import { Badge, InlineError, Notice } from '@/components/ui/Feedback';
import { AmountField, DateField, FieldLabel, TextArea, TextField } from '@/components/ui/Fields';
import { Icon } from '@/components/ui/Icon';
import { Card } from '@/components/ui/Surface';
import { accountLabel, expenseTitle, type Expense } from '@/domain/models';
import type { ParsedBankSms } from '@/domain/sms/bankSmsParser';
import { describeUnmatchedAccount, smsReferenceNote, type SmsCategorySource, type SmsExpenseDraft } from '@/domain/sms/smsDraft';
import { useAccounts, useCapabilities, useCategories } from '@/hooks/data';
import { useDebounced } from '@/hooks/useDebounced';
import { useSaveExpense } from '@/hooks/mutations';
import { errorMessage } from '@/lib/errors';
import { dayMonthYear, formatCurrency } from '@/lib/format';
import { amountToInput, parseAmount } from '@/lib/validators';
import { findPossibleDuplicate } from '@/services/expenses';
import { useUserId } from '@/state/auth';
import { useFeedback } from '@/state/feedback';
import { useSettings } from '@/state/settings';

import styles from '../expenses/Expenses.module.css';

function categoryHint(source: SmsCategorySource, reason: string | null): string | null {
  switch (source) {
    case 'keyword':
      return reason ? `Suggested, ${reason}` : null;
    case 'assistant':
      return 'Suggested by the assistant';
    case 'fallback':
      return 'Not recognised — change if you can';
    default:
      return null;
  }
}

/**
 * Nothing is written until the user confirms (SmsReviewScreen). A likely
 * duplicate is a warning the user can override, never a refusal.
 */
export function SmsReview({ sms, draft, onBack }: { sms: ParsedBankSms; draft: SmsExpenseDraft; onBack: () => void }) {
  const navigate = useNavigate();
  const userId = useUserId();
  const { symbol, currency } = useSettings();
  const { toast } = useFeedback();
  const caps = useCapabilities();
  const categories = useCategories().data ?? [];
  const accounts = (useAccounts().data ?? []).map((b) => b.account);
  const save = useSaveExpense();

  const [amount, setAmount] = useState(amountToInput(draft.amount));
  const [merchant, setMerchant] = useState(draft.merchant ?? '');
  const [description, setDescription] = useState(draft.merchant != null ? '' : (sms.bankName ?? ''));
  const [date, setDate] = useState(draft.date);
  const [categoryId, setCategoryId] = useState(draft.categoryId);
  const [bankAccountId, setBankAccountId] = useState(draft.bankAccountId);
  const [source, setSource] = useState<SmsCategorySource>(draft.categorySource);
  const [submitted, setSubmitted] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [duplicate, setDuplicate] = useState<Expense | null>(null);
  const [checking, setChecking] = useState(true);
  const [accepted, setAccepted] = useState(false);

  const settledAmount = useDebounced(amount, 450);
  useEffect(() => {
    const value = parseAmount(settledAmount);
    // A later edit supersedes this lookup; its answer must not land.
    const run = { current: true };
    void (async () => {
      setChecking(true);
      const found = value == null ? null : await findPossibleDuplicate({ userId, amount: value, date, reference: draft.reference, bankAccountId });
      if (!run.current) return;
      setDuplicate(found);
      setChecking(false);
      if (!found) setAccepted(false);
    })();
    return () => {
      run.current = false;
    };
  }, [settledAmount, date, bankAccountId, userId, draft.reference]);

  const warnDuplicate = duplicate != null && !accepted;
  const categoryMissing = submitted && categoryId == null;
  const missing = [sms.counterparty == null && 'payee', sms.date == null && 'date'].filter((x): x is string => Boolean(x));
  const overridden = bankAccountId !== draft.bankAccountId;

  const submit = async () => {
    setSubmitted(true);
    setError(null);
    if (duplicate && !accepted) {
      setAccepted(true);
      return;
    }
    const value = parseAmount(amount);
    if (value == null || value <= 0) {
      setError('Enter the amount that was spent.');
      return;
    }
    if (categoryId == null) {
      setError('Choose a category for this expense.');
      return;
    }
    try {
      await save.mutateAsync({
        draft: {
          amount: value,
          expenseDate: date,
          categoryId,
          paymentMethodId: null,
          bankAccountId,
          merchant,
          description,
          notes: draft.reference ? smsReferenceNote(draft.reference) : null,
        },
      });
      toast('success', 'Expense added');
      void navigate('/expenses', { replace: true });
    } catch (failure) {
      setError(errorMessage(failure, 'Could not save the expense.'));
    }
  };

  return (
    <Page
      title="Review transaction"
      narrow
      actions={<Button label="Back" variant="ghost" size="sm" onClick={onBack} disabled={save.isPending} />}
      bar={
        <>
          <Button label="Cancel" variant="secondary" size="lg" disabled={save.isPending} onClick={onBack} />
          <Button
            label={warnDuplicate ? 'Add anyway' : 'Add expense'}
            size="lg"
            busy={save.isPending}
            busyLabel="Saving…"
            onClick={() => void submit()}
          />
        </>
      }
    >
      {missing.length ? (
        <Notice
          icon="factCheck"
          tone="var(--warning)"
          message={
            missing.length === 1
              ? `The message did not state a ${missing[0] ?? ''}. Check it below before adding.`
              : `The message did not state a ${missing.join(' or a ')}. Check them below before adding.`
          }
        />
      ) : (
        <Notice icon="checkCircle" tone="var(--income)" message="Read the amount, account, payee and date. Nothing is saved until you confirm." />
      )}

      {duplicate ? (
        <Notice
          icon="copy"
          tone="var(--warning)"
          message={
            draft.reference
              ? `This message has already been added: ${formatCurrency(duplicate.amount, currency)} · ${expenseTitle(duplicate)} on ${dayMonthYear(duplicate.expenseDate)}.`
              : `An expense of ${formatCurrency(duplicate.amount, currency)} from the same account on ${dayMonthYear(duplicate.expenseDate)} is already recorded. Add it again only if you really paid twice.`
          }
        />
      ) : null}

      <div>
        <FieldLabel text="Amount" required />
        <AmountField value={amount} onChange={setAmount} symbol={symbol} tone="var(--expense)" disabled={save.isPending} />
      </div>

      <div>
        <FieldLabel text="Paid from" required hint={bankAccountId == null ? 'No balance affected' : null} />
        {!caps.bankAccounts ? (
          <Notice message="Bank accounts are not set up, so this is recorded as cash and no balance changes." />
        ) : (
          <div className="stack gap-sm">
            {overridden ? (
              <Notice icon="edit" message="Using the account you picked." />
            ) : draft.accountMatch ? (
              <Notice
                icon={draft.accountMatch.strength === 'exact' ? 'verified' : 'info'}
                tone={draft.accountMatch.strength === 'exact' ? 'var(--income)' : undefined}
                message={`Matched ${accountLabel(draft.accountMatch.account)} by ${draft.accountMatch.reason}.`}
              />
            ) : (
              <Notice
                icon="help"
                tone="var(--warning)"
                message={`${describeUnmatchedAccount(sms)} is not one of your accounts. Pick the right one below — none will be created for you.`}
              />
            )}
            {accounts.length ? (
              <AccountChips accounts={accounts} selectedId={bankAccountId} onSelect={setBankAccountId} disabled={save.isPending} fullLabels />
            ) : (
              <Notice message="No bank accounts yet. This will be recorded as cash, which leaves every balance untouched." />
            )}
          </div>
        )}
      </div>

      <div>
        <FieldLabel text="Merchant" />
        <TextField value={merchant} onChange={setMerchant} placeholder="Who you paid" aria-label="Merchant" icon="store" autoCapitalize="words" disabled={save.isPending} />
      </div>

      <div>
        <FieldLabel
          text="Category"
          required
          hint={categoryMissing ? 'Pick one' : categoryHint(source, source === draft.categorySource ? draft.categoryReason : null)}
          hintIsError={categoryMissing}
        />
        <CategoryChips
          categories={categories}
          isSelected={(id) => id === categoryId}
          onToggle={(id) => {
            setCategoryId(id);
            setSource('user');
          }}
          disabled={save.isPending}
          error={categoryMissing}
          emptyMessage="No categories yet. Add one from Settings › Categories before importing a message."
        />
      </div>

      <div>
        <FieldLabel text="Date" required hint={sms.date == null ? 'Not in the message' : null} />
        <DateField value={date} onChange={setDate} disabled={save.isPending} />
      </div>

      <div>
        <FieldLabel text="Description" hint="Optional" />
        <TextArea value={description} onChange={setDescription} placeholder="What this was for" aria-label="Description" icon="text" disabled={save.isPending} />
      </div>

      {draft.reference ? (
        <Card padding="flush">
          <div className={styles.reference}>
            <Icon name="tag" size={16} color="var(--muted)" />
            <div className="grow stack">
              <span className="t-label-md">Reference</span>
              <span className="t-body-sm t-ellipsis">{draft.reference}</span>
            </div>
            <Badge label="Saved in notes" />
          </div>
        </Card>
      ) : null}

      {sms.availableBalance != null ? (
        <Notice
          icon="walletOutline"
          message={`Your bank quoted a balance of ${formatCurrency(sms.availableBalance, currency)} in this message. It is shown for checking only and is not saved.`}
        />
      ) : null}

      {error ? <InlineError message={error} /> : null}
      {checking ? <p className="t-label-sm">Checking for a matching expense…</p> : null}
    </Page>
  );
}
