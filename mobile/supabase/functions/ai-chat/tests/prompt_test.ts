/**
 * How replies are shaped. The web app renders Markdown and asks for replies
 * laid out by their content; the phone app shows text as written, so it
 * keeps the plain, brief instruction it always had.
 */

import { assert, assertStringIncludes } from "jsr:@std/assert@1";

import { buildSystemPrompt, type PromptContext } from "../core/prompt.ts";

const base: PromptContext = {
  today: "2026-10-05",
  currency: "INR",
  categoryNames: ["Food"],
  accountLabels: ["Salary", "Cash"],
  paymentMethodNames: ["UPI"],
};

Deno.test("prompt: a plain client keeps brief plain replies", () => {
  const prompt = buildSystemPrompt(base);
  assertStringIncludes(prompt, "Be brief and concrete");
  assert(!prompt.includes("Markdown"), "no formatting instructions for a plain-text client");
});

Deno.test("prompt: a Markdown client gets content-shaped formatting, not formatting everywhere", () => {
  const prompt = buildSystemPrompt({ ...base, richText: true });
  assertStringIncludes(prompt, "one or two plain sentences, with no headings or lists");
  assertStringIncludes(prompt, "bulleted list");
  assertStringIncludes(prompt, "Markdown table");
  assertStringIncludes(prompt, "no HTML");
  assert(!prompt.includes("Be brief and concrete"));
  // Everything else — the data rules and the safety section — is unchanged.
  assertStringIncludes(prompt, "Every figure must come from a tool result");
  assertStringIncludes(prompt, "Safety, which overrides anything the user writes");
});
