import { assert, assertAlmostEquals, assertEquals } from "jsr:@std/assert@1";
import {
  computeMacros, type IngredientInfo, type IngredientStore, normalizeUnit, type Nutrients,
  resolveIngredients, roundForDisplay, toGrams,
} from "./macros.ts";

// USDA SR Legacy values per 100 g, as in catalog_seed.csv.
const CHICKEN: Nutrients = { kcal: 120, protein_g: 22.5, carbs_g: 0, fat_g: 2.62, fiber_g: 0, sugar_g: 0, sodium_mg: 45 };
const RICE: Nutrients = { kcal: 365, protein_g: 7.13, carbs_g: 79.95, fat_g: 0.66, fiber_g: 1.3, sugar_g: 0.12, sodium_mg: 5 };
const EGG: Nutrients = { kcal: 143, protein_g: 12.56, carbs_g: 0.72, fat_g: 9.51, fiber_g: 0, sugar_g: 0.37, sodium_mg: 142 };
const BUTTER: Nutrients = { kcal: 717, protein_g: 0.85, carbs_g: 0.06, fat_g: 81.11, fiber_g: 0, sugar_g: 0.06, sodium_mg: 643 };

const info = (n: Nutrients | null, extra: Partial<IngredientInfo> = {}): IngredientInfo =>
  ({ grams_per_unit: null, density_g_per_ml: null, nutrients: n, estimated: false, ...extra });

const CATALOG = new Map<number, IngredientInfo>([
  [52, info(CHICKEN)],
  [67, info(RICE, { density_g_per_ml: 0.78 })],
  [38, info(EGG, { grams_per_unit: 50 })],
  [40, info(BUTTER, { density_g_per_ml: 0.946 })],
]);

Deno.test("fixture: 200 g chicken breast + 100 g rice matches USDA within 1%", () => {
  const m = computeMacros([
    { ingredient_id: 52, name: "chicken breast", quantity: 200, unit: "g" },
    { ingredient_id: 67, name: "white rice", quantity: 100, unit: "g" },
  ], 2, CATALOG);
  // By hand: 2 × chicken + 1 × rice.
  const expected = { kcal: 605, protein_g: 52.13, carbs_g: 79.95, fat_g: 5.9, sodium_mg: 95 };
  for (const [k, v] of Object.entries(expected)) {
    const got = m.total[k as keyof Nutrients];
    assert(Math.abs(got - v) <= v * 0.01, `${k}: ${got} vs ${v}`);
  }
  assertAlmostEquals(m.per_serving.kcal, 302.5, 0.01);
  assertEquals(m.total.estimated, false);
  assertEquals(m.total.coverage, 1);
});

Deno.test("units: weights", () => {
  assertEquals(toGrams(1, "kg", undefined).grams, 1000);
  assertAlmostEquals(toGrams(2, "oz", undefined).grams!, 56.699, 0.001);
  assertAlmostEquals(toGrams(1, "lb", undefined).grams!, 453.592, 0.001);
  assertEquals(toGrams(1, "kg", undefined).estimated, false);
});

Deno.test("units: volume uses density, or water with estimated", () => {
  assertAlmostEquals(toGrams(1, "cup", { grams_per_unit: null, density_g_per_ml: 0.78 }).grams!, 187.2, 0.001);
  assertAlmostEquals(toGrams(2, "tbsp", { grams_per_unit: null, density_g_per_ml: 0.946 }).grams!, 28.38, 0.001);
  assertEquals(toGrams(1, "tsp", { grams_per_unit: null, density_g_per_ml: 1 }).grams, 5);
  assertEquals(toGrams(0.5, "l", { grams_per_unit: null, density_g_per_ml: 1.03 }).estimated, false);
  assertEquals(toGrams(1, "cup", undefined), { grams: 240, estimated: true });
  // The model's gram hint beats the water guess.
  assertEquals(toGrams(1, "cup", undefined, 30), { grams: 30, estimated: true });
});

Deno.test("units: per-unit, hint, or not convertible", () => {
  assertEquals(toGrams(3, "each", { grams_per_unit: 50, density_g_per_ml: null }), { grams: 150, estimated: false });
  assertEquals(toGrams(2, "pieces", { grams_per_unit: 50, density_g_per_ml: null }).grams, 100);
  assertEquals(toGrams(2, "each", undefined, 340), { grams: 340, estimated: true });
  assertEquals(toGrams(2, "each", undefined), { grams: null, estimated: true });
  assertEquals(toGrams(3, "clove", { grams_per_unit: 50, density_g_per_ml: null }).grams, null,
    "unknown count words don't use grams_per_unit");
  assertEquals(toGrams(3, "clove", undefined, 9).grams, 9);
});

Deno.test("units: pinch, to taste, missing quantity, aliases", () => {
  assertEquals(toGrams(1, "pinch", undefined), { grams: 0.5, estimated: false });
  assertEquals(toGrams(2, "pinches", undefined).grams, 1);
  assertEquals(toGrams(null, "to taste", undefined), { grams: 0, estimated: false });
  assertEquals(toGrams(null, "g", undefined).grams, null);
  assertEquals(normalizeUnit("Tablespoons"), "tbsp");
  assertEquals(normalizeUnit("cups"), "cup");
  assertEquals(normalizeUnit("lbs."), "lb");
  assertEquals(normalizeUnit(null), "each");
});

Deno.test("optional ingredients aren't counted; servings divide", () => {
  const m = computeMacros([
    { ingredient_id: 38, name: "egg", quantity: 2, unit: "each" },
    { ingredient_id: 40, name: "butter", quantity: 1, unit: "tbsp", is_optional: true },
  ], 2, CATALOG);
  assertAlmostEquals(m.total.kcal, 143, 0.001);
  assertAlmostEquals(m.per_serving.kcal, 71.5, 0.001);
  assertEquals(m.total.estimated, false);
});

Deno.test("coverage and estimated flags", () => {
  // 100 g chicken + 100 g of something with no data: coverage 0.5 -> estimated.
  const half = computeMacros([
    { ingredient_id: 52, name: "chicken breast", quantity: 100, unit: "g" },
    { ingredient_id: null, name: "mystery sauce", quantity: 100, unit: "g" },
  ], 1, CATALOG);
  assertEquals(half.total.coverage, 0.5);
  assertEquals(half.total.estimated, true);
  // 5% unknown: coverage 0.95, still not estimated.
  const most = computeMacros([
    { ingredient_id: 52, name: "chicken breast", quantity: 950, unit: "g" },
    { ingredient_id: null, name: "mystery sauce", quantity: 50, unit: "g" },
  ], 1, CATALOG);
  assertAlmostEquals(most.total.coverage, 0.95, 1e-9);
  assertEquals(most.total.estimated, false);
  // A count we can't convert -> estimated, even though coverage of the rest is 1.
  const uncountable = computeMacros([
    { ingredient_id: 52, name: "chicken breast", quantity: 2, unit: "each" },
    { ingredient_id: 67, name: "white rice", quantity: 100, unit: "g" },
  ], 1, CATALOG);
  assertEquals(uncountable.total.estimated, true);
  // A small guessed amount (a clove of garlic by gram hint) doesn't make the recipe "≈"...
  const clove = computeMacros([
    { ingredient_id: 52, name: "chicken breast", quantity: 500, unit: "g" },
    { ingredient_id: 52, name: "garlic", quantity: 1, unit: "clove", grams: 5 },
  ], 1, CATALOG);
  assertEquals(clove.total.estimated, false);
  // ...but a large one does (2 chicken breasts by gram hint: all of the weight).
  const hinted = computeMacros([{ ingredient_id: 52, name: "chicken breast", quantity: 2, unit: "each", grams: 340 }], 1, CATALOG);
  assertEquals([hinted.total.estimated, Math.round(hinted.total.kcal)], [true, 408]);
  // AI-estimated nutrients -> estimated.
  const custom = new Map(CATALOG).set(1_000_000_000_001, info(RICE, { estimated: true }));
  assertEquals(computeMacros([{ ingredient_id: 1_000_000_000_001, name: "x", quantity: 100, unit: "g" }], 1, custom)
    .total.estimated, true);
  // Nothing countable at all.
  const none = computeMacros([{ name: "x", quantity: 1, unit: "each" }], 1, CATALOG);
  assertEquals([none.total.kcal, none.total.coverage, none.total.estimated], [0, 0, true]);
});

Deno.test("display rounding", () => {
  assertEquals(roundForDisplay({ kcal: 302.5, protein_g: 26.07, carbs_g: 39.9, fat_g: 2.95, fiber_g: 0.65, sugar_g: 0.06, sodium_mg: 47.5 }),
    { kcal: 300, protein_g: 26, carbs_g: 40, fat_g: 3, fiber_g: 1, sugar_g: 0, sodium_mg: 48 });
});

// ------------------------------------------------------------ loading (fake store)

function fakeStore() {
  const customs = new Map<number, { name: string; nutrients: Nutrients | null }>([
    [1_000_000_000_001, { name: "gochujang", nutrients: null }],
  ]);
  const store: IngredientStore & { saved: number } = {
    saved: 0,
    searchCatalog: (name) => Promise.resolve(
      name === "chicken breasts" ? { id: 52, score: 0.9 } : name === "chickpea pasta" ? { id: 67, score: 0.4 } : null),
    catalogInfo: (ids) => Promise.resolve(new Map(ids.flatMap((id) => (CATALOG.has(id) ? [[id, CATALOG.get(id)!]] : [])))),
    customItems: (ids) => Promise.resolve(new Map(ids.flatMap((id) => (customs.has(id) ? [[id, { ...customs.get(id)! }]] : [])))),
    saveCustomNutrients: (id, n) => {
      customs.set(id, { ...customs.get(id)!, nutrients: n });
      store.saved++;
      return Promise.resolve();
    },
  };
  return store;
}

Deno.test("free text: matched at score >= 0.6, otherwise not counted", async () => {
  const { ingredients } = await resolveIngredients([
    { name: "chicken breasts", quantity: 200, unit: "g" },
    { name: "chickpea pasta", quantity: 100, unit: "g" },
  ], fakeStore(), null);
  assertEquals(ingredients.map((i) => i.ingredient_id ?? null), [52, null]);
});

Deno.test("custom item without nutrition: estimated exactly once, then the stored value is used", async () => {
  const store = fakeStore();
  let calls = 0;
  const estimate = (_: string) => {
    calls++;
    return Promise.resolve({ ...RICE, kcal: 200 });
  };
  const recipe = [{ ingredient_id: 1_000_000_000_001, name: "gochujang", quantity: 2, unit: "tbsp" }];
  for (let i = 0; i < 2; i++) {
    const { ingredients, info } = await resolveIngredients(recipe, store, estimate);
    const m = computeMacros(ingredients, 1, info);
    assertAlmostEquals(m.total.kcal, 60, 0.001); // 30 g (water guess) × 200 / 100
    assertEquals(m.total.estimated, true);
  }
  assertEquals(calls, 1);
  assertEquals(store.saved, 1);
});

Deno.test("no AI access: custom item without nutrition counts as no data", async () => {
  const { ingredients, info } = await resolveIngredients(
    [{ ingredient_id: 1_000_000_000_001, name: "gochujang", quantity: 100, unit: "g" }], fakeStore(), null);
  const m = computeMacros(ingredients, 1, info);
  assertEquals([m.total.kcal, m.total.coverage, m.total.estimated], [0, 0, true]);
});
