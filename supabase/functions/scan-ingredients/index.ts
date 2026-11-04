// F1.2 scan-ingredients: photos -> SCAN_MODEL -> catalog matching -> draft list for review (F1.3).
// Photos live only in memory for the length of the request and are never logged or stored.
import "@supabase/functions-js/edge-runtime.d.ts";
import { z } from "npm:zod@4.6.7";
import { callModel, withFallback } from "../_shared/ai.ts";
import { effortFor, modelFor } from "../_shared/config.ts";
import { aiEndpoint, HttpError } from "../_shared/http.ts";
import { decodeBase64, inspectJpeg } from "../_shared/jpeg.ts";
import { buildDraft, type CatalogInfo, type SearchHit } from "../_shared/scan.ts";

const MAX_EDGE = 1568;

const Body = z.object({
  location: z.enum(["fridge", "freezer", "pantry", "staples"]),
  images: z.array(z.string().min(1)).min(1).max(4),
});

// Kept to types structured outputs supports well; ranges are checked in buildDraft.
const ModelOutput = z.object({
  items: z.array(z.object({
    name: z.string(),
    quantity: z.number().nullable(),
    unit: z.string().nullable(),
    confidence: z.number(),
    photo_index: z.number().int(),
  })),
});

const PLACE: Record<string, string> = {
  fridge: "the inside of a fridge",
  freezer: "the inside of a freezer",
  pantry: "pantry or cupboard shelves",
  staples: "a shelf of seasonings, spices, oils, sauces and baking staples (often small labelled jars and bottles)",
};

const SYSTEM = `You list the food and drink visible in photos of a home kitchen, for a pantry-tracking app.

Rules:
- Only food and drink. Ignore containers, appliances, cleaning products and anything else.
- Use short generic names a shopper would use: "cheddar cheese", not a brand or product line; "eggs", "milk", "spinach".
- One entry per kind of item per photo. If the same thing appears in several photos, list it in each photo where you see it; duplicates are merged later.
- quantity and unit: your best estimate in a sensible unit: each, g, ml, bunch, or a whole package as "each" (a carton of eggs is 12 each if you can count them, else 1 pack). Use null for quantity when you can't estimate it.
- confidence: 0 to 1, how sure you are that the item is really there and correctly named.
- Don't guess what's inside opaque containers. If you're confident something is a stored leftover or similar, report it as "container (unknown contents)"; otherwise leave it out.
- photo_index: the number of the photo the item appears in, starting at 0.
- If there is no food or drink, return an empty list.`;

export default {
  fetch: aiEndpoint("scan-ingredients", async ({ body, userId, supabase, supabaseAdmin }) => {
    const parsed = Body.safeParse(body);
    if (!parsed.success) throw new HttpError("bad_request", "Send a location and 1-4 photos.");
    const { location, images } = parsed.data;

    // Photos must already be shrunk and stripped by the app (F1.1).
    for (const [i, b64] of images.entries()) {
      const bytes = decodeBase64(b64);
      const info = bytes ? inspectJpeg(bytes) : null;
      if (!info) throw new HttpError("bad_request", `Photo ${i + 1} isn't a JPEG.`);
      if (Math.max(info.width, info.height) > MAX_EDGE) {
        throw new HttpError("bad_request", `Photo ${i + 1} is larger than ${MAX_EDGE} px.`);
      }
    }

    const content = [
      ...images.flatMap((data, i) => [
        { type: "text" as const, text: `Photo ${i}:` },
        { type: "image" as const, source: { type: "base64" as const, media_type: "image/jpeg" as const, data } },
      ]),
      { type: "text" as const, text: `These ${images.length} photo(s) show ${PLACE[location]}. List the food and drink you can see.` },
    ];

    const call = () =>
      callModel({
        kind: "scan",
        model: modelFor("scan"),
        effort: effortFor("scan"),
        system: SYSTEM,
        messages: [{ role: "user", content }],
        outputSchema: ModelOutput,
        maxTokens: 16000,
        userId,
        supabaseAdmin,
      });
    // No weaker fallback: the scan model is already the strong one (D3). One retry, same
    // model, only when the reply can't be used.
    const { data } = await withFallback(call, call);

    const items = await buildDraft(data.items, images.length, {
      search: async (name): Promise<SearchHit | null> => {
        const { data: hits, error } = await supabase.schema("app").rpc("search_ingredients", { q: name, lim: 1 });
        if (error) throw new Error("search failed");
        return (hits?.[0] as SearchHit | undefined) ?? null;
      },
      catalog: async (ids) => {
        const { data: rows, error } = await supabase.schema("catalog").from("ingredients")
          .select("id, category, is_common_staple").in("id", ids);
        if (error) throw new Error("catalog lookup failed");
        return new Map((rows ?? []).map((r) => [r.id as number, r as CatalogInfo]));
      },
    });

    return { location, items };
  }),
};
