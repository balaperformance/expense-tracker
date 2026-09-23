/**
 * Provider-neutral conversation types.
 *
 * The agent loop, the tools and the tests speak only these. Each provider
 * adapter translates to and from its own wire format, which is what lets the
 * chain hand a half-finished conversation from Gemini to Groq.
 */

/** JSON Schema subset every provider accepts for tool parameters. */
export type JsonSchema = {
  type: "object" | "string" | "number" | "integer" | "boolean";
  description?: string;
  properties?: Record<string, JsonSchema>;
  required?: string[];
  enum?: string[];
  /** Validation-only keywords. Stripped before reaching a provider. */
  maxLength?: number;
  minimum?: number;
  maximum?: number;
  pattern?: string;
};

export type ToolSpec = {
  name: string;
  description: string;
  parameters: JsonSchema;
};

export type ToolCall = {
  /** Provider-issued id, or a synthetic one when the provider has none. */
  id: string;
  name: string;
  args: Record<string, unknown>;
  /** Set when the provider's arguments could not be parsed as JSON. The call
   * still flows through the loop so the model is told what went wrong. */
  malformedReason?: string;
};

export type UserMessage = { role: "user"; content: string };

export type AssistantMessage = {
  role: "assistant";
  content: string;
  toolCalls?: ToolCall[];
  /**
   * Opaque per-provider data needed to replay this turn faithfully. Gemini
   * attaches thought signatures to its parts and rejects a follow-up that
   * drops them, so the adapter keeps the raw content here. Another provider
   * simply ignores it.
   */
  providerMeta?: Record<string, unknown>;
};

export type ToolMessage = {
  role: "tool";
  toolCallId: string;
  name: string;
  /** JSON text. Already truncated to LIMITS.maxToolResultChars. */
  content: string;
};

export type ChatMessage = UserMessage | AssistantMessage | ToolMessage;

export type CompletionRequest = {
  system: string;
  messages: ChatMessage[];
  tools: ToolSpec[];
  /** "none" forces a text answer, used for the final turn after the tool
   * budget is spent. */
  toolChoice: "auto" | "none";
  signal: AbortSignal;
};

export type Completion = {
  text: string;
  toolCalls: ToolCall[];
  providerMeta?: Record<string, unknown>;
};

/** History turn as the client is allowed to send it: text only. */
export type HistoryTurn = { role: "user" | "assistant"; content: string };
