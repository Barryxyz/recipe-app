// F0.5: runtime configuration for AI functions, read from Supabase function secrets
// (`supabase secrets set NAME=value`). Read on every request, so a changed secret takes
// effect without redeploying the function.

export type Effort = "low" | "medium" | "high" | "xhigh" | "max";
export type AiKind = "scan" | "recipes" | "fallback" | "estimate" | "test";

const MODEL_DEFAULTS: Record<AiKind, [envVar: string, model: string]> = {
  scan: ["SCAN_MODEL", "claude-sonnet-5-5"],
  recipes: ["RECIPE_MODEL", "claude-haiku-5-5"],
  fallback: ["FALLBACK_MODEL", "claude-sonnet-5-5"],
  estimate: ["ESTIMATE_MODEL", "claude-haiku-5-5"],
  test: ["RECIPE_MODEL", "claude-haiku-5-5"],
};

// How hard the model thinks before answering (billed as output tokens).
const EFFORT_DEFAULTS: Record<AiKind, [envVar: string, effort: Effort]> = {
  scan: ["SCAN_EFFORT", "medium"],        // listing visible food is recognition, not deep reasoning; raise if the eval says so
  recipes: ["RECIPE_EFFORT", "medium"],
  fallback: ["FALLBACK_EFFORT", "high"],
  estimate: ["ESTIMATE_EFFORT", "low"],
  test: ["RECIPE_EFFORT", "medium"],
};

const EFFORTS: Effort[] = ["low", "medium", "high", "xhigh", "max"];

function env(name: string): string | undefined {
  const v = Deno.env.get(name)?.trim();
  return v ? v : undefined;
}

export function modelFor(kind: AiKind): string {
  const [name, fallback] = MODEL_DEFAULTS[kind];
  return env(name) ?? fallback;
}

export function effortFor(kind: AiKind): Effort {
  const [name, fallback] = EFFORT_DEFAULTS[kind];
  const v = env(name) as Effort | undefined;
  return v && EFFORTS.includes(v) ? v : fallback;
}

/** Kill switch (D5): AI_ENABLED=false turns every AI function off. */
export function aiEnabled(): boolean {
  return env("AI_ENABLED")?.toLowerCase() !== "false";
}

/** NFR-8 / F0.6. Off in the prototype with REQUIRE_PURCHASE=false. Fails closed when unset. */
export function purchaseRequired(): boolean {
  return env("REQUIRE_PURCHASE")?.toLowerCase() !== "false";
}

/** NFR-9: successful scans allowed per user per local day / month. */
export function scanLimits(): { daily: number; monthly: number } {
  const n = (name: string, fallback: number) => {
    const v = Number(env(name));
    return Number.isInteger(v) && v > 0 ? v : fallback;
  };
  return { daily: n("SCAN_DAILY_LIMIT", 10), monthly: n("SCAN_MONTHLY_LIMIT", 60) };
}

export function anthropicApiKey(): string {
  const key = env("ANTHROPIC_API_KEY");
  if (!key) throw new Error("ANTHROPIC_API_KEY is not set");
  return key;
}
