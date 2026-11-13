// F4.2: the public recipe page, as plain HTML and CSS (no JavaScript), light and dark mode.
// Pure functions so they can be tested without Cloudflare: `deno test share/test`.

export function esc(s) {
  return String(s ?? "")
    .replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;").replaceAll("'", "&#39;");
}

const FRACTIONS = [[0, ""], [0.25, "¼"], [1 / 3, "⅓"], [0.5, "½"], [2 / 3, "⅔"], [0.75, "¾"], [1, ""]];
const COUNTABLE = new Set(["tsp", "tbsp", "cup", "each", "", "bunch", "pack", "clove", "pinch"]);

/** "½ tsp", "1¼ cup", "300 g", "2" (like the app's MacroFormat.amount). */
export function amount(q, unit) {
  if (q == null) return "";
  const u = unit ?? "";
  let n = Number.isInteger(q) ? String(q) : String(Math.round(q * 10) / 10);
  if (COUNTABLE.has(u)) {
    const whole = Math.floor(q);
    const frac = q - whole;
    let best = FRACTIONS[0];
    for (const f of FRACTIONS) if (Math.abs(f[0] - frac) < Math.abs(best[0] - frac)) best = f;
    if (Math.abs(best[0] - frac) < 0.05) {
      const w = whole + (best[0] === 1 ? 1 : 0);
      n = w === 0 ? (best[1] || "0") : `${w}${best[1]}`;
    }
  }
  return u === "" || u === "each" ? n : `${n} ${u}`;
}

export function ingredientLine(i) {
  let s;
  if (i.unit === "to taste") s = `${i.name}, to taste`;
  else if (i.quantity != null) s = `${amount(i.quantity, i.unit)} ${i.name}`;
  else s = i.name;
  if (i.note && i.unit !== "to taste") s += `, ${i.note}`;
  if (i.is_optional) s += " (optional)";
  return s;
}

function minutes(n) {
  return n < 60 ? `${n} min` : n % 60 === 0 ? `${n / 60} h` : `${Math.floor(n / 60)} h ${n % 60} min`;
}

const STEP_NUMBER = /^\s*(?:step\s*)?\d+\s*[.):\-–]\s*/i;

export const SAFETY = "AI-generated recipe: check that meat, poultry, fish and eggs reach safe temperatures.";
export const ALLERGENS = "Allergies: always read ingredient labels. Packaged foods (sauces, stocks, spice mixes) " +
  "can contain hidden allergens or traces. If an allergy is severe, double-check every ingredient before cooking.";

const STYLE = `
:root { color-scheme: light dark; --bg: #ffffff; --fg: #1c1c1e; --muted: #6c6c70; --line: #e5e5ea; --accent: #2f8f4e; --card: #f2f2f7; }
@media (prefers-color-scheme: dark) { :root { --bg: #000000; --fg: #f2f2f7; --muted: #a1a1a6; --line: #2c2c2e; --accent: #4cc06f; --card: #1c1c1e; } }
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--fg); font: 17px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
main { max-width: 680px; margin: 0 auto; padding: 24px 16px 48px; }
h1 { font-size: 28px; line-height: 1.2; margin: 0 0 8px; }
.desc { color: var(--muted); margin: 0 0 12px; }
.meta { display: flex; flex-wrap: wrap; gap: 8px 16px; color: var(--muted); font-size: 15px; margin-bottom: 16px; }
.macros { display: grid; grid-template-columns: repeat(4, 1fr); gap: 8px; background: var(--card); border-radius: 12px; padding: 12px; text-align: center; margin-bottom: 8px; }
.macros b { display: block; font-size: 18px; } .macros span { color: var(--muted); font-size: 13px; }
h2 { font-size: 20px; margin: 28px 0 8px; padding-bottom: 4px; border-bottom: 1px solid var(--line); }
ul { padding-left: 20px; margin: 0; } li { margin: 4px 0; }
ol { padding-left: 24px; margin: 0; } ol li { margin: 0 0 12px; } ol li::marker { color: var(--accent); font-weight: 700; }
.note { color: var(--muted); font-size: 14px; margin: 8px 0 0; }
footer { margin-top: 32px; padding-top: 16px; border-top: 1px solid var(--line); color: var(--muted); font-size: 14px; }
.empty { text-align: center; padding-top: 20vh; } .empty h1 { font-size: 24px; }
`;

function page({ title, description, url, body, image }) {
  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>${esc(title)}</title>
<meta name="description" content="${esc(description)}">
<meta property="og:type" content="article">
<meta property="og:title" content="${esc(title)}">
<meta property="og:description" content="${esc(description)}">
${url ? `<meta property="og:url" content="${esc(url)}">` : ""}
${image ? `<meta property="og:image" content="${esc(image)}">` : ""}
<meta name="twitter:card" content="summary">
<style>${STYLE}</style>
</head><body><main>${body}</main></body></html>`;
}

/** The page for a shared recipe (the jsonb from public.get_shared_recipe). */
export function recipePage(r, { url, image, appName = "Fridge" } = {}) {
  const times = [];
  if (r.servings) times.push(`${r.servings} serving${r.servings === 1 ? "" : "s"}`);
  if (r.prep_min != null) times.push(`Prep ${minutes(r.prep_min)}`);
  if (r.cook_min != null) times.push(`Cook ${minutes(r.cook_min)}`);
  const m = r.macros_per_serving;
  const macros = m && m.kcal > 0
    ? `<div class="macros" aria-label="Nutrition per serving">
        <div><b>${m.estimated ? "≈" : ""}${Math.round(m.kcal)}</b><span>kcal</span></div>
        <div><b>${Math.round(m.protein_g)} g</b><span>protein</span></div>
        <div><b>${Math.round(m.carbs_g)} g</b><span>carbs</span></div>
        <div><b>${Math.round(m.fat_g)} g</b><span>fat</span></div>
      </div><p class="note">Per serving${m.estimated ? ", approximate" : ""}.</p>`
    : "";
  const steps = (r.steps ?? []).map((s) => `<li>${esc(String(s).replace(STEP_NUMBER, ""))}</li>`).join("");
  const ingredients = (r.ingredients ?? []).map((i) => `<li>${esc(ingredientLine(i))}</li>`).join("");
  // No app name on the page until the name is final (2026-11-13).
  const description = r.description || "A shared recipe.";
  const body = `
<h1>${esc(r.title)}</h1>
${r.description ? `<p class="desc">${esc(r.description)}</p>` : ""}
<div class="meta">${times.map((t) => `<span>${esc(t)}</span>`).join("")}</div>
${macros}
<h2>Ingredients</h2><ul>${ingredients}</ul>
<h2>Steps</h2><ol>${steps}</ol>
<footer>
  <p>${r.is_ai ? esc(SAFETY) : "Shared by its author."}</p>
  <p>${esc(ALLERGENS)}</p>
</footer>`;
  return page({ title: r.title, description, url, body, image });
}

export function notFoundPage(appName = "Fridge") {
  return page({
    title: "Recipe not found",
    description: "This recipe is no longer shared.",
    body: `<div class="empty"><h1>This recipe is no longer shared.</h1>
<p class="desc">The link may have been turned off by the person who shared it.</p></div>`,
  });
}
