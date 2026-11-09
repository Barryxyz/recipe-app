// F2.2 generate-recipes: pantry + options -> RECIPE_MODEL -> code checks -> (fallback once) ->
// macros (F2.3). Nothing is saved; the app keeps the results until the user saves one (F3.1).
import "@supabase/functions-js/edge-runtime.d.ts";
import { z } from "npm:zod@4.6.7";
import { callModel } from "../_shared/ai.ts";
import { effortFor, modelFor, recipeLimits } from "../_shared/config.ts";
import { aiEndpoint, HttpError, log } from "../_shared/http.ts";
import { computeMacros, CUSTOM_ID_START, resolveIngredients } from "../_shared/macros.ts";
import { nutritionEstimator, supabaseStore } from "../_shared/nutrition.ts";
import {
  buildPrompt, type Context, MAX_PANTRY_ROWS, ModelOutput, outIngredients, type PantryRow, plausibleQuantity,
  RequestSchema, runPipeline, stripStepNumber, SYSTEM, usesExpiring,
} from "../_shared/recipes.ts";

const Check = z.object({ check: z.literal(true) });
const DAY_MS = 86_400_000;
const MAX_STAPLES = 80;

export default {
  fetch: aiEndpoint("generate-recipes", async ({ body, userId, supabase, supabaseAdmin }) => {
    log({ fn: "generate-recipes", stage: "start" });
    const limits = recipeLimits();
    const readUsage = async () => {
      const { data, error } = await supabaseAdmin.schema("app").rpc("ai_usage", { p_kind: "recipes", p_user: userId });
      if (error || !data) throw new Error("usage lookup failed");
      const u = data as { today: number; this_month: number; day_resets_at: string; month_resets_at: string };
      return {
        today: u.today, daily_limit: limits.daily, this_month: u.this_month, monthly_limit: limits.monthly,
        left: Math.max(0, Math.min(limits.daily - u.today, limits.monthly - u.this_month)),
        resets_at: limits.monthly - u.this_month <= 0 ? u.month_resets_at : u.day_resets_at,
      };
    };
    if (Check.safeParse(body).success) return { usage: await readUsage() };

    const before = await readUsage();
    if (before.left <= 0) {
      throw new HttpError("limit_reached", before.this_month >= limits.monthly
        ? `You've used this month's ${limits.monthly} recipe requests.`
        : `You've used today's ${limits.daily} recipe requests. They reset at midnight.`);
    }

    const parsed = RequestSchema.safeParse(body);
    if (!parsed.success) throw new HttpError("bad_request", "Unexpected recipe options.");
    const request = { ...parsed.data, cuisine: parsed.data.cuisine || null };

    // ---- context (as the user: RLS limits this to their household)
    const [{ data: items, error: itemsError }, { data: prefs }] = await Promise.all([
      supabase.schema("app").from("pantry_items")
        .select("id, ingredient_id, display_name, quantity, unit, location, expires_at, is_staple")
        .eq("status", "active").is("deleted_at", null),
      supabase.schema("app").from("user_prefs").select("diets, allergens").eq("user_id", userId).maybeSingle(),
    ]);
    if (itemsError) throw new Error("pantry lookup failed");

    const now = Date.now();
    const excluded = new Set(request.exclude_pantry_item_ids);
    const usable = (items ?? [])
      .filter((i) => !excluded.has(i.id))
      .filter((i) => !i.expires_at || Date.parse(i.expires_at) >= now)     // expired items are never used
      .map((i) => ({
        ...i,
        days_left: i.expires_at ? Math.floor((Date.parse(i.expires_at) - now) / DAY_MS) : null,
      }))
      .sort((a, b) => (a.days_left ?? 1e9) - (b.days_left ?? 1e9));
    const regular = usable.filter((i) => !i.is_staple).slice(0, MAX_PANTRY_ROWS);
    const staples = usable.filter((i) => i.is_staple).slice(0, MAX_STAPLES);

    if (!regular.length) {
      return { recipes: [], note: "Your pantry is empty. Add a few items and try again.", limited_by: ["pantry"], usage: before };
    }

    const catalogIds = [...new Set(usable.flatMap((i) =>
      i.ingredient_id != null && Number(i.ingredient_id) < CUSTOM_ID_START ? [Number(i.ingredient_id)] : []))];
    const store = supabaseStore(supabase);
    const [info, catalogRows] = await Promise.all([
      catalogIds.length ? store.catalogInfo(catalogIds) : Promise.resolve(new Map()),
      catalogIds.length
        ? supabase.schema("catalog").from("ingredients").select("id, allergens, category").in("id", catalogIds)
        : Promise.resolve({ data: [] as { id: number; allergens: string[]; category: string | null }[] }),
    ]);
    const catalog = new Map((catalogRows.data ?? []).map((r) => [Number(r.id), r]));

    const toRow = (i: typeof usable[number], ref: string): PantryRow => {
      const c = i.ingredient_id != null ? catalog.get(Number(i.ingredient_id)) : undefined;
      return {
        ref, pantry_item_id: i.id, ingredient_id: i.ingredient_id == null ? null : Number(i.ingredient_id),
        name: i.display_name, quantity: plausibleQuantity(i.quantity == null ? null : Number(i.quantity), i.unit), unit: i.unit,
        location: i.location, days_left: i.days_left, is_staple: i.is_staple,
        tags: c?.allergens ?? [], category: c?.category ?? null,
      };
    };
    const ctx: Context = {
      request,
      pantry: [...regular.map((i, n) => toRow(i, `P${n + 1}`)), ...staples.map((i, n) => toRow(i, `S${n + 1}`))],
      diets: (prefs?.diets as string[] | undefined) ?? [],
      allergens: ((prefs?.allergens as string[] | undefined) ?? []).map((a) => a.trim()).filter(Boolean),
      info,
    };

    // ---- model, checks, fallback
    const prompt = buildPrompt(ctx);
    log({ fn: "generate-recipes", stage: "model", pantry: regular.length, staples: staples.length });
    const call = (kind: "recipes" | "fallback") => () =>
      callModel({
        kind: kind === "recipes" ? "recipes" : "recipes_fallback",   // only first calls count toward the limit
        model: modelFor(kind),
        effort: effortFor(kind),
        system: SYSTEM,
        messages: [{ role: "user", content: prompt }],
        outputSchema: ModelOutput,
        maxTokens: 16000,
        userId,
        supabaseAdmin,
      });
    // The app waits up to 90 s: no fallback after 35 s.
    const result = await runPipeline(ctx, call("recipes"), call("fallback"), { fallbackCutoffMs: 35_000 });
    if (!result.ok) {
      throw new HttpError(result.error, result.error === "validation_failed"
        ? "Couldn't come up with good recipes with these options."
        : result.error === "timeout" ? "The AI took too long. Try again." : "Something went wrong. Try again.");
    }

    // ---- macros (F2.3) and response
    const estimate = nutritionEstimator(userId, supabaseAdmin);
    const recipes = await Promise.all(result.recipes.map(async (rec, n) => {
      const ingredients = outIngredients(rec, ctx);
      const resolved = await resolveIngredients(ingredients, store, estimate);
      const macros = computeMacros(resolved.ingredients, rec.servings, resolved.info);
      return {
        temp_id: `r${n + 1}`,
        title: rec.title.trim(),
        description: rec.description.trim(),
        servings: rec.servings,
        prep_min: rec.prep_min,
        cook_min: rec.cook_min,
        ingredients,
        steps: rec.steps.map(stripStepNumber).filter(Boolean),
        macros_per_serving: macros.per_serving,
        macros_total: macros.total,
        uses_expiring: usesExpiring(rec, ctx),
        model_version: result.model,
      };
    }));

    return {
      recipes,
      note: result.note,
      limited_by: result.limited_by,
      attempts: result.attempts,
      usage: await readUsage(),
    };
  }),
};
