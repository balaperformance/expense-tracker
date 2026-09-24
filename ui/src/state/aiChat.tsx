/**
 * The conversation with the assistant. Port of `providers/ai_chat_provider.dart`.
 *
 * Held in memory for the session and nowhere else: the server keeps no
 * transcript, the database has no chat table, and sign-out drops it. Each
 * request carries only a short, text-only tail of the conversation.
 */
import { useQueryClient } from '@tanstack/react-query';
import { createContext, useCallback, useContext, useMemo, useRef, useState, type ReactNode } from 'react';

import {
  actionIsExpired,
  AiChatError,
  HISTORY_TURNS,
  isFinalFailure,
  MAX_MESSAGE_CHARS,
  type ChatMessage,
  type ChatRole,
} from '@/domain/aiChat';
import { uuidV4 } from '@/lib/id';
import { confirmAction, sendChat } from '@/services/aiChat';

import { invalidateFinance } from './queryClient';

type ChatApi = {
  messages: ChatMessage[];
  busy: boolean;
  lastFailedText: string | null;
  send: (raw: string) => Promise<boolean>;
  retryLast: () => Promise<boolean>;
  confirm: (messageId: string) => Promise<boolean>;
  cancel: (messageId: string) => void;
  clear: () => void;
  reset: () => void;
};

const ChatContext = createContext<ChatApi | null>(null);

const message = (role: ChatRole, text: string, extra: Partial<ChatMessage> = {}): ChatMessage => ({
  id: uuidV4(),
  role,
  text,
  status: 'sent',
  error: null,
  pendingAction: null,
  actionState: 'pending',
  actionError: null,
  ...extra,
});

/** The last few delivered turns as plain text. Failed sends and cards are not context. */
const historyOf = (transcript: readonly ChatMessage[]) =>
  transcript
    .filter((m) => !(m.role === 'user' && m.status !== 'sent') && m.text.trim())
    .map((m) => ({ role: m.role, content: m.text }))
    .slice(-HISTORY_TURNS);

const describe = (error: unknown) => (error instanceof AiChatError ? error.message : 'Something went wrong. Please try again.');

export function AiChatProvider({ children }: { children: ReactNode }) {
  const client = useQueryClient();
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [busy, setBusy] = useState(false);
  const [lastFailedText, setLastFailedText] = useState<string | null>(null);
  // A mirror of the transcript for building history synchronously.
  const transcript = useRef<ChatMessage[]>([]);
  const busyRef = useRef(false);

  const commit = useCallback((next: ChatMessage[]) => {
    transcript.current = next;
    setMessages(next);
  }, []);

  const replace = useCallback(
    (id: string, patch: Partial<ChatMessage>) => commit(transcript.current.map((m) => (m.id === id ? { ...m, ...patch } : m))),
    [commit],
  );

  const send = useCallback(
    async (raw: string) => {
      const text = raw.trim();
      if (!text || busyRef.current || text.length > MAX_MESSAGE_CHARS) return false;
      const previous = historyOf(transcript.current);
      const outgoing = message('user', text, { status: 'sending' });
      commit([...transcript.current, outgoing]);
      busyRef.current = true;
      setBusy(true);
      setLastFailedText(null);
      try {
        const reply = await sendChat(text, previous);
        replace(outgoing.id, { status: 'sent' });
        commit([...transcript.current, message('assistant', reply.reply, { pendingAction: reply.pendingAction })]);
        if (reply.dataChanged) void invalidateFinance(client);
        return true;
      } catch (error) {
        replace(outgoing.id, { status: 'failed', error: describe(error) });
        setLastFailedText(text);
        return false;
      } finally {
        busyRef.current = false;
        setBusy(false);
      }
    },
    [client, commit, replace],
  );

  const retryLast = useCallback(async () => {
    const text = lastFailedText;
    if (!text || busyRef.current) return false;
    commit(transcript.current.filter((m) => !(m.role === 'user' && m.status === 'failed' && m.text === text)));
    setLastFailedText(null);
    return send(text);
  }, [commit, lastFailedText, send]);

  const confirm = useCallback(
    async (messageId: string) => {
      const card = transcript.current.find((m) => m.id === messageId);
      const action = card?.pendingAction;
      if (!card || !action || card.actionState !== 'pending' || busyRef.current) return false;
      if (actionIsExpired(action, new Date())) {
        replace(messageId, { actionState: 'failed', actionError: 'That request has expired. Please ask again.' });
        return false;
      }
      replace(messageId, { actionState: 'confirming', actionError: null });
      busyRef.current = true;
      setBusy(true);
      try {
        const reply = await confirmAction(action);
        replace(messageId, { actionState: 'confirmed' });
        commit([...transcript.current, message('assistant', reply.reply)]);
        if (reply.dataChanged) void invalidateFinance(client);
        return true;
      } catch (error) {
        const failure = error instanceof AiChatError ? error : new AiChatError('unknown', 'Something went wrong. Please try again.');
        // A rejection is final; a transient failure leaves the card open.
        replace(messageId, { actionState: isFinalFailure(failure.kind) ? 'failed' : 'pending', actionError: failure.message });
        return false;
      } finally {
        busyRef.current = false;
        setBusy(false);
      }
    },
    [client, commit, replace],
  );

  const cancel = useCallback(
    (messageId: string) => {
      const card = transcript.current.find((m) => m.id === messageId);
      if (!card?.pendingAction || card.actionState !== 'pending') return;
      replace(messageId, { actionState: 'cancelled' });
      commit([...transcript.current, message('assistant', 'Okay, nothing was saved.')]);
    },
    [commit, replace],
  );

  const clear = useCallback(() => {
    if (busyRef.current) return;
    commit([]);
    setLastFailedText(null);
  }, [commit]);

  const reset = useCallback(() => {
    commit([]);
    setLastFailedText(null);
    busyRef.current = false;
    setBusy(false);
  }, [commit]);

  const api = useMemo(
    () => ({ messages, busy, lastFailedText, send, retryLast, confirm, cancel, clear, reset }),
    [messages, busy, lastFailedText, send, retryLast, confirm, cancel, clear, reset],
  );
  return <ChatContext.Provider value={api}>{children}</ChatContext.Provider>;
}

export function useAiChat(): ChatApi {
  const api = useContext(ChatContext);
  if (!api) throw new Error('useAiChat must be used inside AiChatProvider');
  return api;
}
