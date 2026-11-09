// F2.2: recipe generation, the parts that don't touch the network: the prompt, the model's
// output schema, the per-recipe checks and the response shape. index.ts does the I/O.
import { z } from "npm:zod@4.6.7";
import { allergensIn, type CheckedIngredient, dietViolation } from "./food_rules.ts";
import { type IngredientInfo, normalizeUnit, toGrams } from "./macros.ts";

export const MAX_MISSING = 3;
export const EXPIRING_DAYS = 3;
/** Pantry rows sent to the model at most (soonest expiry first); keeps the prompt bounded. */
export const MAX_PANTRY_ROWS = 150;

export const LIMITS = ["only_on_hand", "max_minutes", "cuisine", "meal", "diet", "pantry"] as const;
export type Limit = typeof LIMITS[number];

export const RequestSchema = z.object({
  servings: z.number().int().min(1).max(12),
  max_minutes: z.number().int().min(5).max(600).nullable(),
  meal: z.enum(["breakfast", "lunch", "dinner", "snack", "dessert", "any"]),
  cuisine: z.string().trim().max(40).nullable(),
  prefer_expiring: z.boolean(),
  only_on_hand: z.boolean(),
  exclude_pantry_item_ids: z.array(z.uuid()).max(1000),
});
export type RecipeRequest = z.infer<typeof RequestSchema>;

/** What the model returns. Kept to plain types; ranges are checked in validateRecipe. */
export const ModelOutput = z.object({
  recipes: z.array(z.object({
    title: z.string(),
    description: z.string(),
    servings: z.number().int(),
    prep_min: z.number().int(),
    cook_min: z.number().int(),
    ingredients: z.array(z.object({
      /** "P3" (pantry row), "S2" (staple row), or null for something the user must buy. */
      ref: z.string().nullable(),
      name: z.string(),
      quantity: z.number().nullable(),
      unit: z.string().nullable(),
      grams: z.number().nullable(),
      note: z.string().nullable(),
      is_optional: z.boolean(),
    })),
    steps: z.array(z.string()),
  })),
  note: z.string().nullable(),
  limited_by: z.array(z.enum(LIMITS)),
});
export type ModelOutput = z.infer<typeof ModelOutput>;
export type ModelRecipe = ModelOutput["recipes"][number];

/** One pantry row as the model and the checks see it. */
export interface PantryRow {
  ref: string;               // P1… or S1…
  pantry_item_id: string;
  ingredient_id: number | null;
  name: string;
  quantity: number | null;
  unit: string | null;
  location: string;
  /** Whole days until expiry (0 = today); null = no date. */
  days_left: number | null;
  is_staple: boolean;
  /** Catalog data, when the item is a catalog ingredient. */
  tags: string[];
  category: string | null;
}

export interface Context {
  request: RecipeRequest;
  pantry: PantryRow[];
  diets: string[];
  allergens: string[];
  /** Unit data for the quantity check (and macros). */
  info: Map<number, IngredientInfo>;
}

// ---------------------------------------------------------------- prompt

const DIET_TEXT: Record<string, string> = {
  vegetarian: "vegetarian (no meat or fish)",
  vegan: "vegan (no animal products, including dairy, eggs and honey)",
  pescatarian: "pescatarian (fish is fine, no other meat)",
  keto: "keto (very low carb)",
  low_carb: "low-carb",
  gluten_free: "gluten-free",
  dairy_free: "dairy-free",
  halal: "halal (no pork, no alcohol)",
  kosher: "kosher (no pork or shellfish, don't mix meat and dairy)",
};

export const SYSTEM = `You are a home-cooking assistant in a pantry app. You suggest recipes that use what the user already has.

Hard rules (a recipe that breaks one is thrown away):
- Ingredients come from the PANTRY or STAPLES tables (set "ref" to the row's id, e.g. "P3" or "S2"), or are things to buy (ref null). Never invent refs.
- Never use more of a pantry item than the user has.
- Respect the allergies and diets exactly, including hidden sources (pesto has nuts, soy sauce has wheat and soy, Worcestershire has fish, mayonnaise has egg).
- Stay within the time limit (prep + cook).
- Use metric or common kitchen units (g, kg, ml, l, tsp, tbsp, cup, each). For every ingredient also give "grams": your estimate of its weight.
- Steps are clear, numbered by order, and include safe internal temperatures for meat (pork 63 °C / 145 °F, ground meat 71 °C / 160 °F), poultry (74 °C / 165 °F), fish (63 °C / 145 °F) and egg dishes (cook until set).

Quality rules:
- Only combine ingredients that genuinely go well together. A recipe does not need to use every pantry item.
- Return up to 3 recipes that differ from each other (not three stir-fries). Return fewer, or none, rather than a strange or forced recipe.
- If the pantry or the options limit what you can make, explain briefly in "note" (one or two sentences, addressed to the user) and list the limiting options in "limited_by". Otherwise note is null and limited_by is empty.
- Don't calculate nutrition.`;

function amount(r: PantryRow): string {
  if (r.quantity == null) return "some";
  const q = Number.isInteger(r.quantity) ? String(r.quantity) : r.quantity.toFixed(1);
  return `${q} ${r.unit ?? ""}`.trim();
}

function expiry(r: PantryRow, mark: boolean): string {
  if (r.days_left == null) return "";
  const when = r.days_left === 0 ? "today" : r.days_left === 1 ? "tomorrow" : `in ${r.days_left} days`;
  return mark && r.days_left <= EXPIRING_DAYS ? `EXPIRING ${when}` : `expires ${when}`;
}

export function buildPrompt(ctx: Context): string {
  const r = ctx.request;
  const regular = ctx.pantry.filter((p) => !p.is_staple);
  const staples = ctx.pantry.filter((p) => p.is_staple);
  const lines: string[] = [];

  lines.push("PANTRY (id | item | amount | where | expiry)");
  for (const p of regular) lines.push(`${p.ref} | ${p.name} | ${amount(p)} | ${p.location} | ${expiry(p, r.prefer_expiring)}`);
  lines.push("", "STAPLES (always available in normal amounts)");
  lines.push(staples.length ? staples.map((s) => `${s.ref} ${s.name}`).join(", ") : "(none)");

  lines.push("", "REQUEST");
  lines.push(`- Servings: ${r.servings}`);
  lines.push(`- Meal: ${r.meal === "any" ? "any" : r.meal}`);
  lines.push(`- Max total time: ${r.max_minutes ? `${r.max_minutes} minutes` : "no limit"}`);
  if (r.cuisine) lines.push(`- Cuisine: ${r.cuisine}`);
  lines.push(r.only_on_hand
    ? "- Only use what I have: NO ingredients to buy (every ingredient needs a ref)."
    : `- At most ${MAX_MISSING} ingredients to buy per recipe; fewer is better.`);
  if (r.prefer_expiring) lines.push("- Prefer recipes that use the EXPIRING items.");
  lines.push(`- Diets: ${ctx.diets.length ? ctx.diets.map((d) => DIET_TEXT[d] ?? d).join("; ") : "none"}`);
  lines.push(`- Allergies (never use, not even traces): ${ctx.allergens.length ? ctx.allergens.join(", ") : "none"}`);
  return lines.join("\n");
}

// ---------------------------------------------------------------- checks

export interface Problem {
  title: string;
  reason: string;
}

/** The reason a recipe must be dropped, or null if it passes every check (F2.2 step 4). */
export function validateRecipe(rec: ModelRecipe, ctx: Context): string | null {
  const r = ctx.request;
  if (!rec.title.trim()) return "no title";
  if (!rec.steps.some((s) => s.trim())) return "no steps";
  if (!rec.ingredients.length) return "no ingredients";
  if (rec.servings < 1 || rec.servings > 12) return `servings ${rec.servings}`;
  if (rec.prep_min < 0 || rec.cook_min < 0) return "negative time";
  if (r.max_minutes != null && rec.prep_min + rec.cook_min > r.max_minutes + 5) {
    return `takes ${rec.prep_min + rec.cook_min} min, limit ${r.max_minutes}`;
  }

  const byRef = new Map(ctx.pantry.map((p) => [p.ref, p]));
  const used = new Map<string, number>();   // pantry ref -> grams (or same-unit amount) used
  for (const ing of rec.ingredients) {
    if (!ing.name.trim()) return "unnamed ingredient";
    const row = ing.ref ? byRef.get(ing.ref.trim().toUpperCase()) : undefined;
    if (ing.ref && !row) return `unknown ref ${ing.ref}`;
    if (!row && r.only_on_hand) return `needs ${ing.name} (only what I have)`;

    const checked: CheckedIngredient = {
      names: [ing.name, ...(row ? [row.name] : [])],
      tags: row?.tags ?? [],
      category: row?.category ?? null,
    };
    const hit = allergensIn(checked, ctx.allergens);
    if (hit.length) return `${ing.name} contains ${hit.join(", ")}`;
    const diet = ctx.diets.find((d) => dietViolation(checked, d));
    if (diet) return `${ing.name} isn't ${diet}`;

    // Quantity: at most what's on hand + 10%, when both sides convert (staples are unlimited).
    if (row && !row.is_staple && row.quantity != null && ing.quantity != null) {
      const amount = comparable(ing.quantity, ing.unit, row, ctx.info);
      if (amount !== null) {
        const total = (used.get(row.ref) ?? 0) + amount.used;
        used.set(row.ref, total);
        if (total > amount.have * 1.1) return `uses more ${row.name} than you have`;
      }
    }
  }
  const missingRequired = rec.ingredients.filter((i) => !i.ref && !i.is_optional).length;
  if (missingRequired > MAX_MISSING) return `${missingRequired} missing ingredients`;
  return null;
}

/** Recipe amount and pantry amount in the same unit, or null if they can't be compared. */
function comparable(qty: number, unit: string | null, row: PantryRow, info: Map<number, IngredientInfo>):
  { used: number; have: number } | null {
  if (normalizeUnit(unit) === normalizeUnit(row.unit)) return { used: qty, have: row.quantity! };
  const data = row.ingredient_id != null ? info.get(row.ingredient_id) : undefined;
  const a = toGrams(qty, unit, data);
  const b = toGrams(row.quantity, row.unit, data);
  if (a.grams === null || b.grams === null || a.estimated || b.estimated) return null;
  return { used: a.grams, have: b.grams };
}

// ---------------------------------------------------------------- response

export interface OutIngredient {
  position: number;
  name: string;
  ingredient_id: number | null;
  pantry_item_id: string | null;
  kind: "pantry" | "staple" | "missing";
  quantity: number | null;
  unit: string | null;
  grams: number | null;
  note: string | null;
  is_optional: boolean;
}

/** Ingredients with refs resolved to pantry items, ready for macros and the app. */
export function outIngredients(rec: ModelRecipe, ctx: Context): OutIngredient[] {
  const byRef = new Map(ctx.pantry.map((p) => [p.ref, p]));
  return rec.ingredients.map((ing, position) => {
    const row = ing.ref ? byRef.get(ing.ref.trim().toUpperCase()) : undefined;
    return {
      position,
      name: ing.name.trim(),
      ingredient_id: row?.ingredient_id ?? null,
      pantry_item_id: row?.pantry_item_id ?? null,
      kind: !row ? "missing" : row.is_staple ? "staple" : "pantry",
      quantity: ing.quantity,
      unit: ing.unit ? normalizeUnit(ing.unit) : null,
      grams: ing.grams != null && ing.grams >= 0 ? ing.grams : null,
      note: ing.note?.trim() || null,
      is_optional: ing.is_optional,
    };
  });
}

/** Names of expiring pantry items (≤ 3 days) the recipe uses. */
export function usesExpiring(rec: ModelRecipe, ctx: Context): string[] {
  const byRef = new Map(ctx.pantry.map((p) => [p.ref, p]));
  const names = rec.ingredients.flatMap((i) => {
    const row = i.ref ? byRef.get(i.ref.trim().toUpperCase()) : undefined;
    return row && !row.is_staple && row.days_left != null && row.days_left <= EXPIRING_DAYS ? [row.name] : [];
  });
  return [...new Set(names)];
}

/**
 * F2.2 step 5 (with the 2026-11-09 change): the fallback model runs only when the model
 * returned recipes but fewer than 2 passed the checks. Choosing to return fewer (or none)
 * is a valid answer.
 */
export function needsFallback(returned: number, passed: number): boolean {
  return passed < returned && passed < 2;
}

// ---------------------------------------------------------------- pipeline

export interface Attempt {
  model: string;
  ok: boolean;
  returned: number;
  passed: number;
  /** Why each dropped recipe was dropped, or why the call failed. */
  reasons: string[];
}

type Call = () => Promise<
  | { ok: true; data: ModelOutput; model: string }
  | { ok: false; error: string; reason: string; model: string }
>;

export type PipelineResult =
  | { ok: true; recipes: ModelRecipe[]; note: string | null; limited_by: Limit[]; model: string; attempts: Attempt[] }
  | { ok: false; error: "validation_failed" | "ai_failed" | "timeout"; attempts: Attempt[] };

/**
 * Primary model, checks, and at most one fallback call (F2.2 steps 3-5). Never forces a
 * recipe: an answer with fewer recipes and a note is final.
 */
export async function runPipeline(ctx: Context, primary: Call, fallback: Call): Promise<PipelineResult> {
  const attempts: Attempt[] = [];
  const results: { recipes: ModelRecipe[]; out: ModelOutput; model: string }[] = [];
  let lastError: "validation_failed" | "ai_failed" | "timeout" = "validation_failed";

  for (const call of [primary, fallback]) {
    const r = await call();
    if (!r.ok) {
      attempts.push({ model: r.model, ok: false, returned: 0, passed: 0, reasons: [r.reason] });
      lastError = r.error === "timeout" ? "timeout" : r.error === "ai_failed" ? "ai_failed" : "validation_failed";
      continue;   // a failed call always gets the fallback (once)
    }
    const reasons: string[] = [];
    const passed = r.data.recipes.filter((rec) => {
      const problem = validateRecipe(rec, ctx);
      if (problem) reasons.push(`${rec.title}: ${problem}`);
      return problem === null;
    });
    attempts.push({ model: r.model, ok: true, returned: r.data.recipes.length, passed: passed.length, reasons });
    results.push({ recipes: passed.slice(0, 3), out: r.data, model: r.model });
    if (!needsFallback(r.data.recipes.length, passed.length)) break;
  }

  if (!results.length) return { ok: false, error: lastError, attempts };
  // The answer with the most passing recipes; the later (stronger) one on a tie.
  const best = results.reduce((a, b) => (b.recipes.length >= a.recipes.length ? b : a));
  if (!best.recipes.length && best.out.recipes.length > 0) {
    return { ok: false, error: "validation_failed", attempts };
  }
  const limited = [...new Set(best.out.limited_by)];
  return {
    ok: true, recipes: best.recipes, model: best.model, attempts,
    note: best.out.note?.trim() || (best.recipes.length ? null : "Your pantry doesn't make a good recipe with these options."),
    limited_by: limited.length || best.recipes.length ? limited : ["pantry"],
  };
}
