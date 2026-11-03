// F0.1 test function: proves the app can reach an Edge Function and that the
// function can read ANTHROPIC_API_KEY. It reports only whether the key is set,
// never the key itself (NFR-5). Delete once F0.5 has real AI functions.
import "@supabase/functions-js/edge-runtime.d.ts";
import { withSupabase } from "@supabase/server";

export default {
  fetch: withSupabase({ auth: ["publishable", "secret"] }, async (_req, _ctx) => {
    const key = Deno.env.get("ANTHROPIC_API_KEY") ?? "";
    return Response.json({
      message: "Hello from Supabase",
      anthropicKeyConfigured: key.startsWith("sk-ant-"),
      serverTime: new Date().toISOString(),
    });
  }),
};
