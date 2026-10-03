import type { ProviderChain } from "../providers/provider.ts";
import type { PendingAction, ToolContext } from "../tools/common.ts";
import { executeTool, isWriteTool, serialiseOutcome, toolSpecs } from "../tools/registry.ts";
import { LIMITS } from "./limits.ts";
import type { ChatMessage, HistoryTurn, ToolCall } from "./messages.ts";

export type AgentInput = {
  chain: ProviderChain;
  system: string;
  history: HistoryTurn[];
  message: string;
  ctx: ToolContext;
  signal: AbortSignal;
  onToolError?: (tool: string, error: unknown) => void;
};

export type AgentOutput = {
  reply: string;
  pendingAction: PendingAction | null;
  provider: string | null;
  toolCallsMade: number;
};

const NO_ANSWER = "I couldn't work that out. Could you rephrase the question?";
const GAVE_UP = "I couldn't finish that. Try asking for one thing at a time.";

/**
 * The model → tool → model loop, bounded on every axis.
 *
 * The loop ends when the model answers in text, when the iteration budget is
 * spent (after which the model is asked once for a text-only answer), or when
 * the request deadline aborts it. Tool results are the only data the model
 * ever sees, and a write tool contributes a PendingAction to the response
 * rather than a side effect.
 */
export async function runAgent(input: AgentInput): Promise<AgentOutput> {
  const messages: ChatMessage[] = [
    ...input.history.map((turn): ChatMessage =>
      turn.role === "user"
        ? { role: "user", content: turn.content }
        : { role: "assistant", content: turn.content }
    ),
    { role: "user", content: input.message },
  ];

  const tools = toolSpecs();
  let pendingAction: PendingAction | null = null;
  let provider: string | null = null;
  let toolCallsMade = 0;

  for (let iteration = 0; iteration < LIMITS.maxToolIterations; iteration++) {
    const { completion, provider: used } = await input.chain.complete({
      system: input.system,
      messages,
      tools,
      toolChoice: "auto",
      signal: input.signal,
    });
    provider = used;

    if (completion.toolCalls.length === 0) {
      return {
        reply: completion.text || pendingAction?.summary || NO_ANSWER,
        pendingAction,
        provider,
        toolCallsMade,
      };
    }

    messages.push({
      role: "assistant",
      content: completion.text,
      toolCalls: completion.toolCalls,
      providerMeta: completion.providerMeta,
    });

    for (const call of completion.toolCalls) {
      toolCallsMade++;
      const result = await runOne(call, input, pendingAction);
      if (result.pendingAction) pendingAction = result.pendingAction;
      messages.push({
        role: "tool",
        toolCallId: call.id,
        name: call.name,
        content: result.serialised,
      });
    }
  }

  // Budget spent. One last, tool-free turn so the user still gets words.
  try {
    const { completion, provider: used } = await input.chain.complete({
      system: input.system,
      messages,
      tools,
      toolChoice: "none",
      signal: input.signal,
    });
    return {
      reply: completion.text || pendingAction?.summary || GAVE_UP,
      pendingAction,
      provider: used,
      toolCallsMade,
    };
  } catch {
    return { reply: pendingAction?.summary ?? GAVE_UP, pendingAction, provider, toolCallsMade };
  }
}

async function runOne(
  call: ToolCall,
  input: AgentInput,
  existing: PendingAction | null,
): Promise<{ serialised: string; pendingAction?: PendingAction }> {
  if (call.malformedReason) {
    return {
      serialised: serialiseOutcome({
        ok: false,
        error: `The tool call was malformed: ${call.malformedReason}. Try again with valid arguments.`,
      }),
    };
  }

  // One prepared action per user message. A second write in the same turn
  // would either be silently dropped or shown as two cards for one sentence;
  // telling the model to do them one at a time is the honest option.
  if (existing && isWriteTool(call.name)) {
    return {
      serialised: serialiseOutcome({
        ok: false,
        error: "Only one action can be prepared per message. Ask the user to confirm the " +
          "first one, then do this next.",
      }),
    };
  }

  const outcome = await executeTool(input.ctx, call.name, call.args, input.onToolError);
  return {
    serialised: serialiseOutcome(outcome),
    pendingAction: outcome.ok ? outcome.pendingAction : undefined,
  };
}
