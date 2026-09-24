import { useEffect, useLayoutEffect, useRef, useState, type KeyboardEvent } from 'react';

import { Page } from '@/components/layout/Page';
import { Button, IconButton } from '@/components/ui/Button';
import { Badge, InlineError, Notice } from '@/components/ui/Feedback';
import { Icon, type IconName } from '@/components/ui/Icon';
import { Card, IconWell, SectionHeader } from '@/components/ui/Surface';
import {
  actionKindLabel,
  MAX_MESSAGE_CHARS,
  SUGGESTED_ACTIONS,
  SUGGESTED_QUESTIONS,
  type ChatMessage,
  type PendingActionState,
} from '@/domain/aiChat';
import { useAiChat } from '@/state/aiChat';

import styles from './Assistant.module.css';

/** The assistant (AiChatScreen): answers from the user's own records; writes only on confirm. */
export function AssistantPage() {
  const chat = useAiChat();
  const [input, setInput] = useState('');
  const field = useRef<HTMLTextAreaElement>(null);
  const end = useRef<HTMLDivElement>(null);

  // Keep the newest message in view.
  useEffect(() => {
    end.current?.scrollIntoView({ behavior: 'smooth', block: 'end' });
  }, [chat.messages.length, chat.busy]);

  // The composer grows with its text, up to four lines.
  useLayoutEffect(() => {
    const node = field.current;
    if (!node) return;
    node.style.height = 'auto';
    node.style.height = `${Math.min(node.scrollHeight, 132)}px`;
  }, [input]);

  const canSend = !chat.busy && input.trim().length > 0 && input.length <= MAX_MESSAGE_CHARS;

  const send = async (text: string) => {
    const accepted = await chat.send(text);
    if (accepted) setInput('');
  };

  const fill = (text: string) => {
    setInput(text);
    requestAnimationFrame(() => {
      const node = field.current;
      if (!node) return;
      node.focus();
      node.setSelectionRange(text.length, text.length);
    });
  };

  const onKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    // Enter sends on a keyboard; Shift+Enter (and the phone's return key) adds a line.
    if (event.key === 'Enter' && !event.shiftKey && window.matchMedia('(pointer: fine)').matches) {
      event.preventDefault();
      if (canSend) void send(input);
    }
  };

  return (
    <Page
      title="Assistant"
      back="/"
      narrow
      actions={chat.messages.length ? <IconButton icon="newChat" label="New conversation" disabled={chat.busy} onClick={chat.clear} /> : null}
    >
      <div className={styles.screen}>
        {!chat.messages.length ? (
          <Welcome onAsk={(q) => void send(q)} onFill={fill} />
        ) : (
          chat.messages.map((message) =>
            message.role === 'user' ? (
              <UserBubble key={message.id} message={message} onRetry={chat.lastFailedText === message.text ? () => void chat.retryLast() : undefined} />
            ) : (
              <div key={message.id} className={styles.assistantRow}>
                <IconWell icon="assistantSolid" size={26} />
                {message.pendingAction ? (
                  <ActionCard message={message} onConfirm={() => void chat.confirm(message.id)} onCancel={() => chat.cancel(message.id)} />
                ) : (
                  <div className={styles.assistantBubble}>{message.text}</div>
                )}
              </div>
            ),
          )
        )}
        {chat.busy ? (
          <div className={styles.assistantRow}>
            <IconWell icon="assistantSolid" size={26} />
            <span className={styles.typing} aria-label="The assistant is typing">
              <span />
              <span />
              <span />
            </span>
          </div>
        ) : null}
        <div ref={end} />
      </div>

      <div className={styles.composer}>
        <div className={styles.composerInner}>
          <textarea
            ref={field}
            className={styles.input}
            value={input}
            onChange={(e) => setInput(e.target.value.slice(0, MAX_MESSAGE_CHARS))}
            onKeyDown={onKeyDown}
            rows={1}
            placeholder="Ask or tell me what to record…"
            aria-label="Message the assistant"
            enterKeyHint="send"
            disabled={chat.busy}
          />
          <button type="button" className={styles.send} aria-label="Send" disabled={!canSend} onClick={() => void send(input)}>
            <Icon name="send" size={21} />
          </button>
        </div>
      </div>
    </Page>
  );
}

function Welcome({ onAsk, onFill }: { onAsk: (question: string) => void; onFill: (text: string) => void }) {
  return (
    <div className={styles.welcome}>
      <div className={styles.intro}>
        <IconWell icon="assistantSolid" size={34} />
        <div className="stack gap-xs">
          <span className="t-title-md">Ask about your money</span>
          <span className="t-body-sm">Totals, balances, budgets — or tell me what to record.</span>
        </div>
      </div>
      <div>
        <SectionHeader title="Ask" />
        <div className={styles.suggestions}>
          {SUGGESTED_QUESTIONS.map((question) => (
            <button key={question} type="button" className={styles.suggestion} onClick={() => onAsk(question)}>
              {question}
            </button>
          ))}
        </div>
      </div>
      <div>
        <SectionHeader title="Record" />
        <div className={styles.suggestions}>
          {SUGGESTED_ACTIONS.map((action) => (
            <button key={action} type="button" className={styles.suggestion} onClick={() => onFill(action)}>
              <Icon name="edit" size={16} />
              {action}
            </button>
          ))}
        </div>
      </div>
      <Notice
        icon="shield"
        message="Answers are worked out from your own records, never estimated. Anything to be recorded is shown to you first and saved only when you confirm."
      />
    </div>
  );
}

function UserBubble({ message, onRetry }: { message: ChatMessage; onRetry?: () => void }) {
  const failed = message.status === 'failed';
  return (
    <div className={styles.userRow}>
      <div className={[styles.userBubble, failed && styles.userBubbleFailed].filter(Boolean).join(' ')}>{message.text}</div>
      {failed ? (
        <div className={styles.failure}>
          <span>{message.error ?? 'Not sent'}</span>
          {onRetry ? <Button label="Retry" icon="refresh" variant="ghost" size="sm" onClick={onRetry} /> : null}
        </div>
      ) : null}
    </div>
  );
}

const STATE_BADGE: Record<PendingActionState, { label: string; icon?: IconName; tone?: string }> = {
  pending: { label: 'Needs confirmation' },
  confirming: { label: 'Needs confirmation' },
  confirmed: { label: 'Saved', icon: 'check', tone: 'var(--income)' },
  cancelled: { label: 'Cancelled' },
  failed: { label: 'Not saved', tone: 'var(--error)' },
};

function ActionCard({ message, onConfirm, onCancel }: { message: ChatMessage; onConfirm: () => void; onCancel: () => void }) {
  const action = message.pendingAction;
  if (!action) return null;
  const [icon, tone]: [IconName, string] =
    action.tool === 'transfer_money'
      ? ['transfer', 'var(--transfer)']
      : action.tool === 'create_income'
        ? ['incomeAdd', 'var(--income)']
        : ['expense', 'var(--expense)'];
  const state = message.actionState;
  const badge = STATE_BADGE[state];
  return (
    <div className={styles.card}>
      <Card>
        <div className={styles.cardHead}>
          <IconWell icon={icon} tone={tone} size={30} />
          <span className="grow t-label-md">{actionKindLabel(action.tool)}</span>
          <Badge label={badge.label} icon={badge.icon} tone={badge.tone} />
        </div>
        <p className="t-title-md" style={{ lineHeight: 1.4 }}>
          {action.summary}
        </p>
        {message.actionError ? (
          <div style={{ marginTop: 'var(--sp-sm)' }}>
            <InlineError message={message.actionError} />
          </div>
        ) : null}
        {state === 'pending' || state === 'confirming' ? (
          <div className={styles.cardActions}>
            <Button label="Cancel" variant="ghost" onClick={onCancel} disabled={state === 'confirming'} />
            <Button label="Confirm" busy={state === 'confirming'} onClick={onConfirm} />
          </div>
        ) : null}
      </Card>
    </div>
  );
}
