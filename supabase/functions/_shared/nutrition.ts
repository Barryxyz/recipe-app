// F2.3: Supabase-backed ingredient data for the macros calculator, and the one-time
// nutrition estimate for custom items (F0.5 estimateNutrition).
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.118.0";
import { z } from "npm:zod@4.6.7";
import { callModel } from "./ai.ts";
import { effortFor, modelFor } from "./config.ts";
import type { Estimator, IngredientInfo, IngredientStore, Nutrients } from "./macros.ts";

/** Per 100 g; bounds reject impossible answers (nothing is over 900 kcal / 100 g). */
export const NutrientsSchema = z.object({
  kcal: z.number().min(0).max(900),
  protein_g: z.number().min(0).max(100),
  carbs_g: z.number().min(0).max(100),
  fat_g: z.number().min(0).max(100),
  fiber_g: z.number().min(0).max(100),
  sugar_g: z.number().min(0).max(100),
  sodium_mg: z.number().min(0).max(40000),
});

const num = (v: unknown) => (v == null ? null : Number(v));

/** Reads as the signed-in user (RLS): their own custom items only. */
export function supabaseStore(supabase: SupabaseClient): IngredientStore {
  return {
    async searchCatalog(name) {
      const { data, error } = await supabase.schema("catalog").rpc("search_ingredients", { q: name, lim: 1 });
      if (error || !data?.length) return null;
      return { id: Number(data[0].id), score: Number(data[0].score) };
    },
    async catalogInfo(ids) {
      const { data, error } = await supabase.schema("catalog").from("ingredients")
        .select("id, grams_per_unit, density_g_per_ml, ingredient_nutrients(kcal, protein_g, carbs_g, fat_g, fiber_g, sugar_g, sodium_mg)")
        .in("id", ids);
      if (error) throw error;
      const out = new Map<number, IngredientInfo>();
      for (const row of data ?? []) {
        const n = Array.isArray(row.ingredient_nutrients) ? row.ingredient_nutrients[0] : row.ingredient_nutrients;
        out.set(Number(row.id), {
          grams_per_unit: num(row.grams_per_unit),
          density_g_per_ml: num(row.density_g_per_ml),
          nutrients: n
            ? Object.fromEntries(Object.entries(n).map(([k, v]) => [k, num(v) ?? 0])) as Partial<Nutrients>
            : null,
          estimated: false,
        });
      }
      return out;
    },
    async customItems(ids) {
      const { data, error } = await supabase.schema("app").from("ingredients_private")
        .select("id, name, nutrients_per_100g").in("id", ids).is("deleted_at", null);
      if (error) throw error;
      const out = new Map<number, { name: string; nutrients: Nutrients | null }>();
      for (const row of data ?? []) {
        const parsed = NutrientsSchema.safeParse(row.nutrients_per_100g);
        out.set(Number(row.id), { name: row.name, nutrients: parsed.success ? parsed.data : null });
      }
      return out;
    },
    async saveCustomNutrients(id, nutrients) {
      const { error } = await supabase.schema("app").from("ingredients_private")
        .update({ nutrients_per_100g: nutrients, is_estimated: true }).eq("id", id);
      if (error) throw error;
    },
  };
}

/** One cheap model call per custom item, ever (the result is stored). Logged as kind 'estimate'. */
export function nutritionEstimator(userId: string, supabaseAdmin: SupabaseClient): Estimator {
  return async (name) => {
    const r = await callModel({
      kind: "estimate",
      model: modelFor("estimate"),
      effort: effortFor("estimate"),
      system: "You are a nutrition database. Give typical values per 100 g of the food as usually " +
        "bought (raw, edible part). If the name is a dish or brand, use a typical version. " +
        "Sodium in milligrams, everything else in grams except kcal.",
      messages: [{ role: "user", content: `Food: ${name.slice(0, 100)}` }],
      outputSchema: NutrientsSchema,
      maxTokens: 2000,
      userId,
      supabaseAdmin,
    });
    return r.ok ? r.data : null;
  };
}
