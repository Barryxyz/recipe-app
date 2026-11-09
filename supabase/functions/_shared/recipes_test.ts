// F2.2: prompt, per-recipe checks and the fallback rule, against made-up model output.
import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import type { IngredientInfo } from "./macros.ts";
import {
  plausibleQuantity, stripStepNumber,
  buildPrompt, type Context, type ModelOutput, type ModelRecipe, needsFallback, outIngredients, type PantryRow,
  type RecipeRequest, runPipeline, usesExpiring, validateRecipe,
} from "./recipes.ts";

const REQ: RecipeRequest = {
  servings: 2, max_minutes: 30, meal: "dinner", cuisine: null, prefer_expiring: true, only_on_hand: false,
  exclude_pantry_item_ids: [],
};

function row(ref: string, name: string, extra: Partial<PantryRow> = {}): PantryRow {
  return {
    ref, pantry_item_id: `id-${ref}`, ingredient_id: null, name, quantity: null, unit: null, location: "fridge",
    days_left: 10, is_staple: false, tags: [], category: null, ...extra,
  };
}

const INFO = new Map<number, IngredientInfo>([
  [52, { grams_per_unit: null, density_g_per_ml: null, nutrients: null, estimated: false }],
  [38, { grams_per_unit: 50, density_g_per_ml: null, nutrients: null, estimated: false }],
]);

function ctx(over: Partial<Context> = {}, req: Partial<RecipeRequest> = {}): Context {
  return {
    request: { ...REQ, ...req },
    pantry: [
      row("P1", "chicken thighs", { ingredient_id: 52, quantity: 500, unit: "g", days_left: 1, category: "meat" }),
      row("P2", "eggs", { ingredient_id: 38, quantity: 6, unit: "each", tags: ["egg"], category: "dairy" }),
      row("P3", "house sauce", { tags: ["soy", "wheat"] }),
      row("S1", "olive oil", { is_staple: true }),
      row("S2", "soy sauce", { is_staple: true, tags: ["soy", "wheat", "gluten"] }),
    ],
    diets: [],
    allergens: [],
    info: INFO,
    ...over,
  };
}

type Ing = ModelRecipe["ingredients"][number];
const ing = (ref: string | null, name: string, quantity: number | null = null, unit: string | null = null,
  extra: Partial<Ing> = {}): Ing => ({ ref, name, quantity, unit, grams: null, note: null, is_optional: false, ...extra });

function recipe(ingredients: Ing[], over: Partial<ModelRecipe> = {}): ModelRecipe {
  return { title: "Test dish", description: "d", servings: 2, prep_min: 10, cook_min: 15, ingredients,
    steps: ["Cook it."], ...over };
}

Deno.test("prompt: refs, amounts, expiring marks, staples, rules", () => {
  const p = buildPrompt(ctx({ allergens: ["peanuts", "mustard"], diets: ["vegetarian"] }, { cuisine: "thai" }));
  assertStringIncludes(p, "P1 | chicken thighs | 500 g | fridge | EXPIRING tomorrow");
  assertStringIncludes(p, "P2 | eggs | 6 each | fridge | expires in 10 days");
  assertStringIncludes(p, "S1 olive oil, S2 soy sauce");
  assertStringIncludes(p, "Max total time: 30 minutes");
  assertStringIncludes(p, "Cuisine: thai");
  assertStringIncludes(p, "At most 3 ingredients to buy");
  assertStringIncludes(p, "vegetarian (no meat or fish)");
  assertStringIncludes(p, "Allergies (never use, not even traces): peanuts, mustard");
  const only = buildPrompt(ctx({}, { only_on_hand: true, prefer_expiring: false, max_minutes: null }));
  assertStringIncludes(only, "NO ingredients to buy");
  assertStringIncludes(only, "expires tomorrow");
  assertStringIncludes(only, "no limit");
});

Deno.test("checks: a good recipe passes", () => {
  assertEquals(validateRecipe(recipe([ing("P1", "chicken thighs", 400, "g"), ing("S1", "olive oil", 1, "tbsp"),
    ing(null, "lime", 1, "each")]), ctx()), null);
});

Deno.test("checks: schema, refs, time", () => {
  assertEquals(validateRecipe(recipe([ing("P9", "ghost", 1, "each")]), ctx()), "unknown ref P9");
  assertEquals(validateRecipe(recipe([ing("P1", "chicken", 100, "g")], { steps: [" "] }), ctx()), "no steps");
  assertEquals(validateRecipe(recipe([ing("P1", "chicken", 100, "g")], { servings: 13 }), ctx()), "servings 13");
  assertEquals(validateRecipe(recipe([ing("P1", "chicken", 100, "g")], { prep_min: 20, cook_min: 15 }), ctx()), null,
    "within the 5-minute grace");
  assert(validateRecipe(recipe([ing("P1", "chicken", 100, "g")], { prep_min: 20, cook_min: 20 }), ctx())?.includes("takes 40 min"));
  assertEquals(validateRecipe(recipe([ing("p1", "chicken", 100, "g")]), ctx()), null, "refs are case-insensitive");
});

Deno.test("checks: missing ingredients", () => {
  const four = [ing("P1", "chicken", 100, "g"), ...["a", "b", "c", "d"].map((n) => ing(null, n))];
  assertEquals(validateRecipe(recipe(four), ctx()), "4 missing ingredients");
  const optional = [ing("P1", "chicken", 100, "g"), ...["a", "b", "c"].map((n) => ing(null, n)),
    ing(null, "parsley", null, null, { is_optional: true })];
  assertEquals(validateRecipe(recipe(optional), ctx()), null, "optional extras don't count");
  assert(validateRecipe(recipe([ing("P1", "chicken", 100, "g"), ing(null, "lime")]), ctx({}, { only_on_hand: true }))
    ?.includes("only what I have"));
});

Deno.test("checks: allergens by pantry tag, by name, by staple tag, custom", () => {
  const c = ctx({ allergens: ["soy", "peanuts", "egg", "mustard"] });
  assert(validateRecipe(recipe([ing("P3", "the sauce", 2, "tbsp")]), c)?.includes("contains soy"), "tag on the pantry row");
  assert(validateRecipe(recipe([ing("S2", "seasoning", 1, "tbsp")]), c)?.includes("contains soy"), "tag on a staple");
  assert(validateRecipe(recipe([ing(null, "satay sauce", 3, "tbsp")]), c)?.includes("peanuts"), "missing item by name");
  assert(validateRecipe(recipe([ing("P2", "egg", 2, "each")]), c)?.includes("egg"));
  assert(validateRecipe(recipe([ing(null, "dijon mustard", 1, "tsp")]), c)?.includes("mustard"), "custom allergy");
  assertEquals(validateRecipe(recipe([ing("P1", "chicken thighs", 100, "g")]), c), null);
});

Deno.test("checks: diets", () => {
  assert(validateRecipe(recipe([ing("P1", "chicken thighs", 100, "g")]), ctx({ diets: ["vegetarian"] }))?.includes("vegetarian"));
  assert(validateRecipe(recipe([ing(null, "fish sauce", 1, "tbsp")]), ctx({ diets: ["vegetarian"] }))?.includes("vegetarian"));
  assert(validateRecipe(recipe([ing("P2", "eggs", 2, "each")]), ctx({ diets: ["vegan"] }))?.includes("vegan"));
  assertEquals(validateRecipe(recipe([ing("P2", "eggs", 2, "each")]), ctx({ diets: ["vegetarian"] })), null);
});

Deno.test("checks: quantity within what's on hand + 10%", () => {
  assertEquals(validateRecipe(recipe([ing("P1", "chicken", 550, "g")]), ctx()), null, "550 g of 500 g is within 10%");
  assert(validateRecipe(recipe([ing("P1", "chicken", 560, "g")]), ctx())?.includes("more chicken thighs"));
  assert(validateRecipe(recipe([ing("P1", "chicken", 0.6, "kg")]), ctx())?.includes("more"), "converted kg -> g");
  assert(validateRecipe(recipe([ing("P1", "chicken", 300, "g"), ing("P1", "chicken", 300, "g")]), ctx())?.includes("more"),
    "the same item used twice adds up");
  assert(validateRecipe(recipe([ing("P2", "eggs", 7, "each")]), ctx())?.includes("more eggs"));
  assertEquals(validateRecipe(recipe([ing("P2", "eggs", 300, "g")]), ctx()), null, "300 g of 6 eggs (300 g) is fine");
  assertEquals(validateRecipe(recipe([ing("P1", "chicken", 2, "cup")]), ctx()), null, "can't convert: skipped");
  assertEquals(validateRecipe(recipe([ing("S1", "olive oil", 500, "ml")]), ctx()), null, "staples are unlimited");
});

Deno.test("response helpers: kinds, ids, expiring", () => {
  const rec = recipe([ing("P1", "chicken", 200, "grams"), ing("S1", "olive oil", 1, "tbsp"), ing(null, "lime", 1, "each"),
    ing("P2", "eggs", 2, "each")]);
  const out = outIngredients(rec, ctx());
  assertEquals(out.map((i) => i.kind), ["pantry", "staple", "missing", "pantry"]);
  assertEquals(out[0].pantry_item_id, "id-P1");
  assertEquals(out[0].ingredient_id, 52);
  assertEquals(out[0].unit, "g");
  assertEquals(out[2].pantry_item_id, null);
  assertEquals(usesExpiring(rec, ctx()), ["chicken thighs"]);
});

// ------------------------------------------------------------ fallback rule

Deno.test("fallback only when returned recipes failed the checks", () => {
  assertEquals(needsFallback(3, 3), false);
  assertEquals(needsFallback(3, 2), false);
  assertEquals(needsFallback(3, 1), true);
  assertEquals(needsFallback(2, 1), true);
  assertEquals(needsFallback(1, 1), false, "the model chose to return one good recipe");
  assertEquals(needsFallback(1, 0), true);
  assertEquals(needsFallback(0, 0), false, "zero recipes with a note is a valid answer");
});

const GOOD = recipe([ing("P1", "chicken thighs", 200, "g")], { title: "Good" });
const BAD = recipe([ing("P9", "ghost", 1, "each")], { title: "Bad" });
const out = (recipes: ModelRecipe[], note: string | null = null, limited_by: ModelOutput["limited_by"] = []) =>
  ({ ok: true as const, data: { recipes, note, limited_by }, model: "m" });

function calls(...answers: Awaited<ReturnType<Parameters<typeof runPipeline>[1]>>[]) {
  let n = 0;
  const make = (model: string) => () => {
    const a = answers[n++];
    return Promise.resolve({ ...a, model });
  };
  return { primary: make("haiku"), fallback: make("sonnet"), count: () => n };
}

Deno.test("pipeline: forced validation failure -> exactly one fallback call", async () => {
  const c = calls(out([BAD, BAD, BAD]), out([GOOD, GOOD]));
  const r = await runPipeline(ctx(), c.primary, c.fallback);
  assertEquals(c.count(), 2);
  assert(r.ok && r.recipes.length === 2 && r.model === "sonnet");
  assertEquals(r.attempts.map((a) => [a.model, a.passed]), [["haiku", 0], ["sonnet", 2]]);
});

Deno.test("pipeline: zero recipes with a note is final (no fallback)", async () => {
  const c = calls(out([], "These items don't make a meal together.", ["only_on_hand", "pantry"]));
  const r = await runPipeline(ctx(), c.primary, c.fallback);
  assertEquals(c.count(), 1);
  assert(r.ok);
  assertEquals([r.recipes.length, r.note, r.limited_by], [0, "These items don't make a meal together.", ["only_on_hand", "pantry"]]);
});

Deno.test("pipeline: zero recipes without a note gets a default note", async () => {
  const c = calls(out([]));
  const r = await runPipeline(ctx(), c.primary, c.fallback);
  assert(r.ok && r.note !== null && r.limited_by.includes("pantry"));
});

Deno.test("pipeline: one good recipe is enough; keeps the better answer", async () => {
  const one = calls(out([GOOD], "Only one idea fits."));
  const r1 = await runPipeline(ctx(), one.primary, one.fallback);
  assertEquals(one.count(), 1);
  assert(r1.ok && r1.recipes.length === 1 && r1.note === "Only one idea fits.");
  // Primary 1 of 3 passes, fallback 0 of 3: keep the primary's one.
  const worse = calls(out([GOOD, BAD, BAD]), out([BAD, BAD, BAD]));
  const r2 = await runPipeline(ctx(), worse.primary, worse.fallback);
  assert(r2.ok && r2.recipes.length === 1 && r2.model === "haiku");
});

Deno.test("pipeline: both fail -> validation_failed; API error -> fallback, then ai_failed", async () => {
  const bad = calls(out([BAD]), out([BAD, BAD]));
  const r = await runPipeline(ctx(), bad.primary, bad.fallback);
  assert(!r.ok && r.error === "validation_failed");
  const err = { ok: false as const, error: "ai_failed", reason: "api error 529", model: "x" };
  const down = calls(err, err);
  const r2 = await runPipeline(ctx(), down.primary, down.fallback);
  assertEquals(down.count(), 2);
  assert(!r2.ok && r2.error === "ai_failed");
  const recover = calls(err, out([GOOD]));
  const r3 = await runPipeline(ctx(), recover.primary, recover.fallback);
  assert(r3.ok && r3.recipes.length === 1);
});

Deno.test("pipeline: at most 3 recipes returned", async () => {
  const c = calls(out([GOOD, GOOD, GOOD, GOOD]));
  const r = await runPipeline(ctx(), c.primary, c.fallback);
  assert(r.ok && r.recipes.length === 3);
});

Deno.test("placeholder amounts count as 'some'", () => {
  assertEquals(plausibleQuantity(1, "g"), null, "1 g pasta");
  assertEquals(plausibleQuantity(1, "ml"), null, "1 ml almond milk");
  assertEquals(plausibleQuantity(9, "grams"), null);
  assertEquals(plausibleQuantity(10, "g"), 10);
  assertEquals(plausibleQuantity(1, "kg"), 1);
  assertEquals(plausibleQuantity(1, "each"), 1);
  assertEquals(plausibleQuantity(0, "each"), null);
  assertEquals(plausibleQuantity(null, "g"), null);
});

Deno.test("pipeline: no fallback once the time budget is used up", async () => {
  let t = 0;
  const c = calls(out([BAD, BAD, BAD]), out([GOOD]));
  const slow = () => { t += 40_000; return c.primary(); };
  const r = await runPipeline(ctx(), slow, c.fallback, { fallbackCutoffMs: 35_000, now: () => t });
  assertEquals(c.count(), 1, "fallback skipped");
  assert(!r.ok && r.error === "validation_failed");
  assertEquals(r.attempts[1].reasons, ["skipped: out of time"]);
});

Deno.test("step numbers are stripped", () => {
  assertEquals(stripStepNumber("1. Heat the oil."), "Heat the oil.");
  assertEquals(stripStepNumber("Step 2: Add garlic"), "Add garlic");
  assertEquals(stripStepNumber("2 eggs go in"), "2 eggs go in");
});
