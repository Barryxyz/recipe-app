// F0.5: common request handling for AI Edge Functions.
// - Signed-in users only (401), bodies up to 10 MB (413), verified purchase (402, F0.6),
//   kill switch (503).
// - One error shape: { error: { code, message } }.
// - Never logs request bodies, so photos never reach the logs (DESIGN §4).
import { createSupabaseContext } from "npm:@supabase/server@1.9.2";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.118.0";
import { aiEnabled, purchaseRequired } from "./config.ts";

export const MAX_BODY_BYTES = 10 * 1024 * 1024;

export type ErrorCode =
  | "unauthorized"
  | "purchase_required"
  | "bad_request"
  | "payload_too_large"
  | "ai_disabled"
  | "ai_failed"
  | "validation_failed"
  | "timeout"
  | "limit_reached";

const STATUS: Record<ErrorCode, number> = {
  unauthorized: 401,
  purchase_required: 402,
  bad_request: 400,
  payload_too_large: 413,
  ai_disabled: 503,
  ai_failed: 502,
  validation_failed: 502,
  timeout: 504,
  limit_reached: 429,
};

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

/** Throw from a handler to return a typed error response. */
export class HttpError extends Error {
  constructor(readonly code: ErrorCode, message: string) {
    super(message);
  }
}

export function errorResponse(code: ErrorCode, message: string): Response {
  return Response.json({ error: { code, message } }, { status: STATUS[code], headers: CORS });
}

export interface AiRequestContext {
  userId: string;
  /** RLS-scoped as the caller. */
  supabase: SupabaseClient;
  /** Bypasses RLS: usage logging and other server-only writes. */
  supabaseAdmin: SupabaseClient;
  /** Parsed JSON body. */
  body: unknown;
}

/** Wraps an AI endpoint with auth, size limit, purchase check and kill switch. */
export function aiEndpoint(
  name: string,
  handler: (ctx: AiRequestContext) => Promise<unknown>,
): (req: Request) => Promise<Response> {
  return async (req) => {
    if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
    if (req.method !== "POST") return errorResponse("bad_request", "Use POST.");

    // Kill switch first: no auth or body work while AI is off.
    if (!aiEnabled()) {
      return errorResponse("ai_disabled", "AI features are temporarily unavailable.");
    }

    const { data: sb, error: authError } = await createSupabaseContext(req, { auth: "user" });
    if (authError || !sb?.userClaims?.id) {
      return errorResponse("unauthorized", "Sign in required.");
    }
    const userId = sb.userClaims.id as string;

    const raw = await readBody(req);
    if (raw === null) {
      return errorResponse("payload_too_large", "Request body is over 10 MB.");
    }
    let body: unknown = {};
    if (raw.byteLength > 0) {
      try {
        body = JSON.parse(new TextDecoder().decode(raw));
      } catch {
        return errorResponse("bad_request", "Body must be JSON.");
      }
    }

    if (purchaseRequired()) {
      const { data: user, error } = await sb.supabaseAdmin
        .schema("app").from("users").select("purchase_verified_at").eq("id", userId).maybeSingle();
      if (error || !user?.purchase_verified_at) {
        return errorResponse("purchase_required", "A verified App Store purchase is required.");
      }
    }

    const started = Date.now();
    try {
      const result = await handler({ userId, supabase: sb.supabase, supabaseAdmin: sb.supabaseAdmin, body });
      log({ fn: name, user: userId, status: 200, ms: Date.now() - started });
      return Response.json(result, { headers: CORS });
    } catch (e) {
      if (e instanceof HttpError) {
        log({ fn: name, user: userId, status: STATUS[e.code], code: e.code, ms: Date.now() - started });
        return errorResponse(e.code, e.message);
      }
      // Log the error type only: messages can echo request content.
      log({ fn: name, user: userId, status: 500, error: (e as Error)?.name ?? "Error", ms: Date.now() - started });
      return errorResponse("ai_failed", "Something went wrong. Try again.");
    }
  };
}

/**
 * Reads the body, keeping at most MAX_BODY_BYTES; returns null if it's larger.
 * An oversized body is still read to the end (and discarded): answering before the upload
 * finishes makes the Supabase gateway return an empty 503 instead of our 413.
 */
async function readBody(req: Request): Promise<Uint8Array | null> {
  if (!req.body) return new Uint8Array();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for await (const chunk of req.body) {
    total += chunk.byteLength;
    if (total <= MAX_BODY_BYTES) chunks.push(chunk);
  }
  if (total > MAX_BODY_BYTES) return null;
  const out = new Uint8Array(total);
  let offset = 0;
  for (const c of chunks) {
    out.set(c, offset);
    offset += c.byteLength;
  }
  return out;
}

/** Structured, body-free log line. Never pass request or model content here. */
export function log(fields: Record<string, string | number | boolean | null | undefined>): void {
  console.log(JSON.stringify(fields));
}
