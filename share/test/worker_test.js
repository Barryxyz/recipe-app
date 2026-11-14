// F4.2 page tests: deno test share/test
import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { handle } from "../src/index.js";
import { amount, esc, recipePage } from "../src/render.js";

const ENV = { SUPABASE_URL: "https://x.supabase.co", SUPABASE_KEY: "sb_publishable_test", APP_NAME: "Fridge", APP_ID: "T.app" };
const RECIPE = {
  title: "Lemon <Chicken>", description: "Bright & quick.", servings: 2, prep_min: 10, cook_min: 20,
  steps: ["1. Heat the pan.", "Cook the chicken to 74 °C."],
  macros_per_serving: { kcal: 520.4, protein_g: 38, carbs_g: 41, fat_g: 22, estimated: true },
  is_ai: true,
  ingredients: [
    { name: "chicken thighs", quantity: 300, unit: "g", note: null, is_optional: false },
    { name: "lemon", quantity: 0.5, unit: "each", note: "zested", is_optional: true },
    { name: "salt", quantity: null, unit: "to taste", note: null, is_optional: false },
  ],
};
const token = "A".repeat(22);
const fakeFetch = (result, status = 200) => async () => new Response(JSON.stringify(result), { status });

Deno.test("a shared recipe renders in full, escaped, with the disclaimers", async () => {
  const res = await handle(new Request(`https://s.example/r/${token}`), ENV, fakeFetch(RECIPE));
  assertEquals(res.status, 200);
  assertEquals(res.headers.get("cache-control"), "public, max-age=60");
  const body = await res.text();
  assertStringIncludes(body, "<h1>Lemon &lt;Chicken&gt;</h1>");
  assertStringIncludes(body, '<meta property="og:title" content="Lemon &lt;Chicken&gt;">');
  assertStringIncludes(body, '<meta name="robots" content="noindex, nofollow">');
  assertStringIncludes(body, "<li>300 g chicken thighs</li>");
  assertStringIncludes(body, "<li>½ lemon, zested (optional)</li>");
  assertStringIncludes(body, "<li>salt, to taste</li>");
  assertStringIncludes(body, "<li>Heat the pan.</li>");
  assertStringIncludes(body, "≈520");
  assertStringIncludes(body, "AI-generated recipe");
  assertStringIncludes(body, "hidden allergens");
  assert(!body.includes("<script"), "no JavaScript");
  assert(!body.includes("Fridge"), "no app name on the page until the name is final");
});

Deno.test("own recipes say 'Shared by its author' instead of the AI line", () => {
  const body = recipePage({ ...RECIPE, is_ai: false });
  assertStringIncludes(body, "Shared by its author.");
  assert(!body.includes("AI-generated"));
});

Deno.test("unknown, revoked or malformed tokens get the 404 page without asking Supabase for bad ones", async () => {
  const revoked = await handle(new Request(`https://s.example/r/${token}`), ENV, fakeFetch(null));
  assertEquals(revoked.status, 404);
  const notFound = await revoked.text();
  assertStringIncludes(notFound, "This recipe is no longer shared.");
  assert(!notFound.includes("Fridge"));
  let called = false;
  const bad = await handle(new Request("https://s.example/r/short"), ENV, async () => { called = true; return new Response("null"); });
  assertEquals(bad.status, 404);
  assertEquals(called, false);
  assertEquals((await handle(new Request("https://s.example/"), ENV, fakeFetch(null))).status, 404);
});

Deno.test("a Supabase error is a 502, not cached", async () => {
  const res = await handle(new Request(`https://s.example/r/${token}`), ENV, fakeFetch({ message: "x" }, 500));
  assertEquals(res.status, 502);
  assertEquals(res.headers.get("cache-control"), "no-store");
});

Deno.test("app site association lists the app and /r/ links", async () => {
  const res = await handle(new Request("https://s.example/.well-known/apple-app-site-association"), ENV);
  const json = await res.json();
  assertEquals(json.applinks.details[0].appIDs, ["T.app"]);
  assertEquals(json.applinks.details[0].components, [{ "/": "/r/*" }]);
});

Deno.test("helpers", () => {
  assertEquals(esc(`<a href="x">'&'</a>`), "&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;");
  assertEquals(amount(1.25, "cup"), "1¼ cup");
  assertEquals(amount(2, "each"), "2");
  assertEquals(amount(0.3, "kg"), "0.3 kg");
});

Deno.test("the privacy policy is served, indexable, with the contact address and no app name", async () => {
  const res = await handle(new Request("https://x.workers.dev/privacy"), ENV, () => {
    throw new Error("no Supabase call for /privacy");
  });
  assertEquals(res.status, 200);
  assertEquals(res.headers.get("x-robots-tag"), null);
  const body = await res.text();
  assertStringIncludes(body, "<h1>Privacy policy</h1>");
  assertStringIncludes(body, "mailto:fridgefoodscanner@gmail.com");
  assertStringIncludes(body, "Photos aren't stored");
  assertStringIncludes(body, "Settings → Delete account");
  assertEquals(body.includes("noindex"), false);
  assertEquals(/\bFridge\b/.test(body), false);
});
