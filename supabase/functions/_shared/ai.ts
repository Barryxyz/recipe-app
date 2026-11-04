// F0.5: the one place that calls Claude.
// - Structured output: output_config.format from a zod schema; the reply is validated with
//   zod here (not by the SDK's parse(), which throws and loses the token counts).
// - Refusals, truncated replies and schema mismatches all count as validation failures.
// - Every call writes one app.ai_usage_log row, including failed ones.
// - 60 s timeout, one SDK retry on 429/5xx/connection errors.
// - Sonnet 5.5 calls opt into Anthropic's server-side refusal fallback.
import Anthropic from "npm:@anthropic-ai/sdk@0.135.0";
import { betaZodOutputFormat } from "npm:@anthropic-ai/sdk@0.135.0/helpers/beta/zod";
import type { BetaMessageParam } from "npm:@anthropic-ai/sdk@0.135.0/resources/beta/messages/messages";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.118.0";
import { z } from "npm:zod@4.6.7";
import { anthropicApiKey, type Effort } from "./config.ts";
import { HttpError, log } from "./http.ts";

export const TIMEOUT_MS = 60_000;

// Models that accept `fallbacks: "default"` (server-side refusal fallback) on the Claude API.
const SERVER_FALLBACK_MODELS = new Set(["claude-sonnet-5-5", "claude-opus-5-5", "claude-opus-5", "claude-fable-5-1"]);

let client: Anthropic | undefined;
function anthropic(): Anthropic {
  client ??= new Anthropic({ apiKey: anthropicApiKey(), timeout: TIMEOUT_MS, maxRetries: 1 });
  return client;
}

export interface Usage {
  input_tokens: number;
  output_tokens: number;
}

export interface CallModelParams<S extends z.ZodType> {
  /** Logged in ai_usage_log.kind: 'scan' | 'recipes' | 'nutrition' | 'test' ... */
  kind: string;
  model: string;
  effort: Effort;
  system: string;
  messages: BetaMessageParam[];
  outputSchema: S;
  maxTokens?: number;
  /** For usage logging. */
  userId: string;
  supabaseAdmin: SupabaseClient;
}

export type CallResult<T> =
  | { ok: true; data: T; usage: Usage; model: string }
  | { ok: false; error: "validation_failed" | "ai_failed" | "timeout"; reason: string; usage: Usage; model: string };

/** One model call. Never throws for model/API problems; returns ok: false instead. */
export async function callModel<S extends z.ZodType>(p: CallModelParams<S>): Promise<CallResult<z.infer<S>>> {
  const usage: Usage = { input_tokens: 0, output_tokens: 0 };
  let servedBy = p.model;
  let result: CallResult<z.infer<S>>;

  try {
    const useServerFallback = SERVER_FALLBACK_MODELS.has(p.model);
    const response = await anthropic().beta.messages.create({
      model: p.model,
      max_tokens: p.maxTokens ?? 16000,
      system: p.system,
      messages: p.messages,
      output_config: { effort: p.effort, format: betaZodOutputFormat(p.outputSchema) },
      ...(useServerFallback ? { betas: ["server-side-fallback-2026-07-01"], fallbacks: "default" as const } : {}),
    });

    usage.input_tokens = response.usage.input_tokens + (response.usage.cache_read_input_tokens ?? 0) +
      (response.usage.cache_creation_input_tokens ?? 0);
    usage.output_tokens = response.usage.output_tokens;
    servedBy = response.model ?? p.model;

    if (response.stop_reason === "refusal") {
      result = fail("validation_failed", `refusal (${response.stop_details?.category ?? "unspecified"})`);
    } else if (response.stop_reason === "max_tokens") {
      result = fail("validation_failed", "output truncated at max_tokens");
    } else {
      const text = response.content.flatMap((b) => (b.type === "text" ? [b.text] : [])).join("");
      result = parseOutput(text, p.outputSchema);
    }
  } catch (e) {
    if (e instanceof Anthropic.APIConnectionTimeoutError) {
      result = fail("timeout", "model call timed out");
    } else if (e instanceof Anthropic.APIError) {
      result = fail("ai_failed", `api error ${e.status ?? "?"}`);
    } else {
      result = fail("ai_failed", (e as Error)?.name ?? "error");
    }
  }

  await logUsage(p, servedBy, usage, result.ok);
  log({
    ai: p.kind, model: servedBy, ok: result.ok, reason: result.ok ? undefined : result.reason,
    in: usage.input_tokens, out: usage.output_tokens,
  });
  return result;

  function fail(error: "validation_failed" | "ai_failed" | "timeout", reason: string): CallResult<never> {
    return { ok: false, error, reason, usage, model: servedBy };
  }
  function parseOutput(text: string, schema: S): CallResult<z.infer<S>> {
    let json: unknown;
    try {
      json = JSON.parse(text);
    } catch {
      return fail("validation_failed", "output is not JSON");
    }
    const parsed = schema.safeParse(json);
    return parsed.success
      ? { ok: true, data: parsed.data, usage, model: servedBy }
      : fail("validation_failed", "output does not match schema");
  }
}

async function logUsage(p: CallModelParams<z.ZodType>, model: string, usage: Usage, ok: boolean): Promise<void> {
  const { error } = await p.supabaseAdmin.schema("app").from("ai_usage_log").insert({
    user_id: p.userId,
    kind: p.kind,
    model,
    input_tokens: usage.input_tokens,
    output_tokens: usage.output_tokens,
    ok,
  });
  if (error) log({ ai_usage_log: "insert_failed", code: error.code });
}

export interface Attempt {
  model: string;
  ok: boolean;
  reason?: string;
}

/**
 * Runs `primary`, checks it with `validate` (schema-valid output can still be wrong, e.g. a
 * recipe using an ingredient the user doesn't have), and on any failure runs `fallback` once.
 * Throws HttpError if the fallback fails too.
 */
export async function withFallback<T>(
  primary: () => Promise<CallResult<T>>,
  fallback: () => Promise<CallResult<T>>,
  validate: (data: T) => string | null = () => null,
): Promise<{ data: T; model: string; attempts: Attempt[] }> {
  const attempts: Attempt[] = [];
  for (const run of [primary, fallback]) {
    const r = await run();
    if (r.ok) {
      const problem = validate(r.data);
      if (problem === null) {
        attempts.push({ model: r.model, ok: true });
        return { data: r.data, model: r.model, attempts };
      }
      attempts.push({ model: r.model, ok: false, reason: problem });
    } else {
      attempts.push({ model: r.model, ok: false, reason: r.reason });
      if (r.error === "timeout" && run === fallback) throw new HttpError("timeout", "The AI took too long. Try again.");
    }
  }
  const last = attempts[attempts.length - 1];
  throw new HttpError(
    last.reason?.startsWith("api error") ? "ai_failed" : "validation_failed",
    "The AI couldn't produce a usable answer. Try again.",
  );
}
