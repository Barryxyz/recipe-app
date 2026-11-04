// F1.2: turns the scan model's raw items into the draft list for review (F1.3).
// Pure apart from the injected lookups, so it's unit tested without AI or a database
// (scan_test.ts).

export interface ModelItem {
  name: string;
  quantity: number | null;
  unit: string | null;
  confidence: number;
  photo_index: number;
}

/** A search hit (app.search_ingredients): catalog or the user's custom items. */
export interface SearchHit {
  id: number;
  name: string;
  category: string | null;
  default_unit: string | null;
  is_custom: boolean;
  score: number;
}

export interface CatalogInfo {
  category: string | null;
  is_common_staple: boolean;
}

export type Match = "exact" | "alias" | "fuzzy" | "none";

export interface DraftItem {
  temp_id: string;
  name: string;
  ingredient_id: number | null;
  /** Catalog/custom name when matched, else the cleaned model name. */
  display_name: string;
  category: string | null;
  match: Match;
  quantity: number | null;
  unit: string | null;
  confidence: number;
  low_confidence: boolean;
  /** Spices and common staples: F1.3 files them under Seasonings & Staples. */
  suggest_staple: boolean;
  photo_indexes: number[];
}

export interface Lookups {
  /** Best search hit for a name, or null. */
  search: (name: string) => Promise<SearchHit | null>;
  /** Category and staple flag for catalog ids. */
  catalog: (ids: number[]) => Promise<Map<number, CatalogInfo>>;
}

export const FUZZY_MIN_SCORE = 0.5;
export const LOW_CONFIDENCE = 0.6;

const UNITS = new Set(["each", "g", "kg", "ml", "l", "oz", "lb", "cup", "tbsp", "tsp", "bunch", "pack"]);
const UNIT_ALIASES: Record<string, string> = {
  piece: "each", pieces: "each", item: "each", items: "each", whole: "each", unit: "each",
  gram: "g", grams: "g", kilogram: "kg", kilograms: "kg", milliliter: "ml", milliliters: "ml",
  millilitre: "ml", millilitres: "ml", liter: "l", liters: "l", litre: "l", litres: "l",
  ounce: "oz", ounces: "oz", pound: "lb", pounds: "lb", lbs: "lb", cups: "cup",
  package: "pack", packages: "pack", packet: "pack", packets: "pack", bunches: "bunch",
  carton: "each", cartons: "each", bottle: "each", bottles: "each", jar: "each", jars: "each",
  can: "each", cans: "each", bag: "pack", bags: "pack", box: "pack", boxes: "pack",
};

/** Lowercase, trim, single spaces, no trailing punctuation. */
export function normalizeName(name: string): string {
  return name.toLowerCase().replace(/\s+/g, " ").trim().replace(/[.,;:!]+$/g, "").trim();
}

/** Simple singular form for the last word ("cherry tomatoes" -> "cherry tomato"), or null. */
export function singularize(name: string): string | null {
  const words = name.split(" ");
  const last = words[words.length - 1];
  let s: string | null = null;
  if (last.length <= 3 || /(ss|us|is|as)$/.test(last)) return null;   // glass, hummus, asparagus
  if (last.endsWith("ies")) s = last.slice(0, -3) + "y";              // berries
  else if (last.endsWith("oes")) s = last.slice(0, -2);              // tomatoes
  else if (/(ches|shes|xes)$/.test(last)) s = last.slice(0, -2);     // peaches, radishes
  else if (last.endsWith("s")) s = last.slice(0, -1);                // eggs
  if (!s) return null;
  words[words.length - 1] = s;
  return words.join(" ");
}

export function normalizeUnit(unit: string | null): string | null {
  if (!unit) return null;
  const u = unit.toLowerCase().trim();
  if (UNITS.has(u)) return u;
  return UNIT_ALIASES[u] ?? null;
}

/** exact: the hit's own name; alias: one of its aliases (score 1); fuzzy: anything weaker. */
export function classify(query: string, hit: SearchHit | null): Match {
  if (!hit || hit.score < FUZZY_MIN_SCORE) return "none";
  if (hit.score >= 1) return normalizeName(hit.name) === query ? "exact" : "alias";
  return "fuzzy";
}

export async function buildDraft(modelItems: ModelItem[], photoCount: number, lookups: Lookups): Promise<DraftItem[]> {
  // 1. Clean up; drop nonsense.
  const cleaned = modelItems
    .map((m) => ({
      ...m,
      name: normalizeName(m.name ?? ""),
      quantity: typeof m.quantity === "number" && Number.isFinite(m.quantity) && m.quantity > 0 ? m.quantity : null,
      unit: normalizeUnit(m.unit),
      confidence: Math.min(1, Math.max(0, Number.isFinite(m.confidence) ? m.confidence : 0)),
      photo_index: Number.isInteger(m.photo_index) && m.photo_index >= 0 && m.photo_index < photoCount ? m.photo_index : 0,
    }))
    .filter((m) => m.name.length > 0 && m.name.length <= 100);

  // 2. Match each distinct name once (plain, then singular).
  const matches = new Map<string, { hit: SearchHit | null; match: Match }>();
  for (const name of new Set(cleaned.map((m) => m.name))) {
    let hit = await lookups.search(name);
    let match = classify(name, hit);
    if (match !== "exact" && match !== "alias") {
      const singular = singularize(name);
      if (singular) {
        const h2 = await lookups.search(singular);
        const m2 = classify(singular, h2);
        if (m2 === "exact" || m2 === "alias" || (m2 === "fuzzy" && (h2?.score ?? 0) > (hit?.score ?? 0))) {
          hit = h2;
          match = m2;
        }
      }
    }
    matches.set(name, { hit: match === "none" ? null : hit, match });
  }

  const catalogIds = [...new Set([...matches.values()]
    .filter((m) => m.hit && !m.hit.is_custom).map((m) => m.hit!.id))];
  const info = catalogIds.length ? await lookups.catalog(catalogIds) : new Map<number, CatalogInfo>();

  // 3. Merge duplicates: same ingredient (or same name when unmatched) and same unit.
  //    Overlapping photos can show the same item twice, so take the max, not the sum.
  const merged = new Map<string, DraftItem>();
  for (const m of cleaned) {
    const { hit, match } = matches.get(m.name)!;
    const key = `${hit ? `id:${hit.id}` : `name:${m.name}`}|${m.unit ?? ""}`;
    const existing = merged.get(key);
    if (existing) {
      existing.quantity = existing.quantity === null ? m.quantity
        : m.quantity === null ? existing.quantity : Math.max(existing.quantity, m.quantity);
      existing.confidence = Math.min(existing.confidence, m.confidence);
      if (!existing.photo_indexes.includes(m.photo_index)) existing.photo_indexes.push(m.photo_index);
      continue;
    }
    const cat = hit && !hit.is_custom ? info.get(hit.id) : undefined;
    const category = hit?.category ?? cat?.category ?? null;
    merged.set(key, {
      temp_id: "",
      name: m.name,
      ingredient_id: hit?.id ?? null,
      display_name: hit?.name ?? m.name,
      category,
      match,
      quantity: m.quantity,
      unit: m.unit ?? hit?.default_unit ?? null,
      confidence: m.confidence,
      low_confidence: false,
      suggest_staple: category === "spices" || cat?.is_common_staple === true,
      photo_indexes: [m.photo_index],
    });
  }

  // 4. Flags, 5. sort by category (unknown last), then name.
  const items = [...merged.values()];
  for (const it of items) {
    it.low_confidence = it.confidence < LOW_CONFIDENCE || it.match === "fuzzy";
    it.photo_indexes.sort((a, b) => a - b);
  }
  items.sort((a, b) =>
    (a.category === null ? 1 : 0) - (b.category === null ? 1 : 0) ||
    (a.category ?? "").localeCompare(b.category ?? "") ||
    a.display_name.localeCompare(b.display_name));
  items.forEach((it, i) => (it.temp_id = `t${i + 1}`));
  return items;
}
