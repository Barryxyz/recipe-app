// F2.3: recipe nutrition, calculated from catalog data, never by the model.
// Pure maths here (computeMacros, toGrams); data loading in resolveIngredients, which takes a
// store so it can be tested without a database.

export const NUTRIENT_KEYS = ["kcal", "protein_g", "carbs_g", "fat_g", "fiber_g", "sugar_g", "sodium_mg"] as const;
export type NutrientKey = typeof NUTRIENT_KEYS[number];
export type Nutrients = Record<NutrientKey, number>;

export interface Macros extends Nutrients {
  /** Over 10% of the weight is guessed, coverage < 0.9, or an ingredient couldn't be counted: show "≈". */
  estimated: boolean;
  /** Share of the counted weight that has nutrition data (0–1). */
  coverage: number;
}

export interface MacroResult {
  per_serving: Macros;
  total: Macros;
}

/** One recipe ingredient, as stored in app.recipe_ingredients. */
export interface RecipeIngredient {
  ingredient_id?: number | null;
  name: string;
  quantity?: number | null;
  unit?: string | null;
  is_optional?: boolean;
  /** The model's own gram estimate (F2.2). Used only when we can't convert ourselves. */
  grams?: number | null;
}

/** What the maths needs to know about one ingredient. */
export interface IngredientInfo {
  grams_per_unit: number | null;
  density_g_per_ml: number | null;
  /** Per 100 g. Null: no data (the ingredient's weight counts against coverage). */
  nutrients: Partial<Nutrients> | null;
  /** The nutrients are an AI estimate (custom items). */
  estimated: boolean;
}

export const CUSTOM_ID_START = 1_000_000_000_000;
/** Free-text names must match a catalog item at least this well (F2.3 step 2). */
export const FREE_TEXT_MIN_SCORE = 0.6;

const WEIGHT_G: Record<string, number> = { g: 1, kg: 1000, oz: 28.3495, lb: 453.592 };
const VOLUME_ML: Record<string, number> = { ml: 1, l: 1000, tsp: 5, tbsp: 15, cup: 240 };
const COUNT = new Set(["each", "bunch", "pack"]);
const TINY_G: Record<string, number> = { pinch: 0.5, dash: 0.5, "to taste": 0 };

const ALIASES: Record<string, string> = {
  gram: "g", grams: "g", gr: "g", kilogram: "kg", kilograms: "kg", kgs: "kg",
  ounce: "oz", ounces: "oz", pound: "lb", pounds: "lb", lbs: "lb",
  milliliter: "ml", milliliters: "ml", millilitre: "ml", millilitres: "ml",
  liter: "l", liters: "l", litre: "l", litres: "l",
  teaspoon: "tsp", teaspoons: "tsp", tsps: "tsp", tablespoon: "tbsp", tablespoons: "tbsp", tbsps: "tbsp",
  cups: "cup",
  piece: "each", pieces: "each", whole: "each", ea: "each", "": "each",
  bunches: "bunch", packs: "pack", package: "pack", packages: "pack",
  pinches: "pinch", dashes: "dash",
};

/** "Tablespoons" -> "tbsp". Unknown units come back lowercased (e.g. "clove", "can"). */
export function normalizeUnit(unit: string | null | undefined): string {
  const u = (unit ?? "").trim().toLowerCase().replace(/\.$/, "");
  return ALIASES[u] ?? u;
}

/**
 * Grams for an amount. `estimated` when a guess was involved (no density, or the model's
 * gram hint). `grams: null` means it can't be converted at all.
 */
export function toGrams(
  quantity: number | null | undefined,
  unit: string | null | undefined,
  info: Pick<IngredientInfo, "grams_per_unit" | "density_g_per_ml"> | undefined,
  hint?: number | null,
): { grams: number | null; estimated: boolean } {
  const u = normalizeUnit(unit);
  if (u in TINY_G) return { grams: TINY_G[u] * (quantity ?? 1), estimated: false };
  const hinted = hint != null && hint >= 0 ? { grams: hint, estimated: true } : null;
  if (quantity == null) return hinted ?? { grams: null, estimated: true };

  if (u in WEIGHT_G) return { grams: quantity * WEIGHT_G[u], estimated: false };
  if (u in VOLUME_ML) {
    const ml = quantity * VOLUME_ML[u];
    if (info?.density_g_per_ml) return { grams: ml * info.density_g_per_ml, estimated: false };
    return hinted ?? { grams: ml, estimated: true };   // water-like guess
  }
  if (COUNT.has(u) && info?.grams_per_unit) return { grams: quantity * info.grams_per_unit, estimated: false };
  return hinted ?? { grams: null, estimated: true };
}

function zero(): Nutrients {
  return { kcal: 0, protein_g: 0, carbs_g: 0, fat_g: 0, fiber_g: 0, sugar_g: 0, sodium_mg: 0 };
}

/**
 * Totals and per-serving values, unrounded. `info` is looked up by ingredient_id (after free
 * text has been matched to the catalog, see resolveIngredients).
 */
export function computeMacros(
  ingredients: RecipeIngredient[],
  servings: number | null | undefined,
  info: Map<number, IngredientInfo>,
): MacroResult {
  const total = zero();
  let countedGrams = 0;
  let coveredGrams = 0;
  /** Grams whose weight or nutrition was guessed (gram hint, water density, AI estimate). */
  let guessedGrams = 0;
  let estimated = false;

  for (const ing of ingredients) {
    if (ing.is_optional) continue;
    const data = ing.ingredient_id != null ? info.get(ing.ingredient_id) : undefined;
    const { grams, estimated: guessed } = toGrams(ing.quantity, ing.unit, data, ing.grams);
    if (grams === null) {
      estimated = true;            // can't be counted at all
      continue;
    }
    countedGrams += grams;
    if (guessed || data?.estimated) guessedGrams += grams;
    if (!data?.nutrients) continue; // weight known, nutrition unknown: lowers coverage
    coveredGrams += grams;
    for (const k of NUTRIENT_KEYS) total[k] += (grams / 100) * (data.nutrients[k] ?? 0);
  }

  const coverage = countedGrams > 0 ? coveredGrams / countedGrams : (estimated ? 0 : 1);
  // "≈" when more than 10% of the weight is unknown or guessed; a clove of garlic doesn't count.
  if (coverage < 0.9 || (countedGrams > 0 && guessedGrams / countedGrams > 0.1)) estimated = true;
  const n = servings && servings > 0 ? servings : 1;
  const per = zero();
  for (const k of NUTRIENT_KEYS) per[k] = total[k] / n;
  return {
    total: { ...total, estimated, coverage },
    per_serving: { ...per, estimated, coverage },
  };
}

/** Display rounding (F2.3 step 5): kcal to the nearest 10, the rest to whole numbers. */
export function roundForDisplay(m: Nutrients): Nutrients {
  const out = zero();
  for (const k of NUTRIENT_KEYS) out[k] = k === "kcal" ? Math.round(m[k] / 10) * 10 : Math.round(m[k]);
  return out;
}

// ---------------------------------------------------------------- loading

/** Where ingredient data comes from (Supabase in production, a fake in tests). */
export interface IngredientStore {
  /** Best catalog match for a free-text name: id and score, or null. */
  searchCatalog(name: string): Promise<{ id: number; score: number } | null>;
  catalogInfo(ids: number[]): Promise<Map<number, IngredientInfo>>;
  /** The user's custom items: name and stored nutrients (null until estimated). */
  customItems(ids: number[]): Promise<Map<number, { name: string; nutrients: Nutrients | null }>>;
  saveCustomNutrients(id: number, nutrients: Nutrients): Promise<void>;
}

/** Asks the model for a typical per-100 g profile; null if it fails (F0.5 estimateNutrition). */
export type Estimator = (name: string) => Promise<Nutrients | null>;

/**
 * Matches free-text ingredients to the catalog, loads catalog and custom-item data, and
 * estimates nutrition once for custom items that have none (storing it). `estimate` is null
 * when the user has no AI access: such items then count as "no data".
 * Returns the ingredients with matched ids filled in, and the info map for computeMacros.
 */
export async function resolveIngredients(
  ingredients: RecipeIngredient[],
  store: IngredientStore,
  estimate: Estimator | null,
): Promise<{ ingredients: RecipeIngredient[]; info: Map<number, IngredientInfo> }> {
  const resolved = await Promise.all(ingredients.map(async (ing) => {
    if (ing.ingredient_id != null || ing.is_optional) return ing;
    const hit = await store.searchCatalog(ing.name);
    return hit && hit.score >= FREE_TEXT_MIN_SCORE ? { ...ing, ingredient_id: hit.id } : ing;
  }));

  const ids = [...new Set(resolved.flatMap((i) => (i.ingredient_id != null && !i.is_optional ? [i.ingredient_id] : [])))];
  const catalogIds = ids.filter((id) => id < CUSTOM_ID_START);
  const customIds = ids.filter((id) => id >= CUSTOM_ID_START);

  const [info, custom] = await Promise.all([
    catalogIds.length ? store.catalogInfo(catalogIds) : Promise.resolve(new Map<number, IngredientInfo>()),
    customIds.length ? store.customItems(customIds) : Promise.resolve(new Map()),
  ]);

  await Promise.all([...custom.entries()].map(async ([id, item]) => {
    let nutrients = item.nutrients;
    if (!nutrients && estimate) {
      nutrients = await estimate(item.name);
      if (nutrients) await store.saveCustomNutrients(id, nutrients);
    }
    info.set(id, { grams_per_unit: null, density_g_per_ml: null, nutrients, estimated: true });
  }));

  return { ingredients: resolved, info };
}
