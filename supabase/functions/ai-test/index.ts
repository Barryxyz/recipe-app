// F0.5 acceptance test function. Calls the model with a toy schema through the shared
// AI module. Body: { "force_validation_failure": true } rejects the primary model's answer
// to exercise the fallback path.
import "@supabase/functions-js/edge-runtime.d.ts";
import { z } from "npm:zod@^4";
import { callModel, withFallback } from "../_shared/ai.ts";
import { effortFor, modelFor } from "../_shared/config.ts";
import { aiEndpoint, HttpError } from "../_shared/http.ts";

const Fruit = z.object({
  name: z.string().min(1),
  color: z.string().min(1),
  kcal_per_100g: z.number().nonnegative(),
});

const Body = z.object({ force_validation_failure: z.boolean().optional() });

export default {
  fetch: aiEndpoint("ai-test", async ({ userId, supabaseAdmin, body }) => {
    const parsed = Body.safeParse(body);
    if (!parsed.success) throw new HttpError("bad_request", "Unexpected body.");
    const forceFailure = parsed.data.force_validation_failure ?? false;

    const call = (kind: "test" | "fallback") => () =>
      callModel({
        kind: "test",
        model: modelFor(kind),
        effort: effortFor(kind),
        system: "You answer with a single common fruit.",
        messages: [{ role: "user", content: "Name one fruit, its usual color and its calories per 100 g." }],
        outputSchema: Fruit,
        maxTokens: 2000,
        userId,
        supabaseAdmin,
      });

    let primaryChecked = false;
    const result = await withFallback(call("test"), call("fallback"), () => {
      // Reject only the first (primary) answer when asked to.
      if (forceFailure && !primaryChecked) {
        primaryChecked = true;
        return "forced validation failure";
      }
      primaryChecked = true;
      return null;
    });

    return { data: result.data, model: result.model, attempts: result.attempts };
  }),
};
