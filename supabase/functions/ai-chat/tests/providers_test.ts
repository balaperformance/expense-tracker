import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";

import type { CompletionRequest, ToolSpec } from "../core/messages.ts";
import { GeminiProvider } from "../providers/gemini.ts";
import { GroqProvider } from "../providers/groq.ts";
import { ProviderChain, ProviderChainError, ProviderError } from "../providers/provider.ts";
import { FakeProvider, rateLimited, text } from "./fakes.ts";

const tools: ToolSpec[] = [{
  name: "get_monthly_expenses",
  description: "d",
  parameters: {
    type: "object",
    properties: { month: { type: "string", pattern: "^x$", maxLength: 7 } },
  },
}];

function request(messages: CompletionRequest["messages"]): CompletionRequest {
  return { system: "sys", messages, tools, toolChoice: "auto", signal: new AbortController().signal };
}

/** A fetch that records the request and returns a canned response. */
function stubFetch(status: number, body: unknown) {
  const seen: { url?: string; init?: RequestInit; body?: Record<string, unknown> } = {};
  const fetchImpl = (url: string, init: RequestInit) => {
    seen.url = url;
    seen.init = init;
    seen.body = JSON.parse(String(init.body));
    return Promise.resolve(
      new Response(typeof body === "string" ? body : JSON.stringify(body), { status }),
    );
  };
  return { seen, fetchImpl };
}

// ---------------------------------------------------------------------------
// Gemini
// ---------------------------------------------------------------------------

Deno.test("gemini: builds a generateContent request with the key in a header, not the URL", async () => {
  const { seen, fetchImpl } = stubFetch(200, {
    candidates: [{ content: { role: "model", parts: [{ text: "Hi" }] } }],
  });
  const provider = new GeminiProvider("secret-key", "gemini-test", fetchImpl);
  const completion = await provider.complete(request([{ role: "user", content: "hello" }]));

  assertEquals(completion.text, "Hi");
  assert(seen.url!.includes("/models/gemini-test:generateContent"));
  assert(!seen.url!.includes("secret-key"));
  assertEquals((seen.init!.headers as Record<string, string>)["x-goog-api-key"], "secret-key");
  const body = seen.body!;
  assertEquals((body.systemInstruction as { parts: { text: string }[] }).parts[0].text, "sys");
  // Validation-only keywords are stripped from the declaration.
  const decl = (body.tools as Array<{ functionDeclarations: Array<{ parameters: Record<string, unknown> }> }>)[0]
    .functionDeclarations[0].parameters;
  const month = (decl.properties as Record<string, Record<string, unknown>>).month;
  assertEquals(month.pattern, undefined);
  assertEquals(month.maxLength, undefined);
  assertEquals(month.type, "string");
});

Deno.test("gemini: maps functionCall parts to tool calls and keeps raw parts for replay", async () => {
  const { fetchImpl } = stubFetch(200, {
    candidates: [{
      content: {
        role: "model",
        parts: [
          { thought: true, text: "thinking..." },
          { functionCall: { name: "get_monthly_expenses", args: { month: "2026-09" } }, thoughtSignature: "sig" },
        ],
      },
    }],
  });
  const provider = new GeminiProvider("k", "m", fetchImpl);
  const completion = await provider.complete(request([{ role: "user", content: "q" }]));

  assertEquals(completion.text, "");
  assertEquals(completion.toolCalls.length, 1);
  assertEquals(completion.toolCalls[0].name, "get_monthly_expenses");
  assertEquals(completion.toolCalls[0].args, { month: "2026-09" });
  const raw = (completion.providerMeta!.geminiContent as { parts: Array<Record<string, unknown>> }).parts;
  assertEquals(raw[1].thoughtSignature, "sig");
});

Deno.test("gemini: replays an assistant turn from raw parts and groups tool results", async () => {
  const { seen, fetchImpl } = stubFetch(200, {
    candidates: [{ content: { role: "model", parts: [{ text: "₹4,000" }] } }],
  });
  const provider = new GeminiProvider("k", "m", fetchImpl);
  await provider.complete(request([
    { role: "user", content: "q" },
    {
      role: "assistant",
      content: "",
      toolCalls: [{ id: "a", name: "get_monthly_expenses", args: {} }],
      providerMeta: {
        geminiContent: {
          role: "model",
          parts: [{ functionCall: { name: "get_monthly_expenses", args: {} }, thoughtSignature: "sig" }],
        },
      },
    },
    { role: "tool", toolCallId: "a", name: "get_monthly_expenses", content: '{"total":4000}' },
  ]));
  const contents = seen.body!.contents as Array<{ role: string; parts: Array<Record<string, unknown>> }>;
  assertEquals(contents.length, 3);
  assertEquals(contents[1].parts[0].thoughtSignature, "sig");
  assertEquals(contents[2].role, "user");
  assertEquals(
    (contents[2].parts[0].functionResponse as { response: { result: unknown } }).response.result,
    { total: 4000 },
  );
});

Deno.test("gemini: HTTP failures are classified", async () => {
  for (const [status, failure] of [[429, "rate_limited"], [503, "unavailable"], [404, "model_not_found"], [401, "auth"], [400, "invalid_request"]] as const) {
    const { fetchImpl } = stubFetch(status, { error: { message: "x" } });
    const provider = new GeminiProvider("k", "m", fetchImpl);
    const error = await assertRejects(() => provider.complete(request([{ role: "user", content: "q" }])), ProviderError);
    assertEquals(error.failure, failure, `status ${status}`);
  }
});

Deno.test("gemini: a blocked prompt yields a refusal, not an outage", async () => {
  const { fetchImpl } = stubFetch(200, { promptFeedback: { blockReason: "SAFETY" } });
  const provider = new GeminiProvider("k", "m", fetchImpl);
  const completion = await provider.complete(request([{ role: "user", content: "q" }]));
  assertEquals(completion.toolCalls, []);
  assert(completion.text.length > 0);
});

// ---------------------------------------------------------------------------
// Groq
// ---------------------------------------------------------------------------

Deno.test("groq: builds an OpenAI-style request with bearer auth and tool schema", async () => {
  const { seen, fetchImpl } = stubFetch(200, { choices: [{ message: { content: "Hi" } }] });
  const provider = new GroqProvider("gk", "model-x", fetchImpl);
  const completion = await provider.complete(request([{ role: "user", content: "hello" }]));

  assertEquals(completion.text, "Hi");
  assertEquals((seen.init!.headers as Record<string, string>).authorization, "Bearer gk");
  assertEquals(seen.body!.model, "model-x");
  assertEquals(seen.body!.tool_choice, "auto");
  const messages = seen.body!.messages as Array<{ role: string; content: string }>;
  assertEquals(messages[0], { role: "system", content: "sys" });
  const tool = (seen.body!.tools as Array<{ type: string; function: { name: string } }>)[0];
  assertEquals(tool.type, "function");
  assertEquals(tool.function.name, "get_monthly_expenses");
});

Deno.test("groq: parses tool_calls with JSON-string arguments", async () => {
  const { fetchImpl } = stubFetch(200, {
    choices: [{
      message: {
        content: null,
        tool_calls: [{
          id: "call_1",
          type: "function",
          function: { name: "get_monthly_expenses", arguments: '{"month":"2026-09"}' },
        }],
      },
    }],
  });
  const provider = new GroqProvider("gk", "m", fetchImpl);
  const completion = await provider.complete(request([{ role: "user", content: "q" }]));
  assertEquals(completion.toolCalls, [{ id: "call_1", name: "get_monthly_expenses", args: { month: "2026-09" } }]);
});

Deno.test("groq: malformed argument JSON is surfaced as a malformed call, not a crash", async () => {
  const { fetchImpl } = stubFetch(200, {
    choices: [{
      message: {
        tool_calls: [{ id: "c", type: "function", function: { name: "get_monthly_expenses", arguments: "{month: 2026" } }],
      },
    }],
  });
  const provider = new GroqProvider("gk", "m", fetchImpl);
  const completion = await provider.complete(request([{ role: "user", content: "q" }]));
  assertEquals(completion.toolCalls.length, 1);
  assert(completion.toolCalls[0].malformedReason);
});

Deno.test("groq: replays assistant tool calls and tool results in wire form", async () => {
  const { seen, fetchImpl } = stubFetch(200, { choices: [{ message: { content: "ok" } }] });
  const provider = new GroqProvider("gk", "m", fetchImpl);
  await provider.complete(request([
    { role: "user", content: "q" },
    { role: "assistant", content: "", toolCalls: [{ id: "c1", name: "get_monthly_expenses", args: { month: "2026-09" } }] },
    { role: "tool", toolCallId: "c1", name: "get_monthly_expenses", content: '{"total":1}' },
  ]));
  const messages = seen.body!.messages as Array<Record<string, unknown>>;
  const assistant = messages[2] as { content: unknown; tool_calls: Array<{ function: { arguments: string } }> };
  assertEquals(assistant.content, null);
  assertEquals(assistant.tool_calls[0].function.arguments, '{"month":"2026-09"}');
  assertEquals(messages[3].tool_call_id, "c1");
});

Deno.test("groq: a malformed response body is a retryable failure", async () => {
  const { fetchImpl } = stubFetch(200, "<html>oops</html>");
  const provider = new GroqProvider("gk", "m", fetchImpl);
  const error = await assertRejects(() => provider.complete(request([{ role: "user", content: "q" }])), ProviderError);
  assertEquals(error.failure, "malformed_response");
  assert(!error.isConfiguration, "a garbled body is not a configuration problem");
});

// ---------------------------------------------------------------------------
// Chain
// ---------------------------------------------------------------------------

Deno.test("chain: Gemini success never touches Groq", async () => {
  const gemini = new FakeProvider("gemini", [text("from gemini")]);
  const groq = new FakeProvider("groq", [text("from groq")]);
  const chain = new ProviderChain([gemini, groq]);
  const outcome = await chain.complete(request([{ role: "user", content: "q" }]));
  assertEquals(outcome.provider, "gemini");
  assertEquals(outcome.completion.text, "from gemini");
  assertEquals(groq.requests.length, 0);
});

Deno.test("chain: Gemini rate limit falls back to Groq exactly once and sticks", async () => {
  const gemini = new FakeProvider("gemini", [rateLimited("gemini"), text("gemini again")]);
  const groq = new FakeProvider("groq", [text("groq 1"), text("groq 2")]);
  const fallbacks: string[] = [];
  const chain = new ProviderChain([gemini, groq], (from, to, why) => fallbacks.push(`${from}->${to}:${why}`));

  const first = await chain.complete(request([{ role: "user", content: "q" }]));
  assertEquals(first.provider, "groq");
  assertEquals(fallbacks, ["gemini->groq:rate_limited"]);

  const second = await chain.complete(request([{ role: "user", content: "q2" }]));
  assertEquals(second.provider, "groq");
  assertEquals(gemini.requests.length, 1, "Gemini is not retried within the request");
});

Deno.test("chain: both providers down reports every failure", async () => {
  const gemini = new FakeProvider("gemini", [new ProviderError("gemini", "unavailable", "503", 503)]);
  const groq = new FakeProvider("groq", [new ProviderError("groq", "timeout", "abort")]);
  const chain = new ProviderChain([gemini, groq]);

  const error = await assertRejects(
    () => chain.complete(request([{ role: "user", content: "q" }])),
    ProviderChainError,
  );
  assertEquals(error.failures.map((f) => f.provider), ["gemini", "groq"]);
  assertEquals(error.last?.provider, "groq");
  assert(!error.allConfiguration, "an outage is not a configuration problem");
});

Deno.test("chain: a bad key on the primary still falls back to the fallback", async () => {
  // The regression this guards is the one that shipped: Google reports a bad
  // or restricted API key as HTTP 400, which classifies as `invalid_request`.
  // The chain used to stop there, so one unhealthy Gemini key took down a
  // perfectly healthy Groq and the user was told the app had no keys at all.
  for (const failure of ["invalid_request", "auth", "model_not_found"] as const) {
    const gemini = new FakeProvider("gemini", [new ProviderError("gemini", failure, "x", 400)]);
    const groq = new FakeProvider("groq", [text("groq answered")]);
    const chain = new ProviderChain([gemini, groq]);

    const outcome = await chain.complete(request([{ role: "user", content: "q" }]));
    assertEquals(outcome.provider, "groq", failure);
    assertEquals(outcome.completion.text, "groq answered");
    assertEquals(groq.requests.length, 1, failure);
  }
});

Deno.test("chain: only every provider failing on configuration counts as unconfigured", async () => {
  const bothBad = new ProviderChain([
    new FakeProvider("gemini", [new ProviderError("gemini", "invalid_request", "bad key", 400)]),
    new FakeProvider("groq", [new ProviderError("groq", "auth", "bad key", 401)]),
  ]);
  const bothBadError = await assertRejects(
    () => bothBad.complete(request([{ role: "user", content: "q" }])),
    ProviderChainError,
  );
  assert(bothBadError.allConfiguration);

  // One bad key plus one rate limit is a busy assistant, not an unconfigured
  // one: the deployment is fine and the user should be told to wait.
  const mixed = new ProviderChain([
    new FakeProvider("gemini", [new ProviderError("gemini", "invalid_request", "bad key", 400)]),
    new FakeProvider("groq", [rateLimited("groq")]),
  ]);
  const mixedError = await assertRejects(
    () => mixed.complete(request([{ role: "user", content: "q" }])),
    ProviderChainError,
  );
  assert(!mixedError.allConfiguration);
});

Deno.test("chain: configuration failures are classified, load failures are not", () => {
  for (const failure of ["auth", "invalid_request", "model_not_found"] as const) {
    assert(new ProviderError("g", failure, "").isConfiguration, failure);
  }
  for (const failure of ["timeout", "rate_limited", "unavailable", "malformed_response"] as const) {
    assert(!new ProviderError("g", failure, "").isConfiguration, failure);
  }
});
