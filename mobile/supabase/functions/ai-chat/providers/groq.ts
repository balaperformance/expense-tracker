import { LIMITS } from "../core/limits.ts";
import type {
  ChatMessage,
  Completion,
  CompletionRequest,
  ToolCall,
} from "../core/messages.ts";
import { type FetchLike, postJson, providerSchema } from "./http.ts";
import { type AIProvider, ProviderError } from "./provider.ts";

/**
 * Groq via its OpenAI-compatible chat completions endpoint.
 *
 * `llama-3.3-70b-versatile` was retired in August 2026; the documented
 * replacement with tool use on the free tier is `openai/gpt-oss-120b`.
 * Like the Gemini id, `GROQ_MODEL` overrides this without a code change.
 */
export const DEFAULT_GROQ_MODEL = "openai/gpt-oss-120b";

const ENDPOINT = "https://api.groq.com/openai/v1/chat/completions";

type WireMessage =
  | { role: "system" | "user"; content: string }
  | {
    role: "assistant";
    content: string | null;
    tool_calls?: Array<{
      id: string;
      type: "function";
      function: { name: string; arguments: string };
    }>;
  }
  | { role: "tool"; tool_call_id: string; name: string; content: string };

export class GroqProvider implements AIProvider {
  readonly name = "groq";

  constructor(
    private readonly apiKey: string,
    readonly model: string = DEFAULT_GROQ_MODEL,
    private readonly fetchImpl: FetchLike = (input, init) => fetch(input, init),
  ) {}

  async complete(request: CompletionRequest): Promise<Completion> {
    const body: Record<string, unknown> = {
      model: this.model,
      messages: [
        { role: "system", content: request.system },
        ...toWire(request.messages),
      ],
      temperature: 0.2,
      max_tokens: 1024,
    };

    if (request.tools.length > 0) {
      body.tools = request.tools.map((tool) => ({
        type: "function",
        function: {
          name: tool.name,
          description: tool.description,
          parameters: providerSchema(tool.parameters as Record<string, unknown>),
        },
      }));
      body.tool_choice = request.toolChoice === "none" ? "none" : "auto";
    }

    const raw = await postJson(
      this.name,
      this.fetchImpl,
      ENDPOINT,
      { authorization: `Bearer ${this.apiKey}` },
      body,
      LIMITS.providerTimeoutMs,
      request.signal,
    );

    return parseResponse(this.name, raw);
  }
}

function toWire(messages: ChatMessage[]): WireMessage[] {
  return messages.map((message): WireMessage => {
    if (message.role === "user") {
      return { role: "user", content: message.content };
    }
    if (message.role === "assistant") {
      const calls = message.toolCalls ?? [];
      return {
        role: "assistant",
        content: message.content || (calls.length > 0 ? null : ""),
        ...(calls.length > 0
          ? {
            tool_calls: calls.map((call) => ({
              id: call.id,
              type: "function" as const,
              function: { name: call.name, arguments: JSON.stringify(call.args) },
            })),
          }
          : {}),
      };
    }
    return {
      role: "tool",
      tool_call_id: message.toolCallId,
      name: message.name,
      content: message.content,
    };
  });
}

function parseResponse(provider: string, raw: unknown): Completion {
  const data = raw as {
    choices?: Array<{
      message?: {
        content?: string | null;
        tool_calls?: Array<{
          id?: string;
          function?: { name?: string; arguments?: string };
        }>;
      };
    }>;
  };

  const message = data.choices?.[0]?.message;
  if (!message) throw new ProviderError(provider, "malformed_response", "no choices");

  const toolCalls: ToolCall[] = [];
  (message.tool_calls ?? []).forEach((call, index) => {
    const name = call.function?.name;
    if (typeof name !== "string" || name.length === 0) return;
    const id = call.id ?? `groq-${index}-${name}`;
    const rawArgs = call.function?.arguments ?? "{}";
    try {
      const parsed = rawArgs.trim() === "" ? {} : JSON.parse(rawArgs);
      toolCalls.push({
        id,
        name,
        args: typeof parsed === "object" && parsed !== null && !Array.isArray(parsed)
          ? parsed as Record<string, unknown>
          : {},
        ...(typeof parsed === "object" && parsed !== null && !Array.isArray(parsed)
          ? {}
          : { malformedReason: "arguments must be a JSON object" }),
      });
    } catch {
      // Handed to the loop rather than dropped, so the model hears that its
      // arguments were unreadable and can try again.
      toolCalls.push({ id, name, args: {}, malformedReason: "arguments were not valid JSON" });
    }
  });

  return {
    text: typeof message.content === "string" ? message.content.trim() : "",
    toolCalls,
  };
}
