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
 * Gemini via the `generateContent` REST endpoint.
 *
 * The model id is configuration, not code: the free-tier line has been
 * renamed more than once, so `GEMINI_MODEL` decides which Flash model runs
 * and this file only knows the wire format.
 */
export const DEFAULT_GEMINI_MODEL = "gemini-3.8-flash";

const ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/models";

type GeminiPart = Record<string, unknown> & {
  text?: string;
  thought?: boolean;
  functionCall?: { name: string; args?: Record<string, unknown> };
};

type GeminiContent = { role: "user" | "model"; parts: GeminiPart[] };

export class GeminiProvider implements AIProvider {
  readonly name = "gemini";

  constructor(
    private readonly apiKey: string,
    readonly model: string = DEFAULT_GEMINI_MODEL,
    private readonly fetchImpl: FetchLike = (input, init) => fetch(input, init),
  ) {}

  async complete(request: CompletionRequest): Promise<Completion> {
    const body: Record<string, unknown> = {
      systemInstruction: { parts: [{ text: request.system }] },
      contents: toContents(request.messages),
      generationConfig: { temperature: 0.2, maxOutputTokens: 1024 },
    };

    if (request.tools.length > 0) {
      body.tools = [{
        functionDeclarations: request.tools.map((tool) => ({
          name: tool.name,
          description: tool.description,
          parameters: providerSchema(tool.parameters as Record<string, unknown>),
        })),
      }];
      body.toolConfig = {
        functionCallingConfig: {
          mode: request.toolChoice === "none" ? "NONE" : "AUTO",
        },
      };
    }

    const raw = await postJson(
      this.name,
      this.fetchImpl,
      `${ENDPOINT}/${encodeURIComponent(this.model)}:generateContent`,
      // Header rather than `?key=`: a query string ends up in access logs.
      { "x-goog-api-key": this.apiKey },
      body,
      LIMITS.providerTimeoutMs,
      request.signal,
    );

    return parseResponse(this.name, raw);
  }
}

/**
 * Neutral history → Gemini `contents`.
 *
 * An assistant turn that came from Gemini is replayed from its raw parts so
 * thought signatures survive the round trip. One that came from another
 * provider (after a fallback) is rebuilt from the neutral form.
 */
function toContents(messages: ChatMessage[]): GeminiContent[] {
  const out: GeminiContent[] = [];

  for (const message of messages) {
    if (message.role === "user") {
      out.push({ role: "user", parts: [{ text: message.content }] });
      continue;
    }

    if (message.role === "assistant") {
      const raw = message.providerMeta?.geminiContent as GeminiContent | undefined;
      if (raw && Array.isArray(raw.parts) && raw.parts.length > 0) {
        out.push(raw);
        continue;
      }
      const parts: GeminiPart[] = [];
      if (message.content) parts.push({ text: message.content });
      for (const call of message.toolCalls ?? []) {
        parts.push({ functionCall: { name: call.name, args: call.args } });
      }
      if (parts.length === 0) parts.push({ text: "" });
      out.push({ role: "model", parts });
      continue;
    }

    // Tool results. Consecutive ones belong to the same model turn and must
    // be sent together in a single user content.
    const part: GeminiPart = {
      functionResponse: {
        name: message.name,
        response: { result: safeParse(message.content) },
      },
    };
    const last = out[out.length - 1];
    if (last && last.role === "user" && last.parts.every((p) => "functionResponse" in p)) {
      last.parts.push(part);
    } else {
      out.push({ role: "user", parts: [part] });
    }
  }

  return out;
}

function parseResponse(provider: string, raw: unknown): Completion {
  const data = raw as {
    candidates?: Array<{ content?: GeminiContent; finishReason?: string }>;
    promptFeedback?: { blockReason?: string };
  };

  const candidate = data.candidates?.[0];
  if (!candidate) {
    if (data.promptFeedback?.blockReason) {
      // The model declined the prompt. Not an outage, so no fallback: the
      // user gets a plain answer rather than the same prompt sent elsewhere.
      return { text: "I can't help with that request.", toolCalls: [] };
    }
    throw new ProviderError(provider, "malformed_response", "no candidates");
  }

  const parts = candidate.content?.parts ?? [];
  const textParts: string[] = [];
  const toolCalls: ToolCall[] = [];

  parts.forEach((part, index) => {
    if (part.functionCall && typeof part.functionCall.name === "string") {
      toolCalls.push({
        id: `gemini-${index}-${part.functionCall.name}`,
        name: part.functionCall.name,
        args: isRecord(part.functionCall.args) ? part.functionCall.args : {},
      });
    } else if (typeof part.text === "string" && !part.thought) {
      textParts.push(part.text);
    }
  });

  return {
    text: textParts.join("").trim(),
    toolCalls,
    providerMeta: candidate.content
      ? { geminiContent: { role: "model", parts } }
      : undefined,
  };
}

function safeParse(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return { text };
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
