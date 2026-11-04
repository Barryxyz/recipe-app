// deno test supabase/functions/_shared/scan_test.ts
// F1.2 post-processing against made-up model output; no AI, no database.
import { buildDraft, classify, type ModelItem, normalizeName, normalizeUnit, type SearchHit, singularize } from "./scan.ts";

/** Deep equality with object keys in sorted order. */
function canon(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(canon);
  if (v && typeof v === "object") {
    return Object.fromEntries(Object.keys(v as object).sort().map((k) => [k, canon((v as Record<string, unknown>)[k])]));
  }
  return v;
}
function eq(a: unknown, b: unknown, msg = "") {
  if (JSON.stringify(canon(a)) !== JSON.stringify(canon(b))) {
    throw new Error(`${msg}: expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
  }
}

// A tiny catalog, scored like app.search_ingredients.
const CATALOG = [
  { id: 38, name: "egg", aliases: ["eggs"], category: "dairy", default_unit: "each", staple: false },
  { id: 39, name: "milk", aliases: ["whole milk"], category: "dairy", default_unit: "ml", staple: false },
  { id: 10, name: "tomato", aliases: ["tomatoes"], category: "produce", default_unit: "each", staple: false },
  { id: 12, name: "green onion", aliases: ["scallion", "spring onion"], category: "produce", default_unit: "each", staple: false },
  { id: 89, name: "soy sauce", aliases: ["shoyu"], category: "condiments", default_unit: "ml", staple: true },
  { id: 80, name: "cumin", aliases: ["ground cumin"], category: "spices", default_unit: "g", staple: false },
  { id: 6, name: "strawberries", aliases: ["strawberry"], category: "produce", default_unit: "g", staple: false },
  { id: 41, name: "cheddar cheese", aliases: ["cheddar"], category: "dairy", default_unit: "g", staple: false },
];
const CUSTOM = [{ id: 1000000000024, name: "quail" }];

async function search(q: string): Promise<SearchHit | null> {
  const hits: SearchHit[] = [];
  for (const c of CATALOG) {
    const terms = [c.name, ...c.aliases];
    const score = terms.includes(q) ? 1 : terms.some((t) => t.startsWith(q)) ? 0.9
      : terms.some((t) => t.includes(q) || q.includes(t)) ? 0.55 : 0;
    if (score) hits.push({ id: c.id, name: c.name, category: c.category, default_unit: c.default_unit, is_custom: false, score });
  }
  for (const c of CUSTOM) if (c.name === q) hits.unshift({ id: c.id, name: c.name, category: null, default_unit: "each", is_custom: true, score: 1 });
  hits.sort((a, b) => b.score - a.score);
  return hits[0] ?? null;
}
const lookups = {
  search,
  catalog: async (ids: number[]) =>
    new Map(CATALOG.filter((c) => ids.includes(c.id)).map((c) => [c.id, { category: c.category, is_common_staple: c.staple }])),
};
const item = (name: string, o: Partial<ModelItem> = {}): ModelItem =>
  ({ name, quantity: 1, unit: "each", confidence: 0.9, photo_index: 0, ...o });

Deno.test("normalize, singularize, units", () => {
  eq(normalizeName("  Cheddar   Cheese. "), "cheddar cheese");
  eq(singularize("eggs"), "egg");
  eq(singularize("cherry tomatoes"), "cherry tomato");
  eq(singularize("berries"), "berry");
  eq(singularize("peaches"), "peach");
  eq(singularize("hummus"), null, "hummus");
  eq(singularize("asparagus"), null, "asparagus");
  eq(singularize("rice"), null, "no plural");
  eq(normalizeUnit("Grams"), "g");
  eq(normalizeUnit("carton"), "each");
  eq(normalizeUnit("handful"), null, "unknown units become null");
});

Deno.test("match types: exact, alias, fuzzy, none", async () => {
  eq(classify("egg", await search("egg")), "exact");
  eq(classify("scallion", await search("scallion")), "alias");
  eq(classify("chedd", await search("chedd")), "fuzzy");
  eq(classify("dragonfruit", await search("dragonfruit")), "none");
  const d = await buildDraft([item("Eggs", { quantity: 6 }), item("scallions"), item("dragon fruit")], 1, lookups);
  const by = Object.fromEntries(d.map((x) => [x.name, x]));
  eq([by["eggs"].ingredient_id, by["eggs"].match], [38, "alias"], "eggs is an alias of egg");
  eq([by["scallions"].ingredient_id, by["scallions"].match], [12, "alias"], "plural matched via singular");
  eq([by["dragon fruit"].ingredient_id, by["dragon fruit"].match, by["dragon fruit"].display_name], [null, "none", "dragon fruit"]);
});

Deno.test("matches the user's custom items", async () => {
  const d = await buildDraft([item("quail", { quantity: 4 })], 1, lookups);
  eq([d[0].ingredient_id, d[0].match], [1000000000024, "exact"]);
});

Deno.test("merges the same item seen in overlapping photos: max quantity, min confidence", async () => {
  const d = await buildDraft([
    item("egg", { quantity: 6, confidence: 0.95, photo_index: 0 }),
    item("eggs", { quantity: 4, confidence: 0.7, photo_index: 1 }),
    item("milk", { quantity: 1000, unit: "ml", photo_index: 1 }),
  ], 2, lookups);
  const egg = d.find((x) => x.ingredient_id === 38)!;
  eq([d.length, egg.quantity, egg.confidence, egg.photo_indexes], [2, 6, 0.7, [0, 1]]);
});

Deno.test("different units stay separate", async () => {
  const d = await buildDraft([item("milk", { quantity: 1, unit: "l" }), item("milk", { quantity: 500, unit: "ml" })], 1, lookups);
  eq(d.length, 2);
});

Deno.test("\"some\" plus a number keeps the number", async () => {
  const d = await buildDraft([item("tomato", { quantity: null }), item("tomatoes", { quantity: 3, photo_index: 1 })], 2, lookups);
  eq([d.length, d[0].quantity], [1, 3]);
});

Deno.test("low confidence: below 0.6 or a fuzzy match", async () => {
  const d = await buildDraft([item("milk", { confidence: 0.5, unit: "ml" }), item("chedd"), item("egg")], 1, lookups);
  const by = Object.fromEntries(d.map((x) => [x.name, x.low_confidence]));
  eq(by, { milk: true, chedd: true, egg: false });
});

Deno.test("staple suggestions: spices and common staples", async () => {
  const d = await buildDraft([item("cumin", { unit: "g" }), item("soy sauce", { unit: "ml" }), item("milk", { unit: "ml" })], 1, lookups);
  const by = Object.fromEntries(d.map((x) => [x.name, x.suggest_staple]));
  eq(by, { cumin: true, "soy sauce": true, milk: false });
});

Deno.test("sorted by category (unknown last), then name; temp ids in order", async () => {
  const d = await buildDraft([item("tomato"), item("mystery jar"), item("milk", { unit: "ml" }), item("egg")], 1, lookups);
  eq(d.map((x) => x.display_name), ["egg", "milk", "tomato", "mystery jar"]);
  eq(d.map((x) => x.temp_id), ["t1", "t2", "t3", "t4"]);
});

Deno.test("cleans up bad model values", async () => {
  const d = await buildDraft([
    item("egg", { quantity: -3, confidence: 7, photo_index: 9, unit: "dozenish" }),
    item("   ", {}),
  ], 2, lookups);
  eq(d.length, 1, "blank names dropped");
  eq([d[0].quantity, d[0].confidence, d[0].photo_indexes, d[0].unit], [null, 1, [0], "each"],
    "negative quantity -> some, confidence clamped, bad photo index -> 0, unknown unit -> catalog default");
});

Deno.test("no food -> empty list", async () => {
  eq(await buildDraft([], 1, lookups), []);
});
