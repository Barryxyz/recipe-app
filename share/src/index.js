// F4.2: Cloudflare Worker for shared recipe links.
//   GET /r/<token>  the recipe page (public.get_shared_recipe through the Supabase REST API with
//                   the publishable key), or a 404 page; cached for 60 s so revoking applies fast
//   GET /.well-known/apple-app-site-association  for links that open the app (F4.3)
//   anything else   404
import { notFoundPage, recipePage } from "./render.js";

const TOKEN = /^\/r\/([0-9A-Za-z]{22})\/?$/;

function html(body, status) {
  return new Response(body, {
    status,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "public, max-age=60",
      "x-robots-tag": "noindex, nofollow",
      "x-content-type-options": "nosniff",
      "referrer-policy": "no-referrer",
      "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; img-src https:; base-uri 'none'; form-action 'none'",
    },
  });
}

export async function fetchSharedRecipe(token, env, fetchImpl = fetch) {
  const res = await fetchImpl(`${env.SUPABASE_URL}/rest/v1/rpc/get_shared_recipe`, {
    method: "POST",
    headers: { apikey: env.SUPABASE_KEY, "content-type": "application/json" },
    body: JSON.stringify({ p_token: token }),
  });
  if (!res.ok) throw new Error(`supabase ${res.status}`);
  return await res.json();       // the recipe object, or null
}

export async function handle(request, env, fetchImpl = fetch) {
  const url = new URL(request.url);
  if (request.method !== "GET" && request.method !== "HEAD") return new Response("Method not allowed", { status: 405 });

  if (url.pathname === "/.well-known/apple-app-site-association") {
    return new Response(JSON.stringify({
      applinks: { details: [{ appIDs: [env.APP_ID], components: [{ "/": "/r/*" }] }] },
    }), { headers: { "content-type": "application/json", "cache-control": "public, max-age=3600" } });
  }

  const m = url.pathname.match(TOKEN);
  if (!m) return html(notFoundPage(env.APP_NAME), 404);
  try {
    const recipe = await fetchSharedRecipe(m[1], env, fetchImpl);
    if (!recipe) return html(notFoundPage(env.APP_NAME), 404);
    return html(recipePage(recipe, { url: url.toString(), appName: env.APP_NAME }), 200);
  } catch {
    return new Response("Something went wrong. Try again in a moment.", {
      status: 502, headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" },
    });
  }
}

export default { fetch: (request, env) => handle(request, env) };
