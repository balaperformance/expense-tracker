/**
 * Conversation types for the AI assistant. Port of `models/ai_chat.dart`.
 * Everything here mirrors the `ai-chat` Edge Function's response contract:
 * the app never sees a model, a tool call or a database row.
 */

export type ChatRole = 'user' | 'assistant';
export type ChatMessageStatus = 'sending' | 'sent' | 'failed';
export type PendingActionState = 'pending' | 'confirming' | 'confirmed' | 'cancelled' | 'failed';

/** A write the server prepared; its args are opaque and re-verified on confirm. */
export type PendingAction = {
  id: string;
  tool: string;
  args: Record<string, unknown>;
  summary: string;
  expiresAt: string | null;
};

export const actionKindLabel = (tool: string) =>
  tool === 'create_expense' ? 'New expense' : tool === 'create_income' ? 'New income' : tool === 'transfer_money' ? 'Transfer' : 'Action';

export const actionIsExpired = (action: PendingAction, now: Date) =>
  action.expiresAt != null && now.getTime() > Date.parse(action.expiresAt);

export function parsePendingAction(json: unknown): PendingAction | null {
  if (typeof json !== 'object' || json === null) return null;
  const record = json as Record<string, unknown>;
  const { tool, summary, args, id, expires_at: expires } = record;
  if (typeof tool !== 'string' || typeof summary !== 'string' || typeof args !== 'object' || args === null) return null;
  return {
    id: typeof id === 'string' ? id : '',
    tool,
    args: args as Record<string, unknown>,
    summary,
    expiresAt: typeof expires === 'string' ? expires : null,
  };
}

export const pendingActionToJson = (action: PendingAction) => ({
  id: action.id,
  tool: action.tool,
  args: action.args,
  summary: action.summary,
  ...(action.expiresAt ? { expires_at: action.expiresAt } : {}),
});

export type ChatMessage = {
  id: string;
  role: ChatRole;
  text: string;
  status: ChatMessageStatus;
  error: string | null;
  pendingAction: PendingAction | null;
  actionState: PendingActionState;
  actionError: string | null;
};

export type AiChatReply = {
  reply: string;
  pendingAction: PendingAction | null;
  dataChanged: boolean;
};

export function parseReply(json: unknown): AiChatReply {
  if (typeof json !== 'object' || json === null || typeof (json as { reply?: unknown }).reply !== 'string') {
    throw new AiChatError('unknown', 'The assistant returned an unexpected response.');
  }
  const record = json as Record<string, unknown>;
  return {
    reply: record.reply as string,
    pendingAction: parsePendingAction(record.pending_action),
    dataChanged: record.data_changed === true,
  };
}

export type AiChatFailure =
  | 'unauthenticated'
  | 'rateLimited'
  | 'notConfigured'
  | 'unavailable'
  | 'rejected'
  | 'tooLong'
  | 'network'
  | 'unknown';

export class AiChatError extends Error {
  override readonly name = 'AiChatError';
  constructor(
    readonly kind: AiChatFailure,
    message: string,
    readonly retryAfterSeconds: number | null = null,
  ) {
    super(message);
  }
}

/** A rejection is final; a transient failure leaves the card open to retry. */
export const isFinalFailure = (kind: AiChatFailure) => kind === 'rejected' || kind === 'unauthenticated';

/** Longest message sent — matches the function's own limit. */
export const MAX_MESSAGE_CHARS = 1000;
/** Turns of text-only context sent with each message. */
export const HISTORY_TURNS = 10;
/** Longest merchant name sent to `classify`. */
export const MAX_MERCHANT_CHARS = 120;

export const SUGGESTED_QUESTIONS = [
  'What did I spend this month?',
  'Where am I spending the most?',
  'How much is left in my budget?',
  'What is my current bank balance?',
  'Show my recent expenses.',
];

/** Filled into the input rather than sent, so the amount is the user's. */
export const SUGGESTED_ACTIONS = ['Add ₹500 for shopping', 'Add ₹2,000 salary income', 'Transfer ₹1,000 from HDFC to SBI'];
