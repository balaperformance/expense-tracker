import { useState } from 'react';

import { Page } from '@/components/layout/Page';
import { Button } from '@/components/ui/Button';
import { Notice } from '@/components/ui/Feedback';
import { FieldLabel, TextArea } from '@/components/ui/Fields';
import { Icon } from '@/components/ui/Icon';
import { Card } from '@/components/ui/Surface';
import { MAX_SMS_CHARS, parseBankSms, smsIsUsable, type ParsedBankSms } from '@/domain/sms/bankSmsParser';
import { applyAssistantCategory, buildSmsDraft, shouldAskAssistant, type SmsExpenseDraft } from '@/domain/sms/smsDraft';
import { useAccounts, useCategories } from '@/hooks/data';
import { today } from '@/lib/dates';
import { suggestCategory } from '@/services/aiChat';

import styles from '../expenses/Expenses.module.css';

import { SmsReview } from './SmsReview';

const SAMPLE = 'Sent Rs.2900.00\nFrom HDFC Bank A/C *6459\nTo CHENNAI KEY MAKERS\nOn 19/09/26';

/** Paste a bank alert, read it on this device, then review it (PasteSmsScreen). */
export function PasteSmsPage() {
  const categories = useCategories().data ?? [];
  const accounts = (useAccounts().data ?? []).map((b) => b.account);
  const [text, setText] = useState('');
  const [problem, setProblem] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [parsed, setParsed] = useState<{ sms: ParsedBankSms; draft: SmsExpenseDraft; text: string } | null>(null);

  const change = (value: string) => {
    setText(value.slice(0, MAX_SMS_CHARS));
    setProblem(null);
  };

  const paste = async () => {
    try {
      const clip = await navigator.clipboard.readText();
      if (!clip.trim()) {
        setProblem('There is nothing to paste right now.');
        return;
      }
      change(clip);
    } catch {
      setProblem('Paste is blocked here. Long-press the box and choose Paste instead.');
    }
  };

  const parse = async () => {
    const sms = parseBankSms(text);
    if (!smsIsUsable(sms)) {
      setProblem('That does not look like a bank transaction message. Paste the whole alert, including the amount.');
      return;
    }
    if (sms.direction === 'credit') {
      setProblem('That message is money received, not money spent. Add it from the Income tab instead.');
      return;
    }
    setBusy(true);
    let draft = buildSmsDraft({ sms, accounts, categories, today: today() });
    // Only the payee name is ever sent, and only when the keywords found nothing.
    if (shouldAskAssistant(draft, categories) && draft.merchant) {
      draft = applyAssistantCategory(draft, categories, await suggestCategory(draft.merchant));
    }
    setBusy(false);
    setParsed({ sms, draft, text });
  };

  if (parsed) return <SmsReview sms={parsed.sms} draft={parsed.draft} text={parsed.text} onBack={() => setParsed(null)} />;

  return (
    <Page
      title="Paste bank SMS"
      back="/expenses/new"
      narrow
      bar={
        <Button
          label="Parse transaction"
          icon="autoFix"
          size="lg"
          block
          busy={busy}
          busyLabel="Reading…"
          disabled={!text.trim()}
          onClick={() => void parse()}
        />
      }
    >
      <div>
        <FieldLabel text="Message" required />
        <TextArea
          value={text}
          onChange={change}
          rows={6}
          placeholder="Paste the transaction alert from your bank"
          aria-label="Bank message"
          maxLength={MAX_SMS_CHARS}
          autoCapitalize="none"
          disabled={busy}
          autoFocus
        />
      </div>
      <div className="row gap-sm">
        <Button label="Paste" icon="paste" size="sm" variant="tonal" onClick={() => void paste()} disabled={busy} />
        <Button label="Clear" icon="backspace" size="sm" variant="ghost" onClick={() => change('')} disabled={busy || !text} />
      </div>
      {problem ? <Notice icon="error" tone="var(--error)" message={problem} /> : null}
      <Card padding="roomy">
        <div className="stack gap-md">
          <div className="row gap-sm">
            <Icon name="lightbulb" size={16} color="var(--primary)" />
            <span className="t-title-sm">Messages like this work</span>
          </div>
          <div className={styles.smsSample}>{SAMPLE}</div>
          <p className="t-body-sm">Debit alerts from most banks are understood, with or without a transaction id, a balance or a date.</p>
        </div>
      </Card>
      <Notice
        icon="lock"
        message="The message is read on this device and is not saved. If a category cannot be worked out here, only the payee name is sent to the assistant — never the amount, the account or the message itself."
      />
    </Page>
  );
}
