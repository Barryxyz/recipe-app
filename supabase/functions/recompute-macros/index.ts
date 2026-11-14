// F2.3: recalculates a saved recipe's macros from its ingredients (called after an edit, F3.2).
// Body: { recipe_id }. Works without a subscription; custom items are only estimated by the
// model (once each) when the user has AI access.
import "@supabase/functions-js/edge-runtime.d.ts";
import { z } from "npm:zod@4.6.7";
import { endpoint, hasAiAccess, HttpError } from "../_shared/http.ts";
import { computeMacros, resolveIngredients } from "../_shared/macros.ts";
import { nutritionEstimator, supabaseStore } from "../_shared/nutrition.ts";

// estimate: false when the user hasn't agreed to the AI (F5.3); older apps omit it.
const Body = z.object({ recipe_id: z.uuid(), estimate: z.boolean().optional() });

export default {
  fetch: endpoint("recompute-macros", async ({ userId, supabase, supabaseAdmin, body }) => {
    const parsed = Body.safeParse(body);
    if (!parsed.success) throw new HttpError("bad_request", "Send { recipe_id }.");
    const id = parsed.data.recipe_id;

    // As the user: RLS limits this to their own recipes.
    const { data: recipe, error } = await supabase.schema("app").from("recipes")
      .select("id, servings").eq("id", id).is("deleted_at", null).maybeSingle();
    if (error) throw error;
    if (!recipe) throw new HttpError("not_found", "Recipe not found.");

    const { data: rows, error: ingError } = await supabase.schema("app").from("recipe_ingredients")
      .select("ingredient_id, name, quantity, unit, grams, is_optional").eq("recipe_id", id).order("position");
    if (ingError) throw ingError;

    const ingredients = (rows ?? []).map((r) => ({
      ingredient_id: r.ingredient_id == null ? null : Number(r.ingredient_id),
      name: r.name,
      quantity: r.quantity == null ? null : Number(r.quantity),
      unit: r.unit,
      grams: r.grams == null ? null : Number(r.grams),
      is_optional: r.is_optional,
    }));
    const estimate = parsed.data.estimate !== false && (await hasAiAccess(userId, supabaseAdmin))
      ? nutritionEstimator(userId, supabaseAdmin) : null;
    const { ingredients: resolved, info } = await resolveIngredients(ingredients, supabaseStore(supabase), estimate);
    const macros = computeMacros(resolved, recipe.servings, info);

    const { error: saveError } = await supabase.schema("app").from("recipes")
      .update({ macros_per_serving: macros.per_serving, macros_total: macros.total }).eq("id", id);
    if (saveError) throw saveError;
    return { recipe_id: id, macros_per_serving: macros.per_serving, macros_total: macros.total };
  }, { ai: false }),
};
