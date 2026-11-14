// F5.3: the privacy policy, served at /privacy. No app name until it's final (2026-11-14).
// Anthropic's API terms were checked on 2026-11-14 (no training on API data by default,
// inputs and outputs deleted within 30 days); check them again before launch.
import { esc } from "./render.js";

export const CONTACT = "fridgefoodscanner@gmail.com";
export const UPDATED = "November 14, 2026";

export function privacyBody() {
  return `
<h1>Privacy policy</h1>
<p class="desc">Last updated ${esc(UPDATED)}</p>

<p>This app helps you keep track of the food you have, use it before it expires, and get recipe ideas.
This page explains what it stores, what it sends to other services, and how to delete it.</p>

<h2>Your account</h2>
<p>You don't sign up with an email, name or phone number. The app creates an anonymous account
on your device the first time it opens. We don't know who you are.</p>

<h2>What we store</h2>
<ul>
  <li><b>Your pantry:</b> the food you add, with amounts, where it's kept and expiry dates.</li>
  <li><b>Your recipes and shopping list:</b> recipes you save or write, and your shopping list.</li>
  <li><b>Your preferences:</b> diets, allergies, the staples you usually have, serving size and expiry
    settings. Allergies are used to leave ingredients out of recipe ideas.</li>
  <li><b>Usage counts:</b> how many scans and recipe ideas you've used, so limits can be applied, and
    simple app events (for example "a recipe was saved", with counts and options only). Events never
    contain food names, recipe text or photos.</li>
  <li><b>Your subscription:</b> if you subscribe, the plan, its renewal date and Apple's transaction id.
    Payment is handled by Apple; we never see your card or Apple ID.</li>
</ul>
<p>This data is stored with <a href="https://supabase.com/privacy">Supabase</a>, our database provider.
Each account can only read its own data.</p>

<h2>Photos and AI</h2>
<p>When you scan your fridge, the photo is sent to <a href="https://www.anthropic.com/legal/privacy">Anthropic</a>'s
AI to identify the food. When you ask for recipe ideas, your pantry list and preferences (including
allergies) are sent to Anthropic to write the recipes, and the names of ingredients you add to your own
recipes may be sent to estimate nutrition. The app asks for your permission before it sends anything to
the AI for the first time.</p>
<ul>
  <li><b>Photos aren't stored</b> by the app or on our servers. They're used once and discarded.</li>
  <li>Under Anthropic's commercial terms, data sent through its API isn't used to train its models, and
    it's deleted from Anthropic's systems within 30 days (longer only where needed for safety or legal
    reasons).</li>
</ul>

<h2>Shared recipes</h2>
<p>When you share a recipe, anyone with the link can see it (the recipe only, never your name or
anything else in your account). Shared pages are served by <a href="https://www.cloudflare.com/privacypolicy/">Cloudflare</a>.
You can stop sharing at any time and the link stops working.</p>

<h2>Notifications</h2>
<p>Expiry reminders are created on your phone. They aren't sent from our servers.</p>

<h2>What we don't do</h2>
<ul>
  <li>No ads, and no tracking across other apps or websites.</li>
  <li>We don't sell or rent your data.</li>
</ul>

<h2>Deleting your data</h2>
<p>In the app, go to <b>Settings → Delete account</b>. This permanently deletes your account and
everything in it straight away, and any shared links stop working. Deleting the app alone doesn't
delete your account. A subscription isn't cancelled by deleting your account: cancel it in your
iPhone's Settings → Apple ID → Subscriptions.</p>
<p>You can also email us to ask for your data to be deleted or for a copy of it.</p>

<h2>Children</h2>
<p>The app isn't directed at children under 13, and we don't knowingly collect their data.</p>

<h2>Changes</h2>
<p>If this policy changes, the date at the top changes. Important changes will also be shown in the app.</p>

<h2>Contact</h2>
<p><a href="mailto:${esc(CONTACT)}">${esc(CONTACT)}</a></p>`;
}
