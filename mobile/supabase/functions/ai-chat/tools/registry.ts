import { LIMITS } from "../core/limits.ts";
import type { ToolSpec } from "../core/messages.ts";
import type { ToolContext, ToolDefinition, ToolOutcome } from "./common.ts";
import { READ_TOOLS } from "./read_tools.ts";
import { validateArgs } from "./schema.ts";
import { WRITE_TOOLS } from "./write_tools.ts";

/**
 * The allowlist.
 *
 * A tool the model names that is not in this array does not exist, whatever
 * the model was told. There is deliberately nothing generic here — no
 * "query", no "sql", no "rpc" — and nothing that takes a table or column.
 */
export const TOOLS: readonly ToolDefinition[] = [...READ_TOOLS, ...WRITE_TOOLS];

const BY_NAME: ReadonlyMap<string, ToolDefinition> = new Map(TOOLS.map((t) => [t.name, t]));

export function findTool(name: string): ToolDefinition | undefined {
  return BY_NAME.get(name);
}

export function isWriteTool(name: string): boolean {
  return BY_NAME.get(name)?.kind === "write";
}

/** What the model is told about the tools. */
export function toolSpecs(): ToolSpec[] {
  return TOOLS.map((tool) => ({
    name: tool.name,
    description: tool.description,
    parameters: tool.parameters,
  }));
}

/**
 * Validates and runs one tool call from the model.
 *
 * Never throws: a failure becomes a `{ ok: false, error }` that is fed back
 * to the model as data, in words a person could read, so it can correct
 * itself or ask the user. Internals — database codes, stack traces — stay
 * on the server.
 */
export async function executeTool(
  ctx: ToolContext,
  name: string,
  rawArgs: unknown,
  onInternalError?: (toolName: string, error: unknown) => void,
): Promise<ToolOutcome> {
  const tool = BY_NAME.get(name);
  if (!tool) {
    return { ok: false, error: `Unknown tool "${sanitiseName(name)}". Use only the tools provided.` };
  }

  const validated = validateArgs(tool.parameters, rawArgs);
  if (!validated.ok) {
    return { ok: false, error: `Invalid arguments: ${validated.errors.join("; ")}.` };
  }

  try {
    return await tool.run(ctx, validated.value);
  } catch (error) {
    onInternalError?.(name, error);
    return { ok: false, error: "That information could not be retrieved right now." };
  }
}

/** Serialises a tool outcome for the model, bounded in size. */
export function serialiseOutcome(outcome: ToolOutcome): string {
  const payload = outcome.ok ? outcome.data : { error: outcome.error };
  let json: string;
  try {
    json = JSON.stringify(payload ?? null);
  } catch {
    json = JSON.stringify({ error: "The result could not be encoded." });
  }
  if (json.length <= LIMITS.maxToolResultChars) return json;
  return JSON.stringify({
    error: "The result was too large to show. Ask for a narrower period or fewer rows.",
  });
}

function sanitiseName(name: string): string {
  return name.replace(/[^a-zA-Z0-9_.-]/g, "").slice(0, 60);
}
