# Fridge App — Design Document

**Status:** Draft v1.2 · **Last updated:** 2026-08-05 · **Platform:** iOS only

An iOS app that tracks what's in your fridge — by photo or by manual entry — estimates quantities and expiry dates, and generates recipes from the ingredients on hand.

---

## 1. Goals and non-goals

### Goals
- Scan a fridge with the camera and get an editable ingredient list with estimated quantities.
- Add ingredients manually, without taking a photo. Scanning is optional, never required.
- Track expiry dates for each item, with sensible defaults the user can change.
- Generate recipes from available ingredients. A recipe doesn't need to use every ingredient.
- Save, edit, delete and share recipes (up to 50 saved per user).
- Build a shopping list from ingredients a recipe needs but the user doesn't have.
- Support 100 users at launch, with an architecture that reaches 10,000 without a rewrite.
- Sell the app as a one-time **$4.99 paid download** (D5).

### Non-goals (v1)
- Android or web app (a web page exists only to view shared recipes).
- Barcode scanning (deferred, see §11).
- Household / shared fridges (deferred; the schema is ready for it, see §5).
- Meal planning, recipe images, subscriptions or in-app purchases (the app is a one-time paid download, D5).

---

## 2. Requirements

### Functional
| ID | Requirement |
|---|---|
| FR-1 | Take one or more photos of the fridge. Photos are **not stored**. |
| FR-2 | Detect ingredients and estimate quantities from the photos. |
| FR-3 | User reviews, edits, adds and removes detected items before saving. |
| FR-4 | Each item gets an estimated expiry date (assumed fresh at scan time), which the user can change per item and per ingredient type. |
| FR-5 | Generate AI recipes from available ingredients. Not all ingredients must be used. |
| FR-6 | Recipes include prep/cook time, step-by-step instructions, ingredient measurements and estimated macros. |
| FR-7 | Users can save up to 50 recipes, and edit or delete them. |
| FR-8 | Share a recipe via a link that friends can open with or without the app. |
| FR-9 | Recipes pull ingredient and nutrition data from a dedicated ingredient database (similar to MyFitnessPal). |
| FR-10 | Add a recipe's missing ingredients to a shopping list, check items off, and move bought items into the pantry. |
| FR-11 | Mark pantry items as used or discarded. "Cooked this" subtracts a recipe's ingredients. |
| FR-12 | Dietary preferences, allergens and pantry staples are taken into account when generating recipes. |
| FR-13 | Add ingredients manually, without a photo: search the catalog or type free text, set quantity, unit, location and (optionally) expiry. Several items can be added in one session. Works on its own; no scan needed first. |

### Non-functional
| ID | Requirement |
|---|---|
| NFR-1 | Accounts and sessions persist across app launches and reinstalls. |
| NFR-2 | 100 users at launch; the design reaches 10,000 without architectural changes. |
| NFR-3 | iOS only (SwiftUI). |
| NFR-4 | Ingredient reference data and user/recipe data are stored separately (see Decision 1). |
| NFR-5 | The AI API key never ships in the app. |
| NFR-6 | Saved pantry and recipes can be viewed offline. Manual entry works offline once the cache exists (v1), with changes queued for sync. Scanning and generation need a network connection. |
| NFR-7 | In-app account deletion (App Store requirement). |
| NFR-8 | AI features work only for accounts with a verified App Store purchase, so the public API key can't be used for free AI calls. |

---

## 3. Decisions

| # | Decision | Choice | Rejected alternatives |
|---|---|---|---|
| D1 | Database separation | **One Postgres database with two schemas:** `catalog` (shared ingredient/nutrition data) and `app` (per-user data) | Two physical databases (no joins, ~+$10/month); Postgres + search engine (extra system) |
| D2 | Backend platform | **Supabase.** Free tier for the prototype, Pro ($25/month) for production | EC2 (days–weeks of setup and ongoing maintenance), Firebase (NoSQL conflicts with D1), CloudKit (can't run AI calls) |
| D3 | AI models | **Hybrid:** Claude Sonnet 5.5 for photo scans, Claude Haiku 5.5 for recipe generation. Model is a config value. | Sonnet for everything (~6x cost), Haiku for everything (weaker scans), Opus 5.5 (~11x cost) |
| D4 | v1 scope | **Shopping list included.** Barcode scanning and household sharing deferred. | — |
| D5 | Business model | **Paid download, $4.99 one-time (US). No subscriptions, in-app purchases or per-user caps.** | Completely free (previous choice), free with caps, freemium subscription |
| D6 | Share page hosting | **Cloudflare Worker (free tier) on the app's own domain (~$10–15/year).** It also serves the Universal Links file and the privacy policy. | Supabase Edge Function (serves HTML as plain text on the default domain; a custom domain is a paid add-on — check current Supabase docs) |

### Rationale
- **D1:** Joins between recipes, ingredients and nutrition stay in one query. Each schema has its own permissions. Either schema can move to its own database later without changing app code.
- **D2:** Postgres matches D1. Supabase provides auth (anonymous now, Sign in with Apple later), row-level security, and Edge Functions to relay AI calls. Prototype code carries straight into production.
- **D3:** Scans are infrequent and accuracy is what users notice first, so they get the stronger vision model. Recipe generation is the frequent call. Server-side checks (§6.2) catch Haiku mistakes, with one retry on Sonnet if checks fail.
- **D5:** One-time price of $4.99 in the US. Apple sets equivalent prices in other countries, and $5.00 is also an allowed price point. With the App Store Small Business Program (15% commission), each US sale nets about **$4.24**. Accepted risk: revenue arrives once, while AI and hosting costs continue (see §8). **Mitigation:**
  - Set a monthly spend limit on the Anthropic account before inviting anyone besides the developer.
  - Log token usage per user.
  - AI functions only serve verified purchases (NFR-8, F0.6).
- **D6:** Universal Links need an `apple-app-site-association` file on a domain the app controls, and the share page must be served as real HTML. A Worker on our own domain does both for free.

---

## 4. Architecture

```
┌──────────────────────┐        ┌────────────────────── Supabase ──────────────────────┐
│ iOS app (SwiftUI)    │        │                                                       │
│                      │  HTTPS │  Auth (anonymous → Sign in with Apple)                │
│  Scan / Manual add   ├───────►│                                                       │
│  Pantry / Recipes    │        │  Edge Functions (TypeScript)                          │
│  Shopping list       │        │   • scan-ingredients ───────────┐                     │
│                      │        │   • generate-recipes ───────────┤                     │
│  SwiftData cache     │        │   • recompute-macros            │                     │
│  (offline viewing)   │        │   • verify-purchase             │                     │
└──────────────────────┘        │                                 ▼                     │
                                │  Postgres                   Claude API                │
                                │   ├─ catalog.*  (shared)     • Sonnet 5.5 (vision)    │
                                │   └─ app.*      (per user,   • Haiku 5.5 (recipes)    │
                                │                  row-level                            │
                                │                  security)                            │
                                └───────────────────────────────────────────────────────┘
```

- **Source of truth:** the server. The device keeps a SwiftData cache for offline viewing and editing, and syncs changes when back online.
- **All AI calls go through Edge Functions.** The app never holds the API key.
- **Photos** are resized on the device (longest edge ~1568px, JPEG), sent to `scan-ingredients`, forwarded to the model, and never written to storage or logs.
- **Share page** (D6): a Cloudflare Worker on the app's own domain. It serves `/r/<token>` (reading the recipe through a Supabase function), the Universal Links file, and `/privacy`.
- **Purchase check** (NFR-8): `verify-purchase` checks Apple's signed proof of purchase once per account. AI functions refuse accounts without it.

---

## 5. Data model

### `catalog` schema (shared, read-only to users)
Seeded from **USDA FoodData Central** (nutrition, public domain) and **USDA FoodKeeper** (shelf life).

```sql
catalog.ingredients (
  id                       bigint primary key,
  name                     text not null,
  aliases                  text[] default '{}',      -- "scallion", "green onion"
  category                 text,                     -- produce, dairy, meat, ...
  fdc_id                   int,                      -- USDA FoodData Central id
  default_unit             text,                     -- "g", "ml", "each"
  grams_per_unit           numeric,                  -- 1 egg ≈ 50 g
  density_g_per_ml         numeric,
  shelf_life_fridge_days   int,
  shelf_life_freezer_days  int,
  shelf_life_pantry_days   int,
  is_common_staple         boolean default false,    -- salt, oil, pepper
  allergens                text[] default '{}'       -- top-9 allergens + gluten; checked in code (§6.2)
)

catalog.ingredient_nutrients (            -- per 100 g
  ingredient_id  bigint primary key references catalog.ingredients,
  kcal numeric, protein_g numeric, carbs_g numeric, fat_g numeric,
  fiber_g numeric, sugar_g numeric, sodium_mg numeric
)
```
Name search uses Postgres's `pg_trgm` extension (fuzzy matching) on `name` and `aliases`.

### `app` schema (per user, row-level security on every table)
```sql
app.households (id uuid primary key, created_at timestamptz)
  -- v1: every user gets a personal household automatically.
  -- Exists now so household sharing needs no data migration later.

app.users (
  id uuid primary key,             -- = Supabase auth user id
  household_id uuid references app.households,
  purchase_verified_at timestamptz,  -- App Store purchase proof checked (NFR-8); service role only
  purchase_environment text,         -- 'Production' | 'Sandbox' | 'Xcode'
  created_at timestamptz,
  deleted_at timestamptz
)

app.user_prefs (
  user_id uuid primary key references app.users,
  diets text[], allergens text[],
  staple_ingredient_ids bigint[],  -- always treated as available
  default_servings int default 2
)

app.user_shelf_life_overrides (    -- "customizable expiry" per ingredient type and location
  user_id uuid, ingredient_id bigint,
  location text check (location in ('fridge','freezer','pantry')),
  days int,
  primary key (user_id, ingredient_id, location)
)

app.ingredients_private (          -- items the catalog doesn't know
  id bigint primary key, user_id uuid, name text,
  nutrients_per_100g jsonb,        -- null until estimated (manual free-text items, see §6.1b)
  is_estimated boolean default true
)

app.pantry_items (
  id uuid primary key,
  household_id uuid not null references app.households,
  added_by uuid references app.users,
  ingredient_id bigint,            -- soft ref to catalog.ingredients (or private)
  display_name text not null,
  quantity numeric, unit text,     -- quantity null = "some"
  location text check (location in ('fridge','freezer','pantry')),
  added_at timestamptz, expires_at timestamptz,
  expiry_overridden boolean default false,
  status text check (status in ('active','used','discarded')) default 'active',
  source text check (source in ('scan','manual','shopping_list')) not null
                                   -- how the item was added; used to compare scan vs. manual use
)

app.recipes (
  id uuid primary key,
  user_id uuid not null references app.users,
  title text, description text,
  servings int, prep_min int, cook_min int,
  steps jsonb,                     -- ordered list of instruction strings
  macros_per_serving jsonb,        -- calculated by the server, never by the model
  macros_total jsonb,
  source text check (source in ('ai','edited','shared')),  -- 'shared' = saved from someone's link
  model_version text,
  share_token text unique,         -- null = not shared
  created_at timestamptz, updated_at timestamptz
)
-- Trigger: reject inserts when the user already has 50 recipes (soft-deleted rows don't count).

app.recipe_ingredients (
  recipe_id uuid references app.recipes on delete cascade,
  position int,
  ingredient_id bigint,            -- soft ref; null if free text
  name text not null,              -- copied so the recipe still reads correctly
  quantity numeric, unit text, grams numeric,
  note text, is_optional boolean default false
)

app.shopping_list_items (
  id uuid primary key,
  household_id uuid not null references app.households,
  ingredient_id bigint,
  name text not null,
  quantity numeric, unit text,
  source_recipe_id uuid references app.recipes on delete set null,
  checked boolean default false,
  created_at timestamptz
)

app.ai_usage_log (                 -- cost visibility (no caps, see D5)
  id bigint primary key, user_id uuid, kind text,   -- 'scan' | 'recipes'
  model text, input_tokens int, output_tokens int, created_at timestamptz
)
```

**Soft references:** `ingredient_id` columns in `app` aren't foreign keys into `catalog`. Copied `name` and `grams` keep recipes readable even if catalog entries change, and keep the schemas independent (D1).

**Sync columns (for offline sync, F3.6):**
- Every synced `app` table has `updated_at`, kept current by a trigger.
- `pantry_items`, `shopping_list_items`, `recipes`, `ingredients_private` and `user_shelf_life_overrides` also have `deleted_at`. Deletes on them are **soft deletes**, so other devices learn about them, and a nightly job purges rows deleted more than 30 days ago.
- `recipe_ingredients` sync with their parent recipe.

---

## 6. Core flows

### 6.1 Adding ingredients
There are two ways to add ingredients. They are equal: a user can rely on either one only, or mix them.

### 6.1a Scan → pantry
1. User picks a location (fridge/freezer/pantry) and takes 1–4 photos.
2. The app resizes the photos and sends them to `scan-ingredients`.
3. The Edge Function calls **Sonnet 5.5** with structured output:
   `[{ name, quantity, unit, confidence }]`
4. Each item is matched to the catalog (exact → alias → fuzzy). Duplicates across photos are merged.
5. **Review screen:** user confirms, edits, deletes or adds items. Low-confidence items are flagged.
6. Saved items get `expires_at = now + shelf life` (user override → catalog default for that location).
7. Unknown items become `ingredients_private` rows with no nutrition yet. As with manual custom items, nutrition is estimated only if a recipe uses them (§6.2 step 6).

### 6.1b Manual entry → pantry
Entry points: the **+** button on the pantry screen, the empty-pantry screen ("Scan your fridge" / "Add manually", side by side), and **Add item** on the scan review screen (same sheet).

1. User types a name. Type-ahead searches the catalog (`pg_trgm` on `name` and `aliases`). Recently and frequently added items show before the user types.
2. Picking a catalog item fills in default unit, location (from category) and quantity of 1. The user can change any of them; quantity can also be "some".
3. Expiry is calculated as in §6.1a step 6 and shown in the form. The user can override it (sets `expiry_overridden`).
4. **Add & next** keeps the sheet open with the same location selected, for entering a grocery haul quickly. **Done** closes it.
5. **No catalog match:** "Add "<text>" as a custom item" creates an `ingredients_private` row with `nutrients_per_100g = null`, and the user picks the location. Expiry uses a 7-day fridge default (editable) until a per-ingredient override exists.
6. Saved items get `source = 'manual'`.

**No AI call** during manual entry, so it's free and works with the catalog only. Nutrition for custom items is estimated later, only if a recipe uses them (§6.2 step 6).

### 6.2 Recipe generation
1. User picks options: servings, max time, meal type, cuisine (optional), "use expiring items first" (on by default), and "only use what I have" (off by default; when on, no `missing` ingredients are allowed).
2. `generate-recipes` loads the pantry, staples, preferences and allergens, and nutrition data for those ingredients.
3. Calls **Haiku 5.5** with structured output for 2–3 recipes. Ingredients must reference pantry item IDs, staples, or be marked `missing`.
4. **Validation:**
   - ingredients exist
   - quantities don't exceed what's on hand (except `missing` items)
   - no allergens appear: checked against `catalog.ingredients.allergens`, plus a name match for custom and free-text items
   - no `missing` items when "only use what I have" is on
   - required fields are present
5. If validation fails, **retry once on Sonnet 5.5**.
6. Macros are calculated on the server: `grams × per-100g nutrients`, per serving and total. Custom ingredients with no nutrition yet (from manual entry) get a one-off Haiku estimate, saved on the `ingredients_private` row and marked estimated.
7. Results are temporary until the user taps **Save** (which counts toward the 50 limit).

The system prompt requires safe cooking temperatures for meat, poultry and eggs. The recipe screen shows a short food-safety disclaimer.

### 6.3 Saved recipes
- List and search saved recipes. At 50, saving is blocked and the app offers "replace a recipe".
- Editing ingredients or servings triggers `recompute-macros`, and `source` becomes `edited`.
- Delete with confirmation and an undo toast.
- **"Cooked this"** shows a review of quantities to subtract from the pantry.

### 6.4 Shopping list
- On a recipe: **"Add missing to shopping list"** adds its `missing` ingredients (and amounts the pantry is short on).
- Manual add from catalog search or free text.
- Checking an item off can move it into the pantry (`source = 'shopping_list'`), with expiry calculated as in §6.1a.

### 6.5 Sharing
- **Share** creates a random `share_token` and opens the iOS share sheet with `https://<domain>/r/<token>`.
- **Without the app:** the link opens a read-only web page served by the Cloudflare Worker (D6).
- **With the app:** the Universal Link opens the recipe in the app with **"Save to my recipes"**.
- The page shows the recipe **as currently saved**, so the owner's edits appear. **Save to my recipes** stores an independent copy (`source = 'shared'`), which is the snapshot. The owner can revoke the link (clears `share_token`).
- *Requires the paid Apple Developer Program (for Universal Links), so it's not in the prototype.*

---

## 7. Gaps addressed

| Gap | Resolution |
|---|---|
| Authentication | Anonymous sign-in for the prototype → Sign in with Apple for v1 |
| Wrong scan results | Mandatory review screen; low-confidence items flagged |
| Manual entry | First-class alternative to scanning (§6.1b): catalog type-ahead, recent items, free-text custom items, batch "Add & next"; no AI cost |
| Units and quantities | Quantity + unit, converted to grams internally; "some" allowed |
| Pantry staples | User-defined staples list, always available |
| Diets and allergies | Collected during onboarding; in the prompt and checked in code against catalog allergen tags |
| Inventory never decreases | Used/discarded actions; "Cooked this" subtracts ingredients |
| Expiry alerts | Daily local notification digest; pantry sorted by expiry |
| Generated vs. saved recipes | Generated recipes are temporary; saving counts toward 50 |
| Macro accuracy | Calculated on the server from the catalog, never by the model |
| Unknown ingredients | Private ingredient with estimated nutrition |
| Share link behavior | Web page (D6) + Universal Link; the page shows the live recipe, and saving makes a copy; revocable |
| AI cost and abuse | Paid download, no per-user caps (D5); account spend limit, per-user usage log |
| Free AI through the public API key | AI functions require a verified App Store purchase (NFR-8, F0.6) |
| Photo privacy | Never stored or logged; stated in the privacy policy and App Store privacy labels |
| Account deletion | In-app deletion removes all `app` rows and revokes share links |
| Food safety | Safe-temperature rules in the prompt + disclaimer |
| Storage locations | Fridge, freezer, pantry, each with its own shelf life; user expiry overrides are per ingredient **and** location |
| Offline | Cached viewing and editing, synced with `updated_at` and soft deletes; scan and generate need a network connection |
| Household sharing | Deferred; `household_id` already in the schema |

---

## 8. Cost estimates

Prices: Claude Sonnet 5.5 at $2 / $10 per 1M input/output tokens, Haiku 5.5 at $0.10 / $0.50. Token counts are estimates (scan ≈ 6.5k in / 1.5k out; recipe set ≈ 3k in / 5k out).

| | Prototype | 100 users | 10,000 users |
|---|---|---|---|
| Supabase | $0 (free tier) | $25/month | ~$25–60/month |
| AI (worst case: every user scans 8× and generates 30× per month) | ~$3–5 total | ~$33/month | ~$3,300/month |
| AI (typical, 20–40% of worst case) | — | ~$7–13/month | ~$660–1,300/month |
| Apple Developer Program | $0 (free Apple ID) | $99/year | $99/year |
| Domain + Cloudflare Worker (D6) | $0 | ~$1/month | ~$1/month |

Per call: scan ≈ $0.03, recipe set ≈ $0.003. **AI is the largest cost at every scale.**

### Revenue (D5)
Net per US sale ≈ **$4.24** ($4.99 minus the 15% Small Business Program commission; EU prices include VAT, so they net less).

| | 100 users | 10,000 users |
|---|---|---|
| One-time revenue | ~$424 | ~$42,400 |
| Monthly running cost (typical AI) | ~$43 | ~$760–1,420 |
| Monthly running cost (worst-case AI) | ~$68 | ~$3,400 |
| Months covered with no new sales (typical / worst case) | ~10 / ~6 | ~30–55 / ~12 |

**Per user:** a worst-case user costs about $0.33/month in AI, so one purchase covers about 13 months of that user's heaviest use. A typical user costs about $0.07–0.13/month, which is 3–5 years.

The model works while new sales keep pace with the people still using the app. Track **cost per purchaser** (F5.2). Family Sharing can spread one purchase across several people (see §12).

---

## 9. Prototype plan (cost-efficient)

**Goal:** check scan accuracy and recipe quality on real use, at near-zero cost.

| Piece | Prototype choice |
|---|---|
| App distribution | Run from Xcode on the developer's phone with a free Apple ID (installs expire after 7 days) |
| Backend | Supabase free tier (pauses when idle; unpause from the dashboard) |
| Auth | Supabase anonymous sign-in |
| Catalog | ~100 hand-seeded common ingredients |
| AI | Hybrid per D3; model names in config so they can be swapped while testing |
| Notifications | Local only |

**In scope:** scan → review → pantry; manual add (catalog search + custom items); pantry list with expiry; recipe generation; save/edit/delete recipes; shopping list.
**Out of scope:** sharing, Sign in with Apple, 50-recipe limit, offline cache, full USDA import, account deletion, purchase verification.
**Pricing:** doesn't apply to the prototype. Xcode installs and TestFlight are free for testers.

**Estimated effort:** ~2 weeks. **Estimated cost:** ~$3–5 of AI usage.

---

## 10. Feature breakdown (v1)

Sizes: S = 1–2 days, M = 3–5 days, L = 1–2 weeks (one developer).

### Phase 0 — Foundations
| Feature | Stories | Size |
|---|---|---|
| F0.1 Project setup | Xcode SwiftUI project, Supabase project, dev/prod environments | S |
| F0.2 Auth & sessions | Anonymous → Sign in with Apple, keep session across launches, sign out, delete account | M |
| F0.3 Schemas | `catalog` and `app` migrations, row-level security, 50-recipe trigger, households | M |
| F0.4 Catalog seed | Import USDA FDC + FoodKeeper shelf lives, aliases, staples | L |
| F0.5 AI functions | Edge Functions, structured output, validation, Sonnet retry, usage logging | M |
| F0.6 Purchase verification | App Store purchase proof sent on sign-in, `verify-purchase` function, AI functions require it, sandbox allowed for TestFlight | S |

### Phase 1 — Pantry
| Feature | Stories | Size |
|---|---|---|
| F1.1 Photo scan | Camera, multiple photos, resize, location tag, upload | M |
| F1.2 Ingredient detection | Vision prompt, catalog matching, merging duplicates, confidence | L |
| F1.3 Scan review | Confirm/edit/delete/add, fix quantities and units | M |
| F1.4 Pantry list | Grouped by location, sorted by expiry, badges, search | M |
| F1.5 Manual add/edit | Add without scanning: catalog type-ahead, recent/frequent items, custom free-text items, "Add & next" batch entry, empty-state entry point; edit quantity/unit/expiry; used/discarded | M |
| F1.6 Expiry rules | Defaults, per-item override, per-ingredient user default | S |
| F1.7 Onboarding prefs | Diets, allergens, staples, default servings | S |

### Phase 2 — Recipe generation
| Feature | Stories | Size |
|---|---|---|
| F2.1 Request options | Servings, time, meal type, cuisine, use expiring first, only use what I have | S |
| F2.2 Generation pipeline | Prompt, structured output, validation, retry | L |
| F2.3 Macros | Server-side calculation, per serving and total, "estimated" flag | M |
| F2.4 Results UI | 2–3 candidate cards, detail view, regenerate | M |

### Phase 3 — Saved recipes & shopping list
| Feature | Stories | Size |
|---|---|---|
| F3.1 Save & list | Save, list, search, 50-limit message and replace | M |
| F3.2 Edit | Edit fields, recalculate macros on the server | M |
| F3.3 Delete | Confirmation, undo toast | S |
| F3.4 "Cooked this" | Subtract ingredients with review | M |
| F3.5 Shopping list | Add missing from recipe, manual add, check off, move to pantry | M |
| F3.6 Offline cache | SwiftData mirror, offline edits, sync | L |

### Phase 4 — Sharing
| Feature | Stories | Size |
|---|---|---|
| F4.1 Share link | Create/revoke token, share sheet | S |
| F4.2 Public page | Read-only web page on a Cloudflare Worker (D6); also serves the Universal Links file and privacy policy | M |
| F4.3 Universal Links | Open in app, "Save to my recipes" | M |
| F4.4 Export | Copy as text, export PDF | S |

### Phase 5 — Polish & launch
| Feature | Stories | Size |
|---|---|---|
| F5.1 Expiry notifications | Daily local digest, settings | S |
| F5.2 Observability | Crash reporting, product events, AI cost dashboard from `ai_usage_log` | S |
| F5.3 App Store readiness | Paid Apps Agreement, tax and banking, Small Business Program, $4.99 price, privacy policy, privacy labels, disclaimer, TestFlight, account spend limit | M |

**Total v1 estimate:** ~11–15 weeks for one developer.

---

## 11. Backlog (after v1)
1. Barcode scanning (Open Food Facts — free, attribution required)
2. Household sharing (schema already supports it)
3. Recipe images
4. Meal planning
5. User-contributed catalog entries (promote reviewed `ingredients_private` rows)
6. Embedding-based ingredient matching if fuzzy matching isn't good enough
7. Natural-language quick add ("2 eggs, half a gallon of milk") or voice entry, parsed by Haiku into manual-entry rows
8. Revisit pricing (a price change, or an optional subscription for heavy users) if AI cost per purchaser approaches the ≈$4.24 net per sale (§8)
9. App Store Server Notifications: remove AI access when a purchase is refunded

---

## 12. Risks and open questions
| Risk / question | Notes |
|---|---|
| Scan accuracy on cluttered fridges | Main thing the prototype tests. Fallback: switch scans to a stronger model, or ask for photos per shelf. |
| Haiku recipe quality | Prototype tests it; the retry on Sonnet limits bad output. Can switch recipes to Sonnet (~6x AI cost). |
| One-time revenue vs. ongoing AI cost (D5) | Each sale nets ≈$4.24 once, while costs continue. Track cost per purchaser (F5.2); account spend limit as the backstop; revisit pricing if needed (§11). |
| Paid download lowers adoption | Paid apps can't offer a free trial. Screenshots, the description and shared recipe pages have to sell it. Watch conversion in App Store Connect. |
| Family Sharing | Paid apps can be shared with up to 6 family members, each with their own account, so one sale can mean several users' AI cost. Accepted; check in App Store Connect whether it can be turned off. |
| Quantity estimation from photos | Expected to be rough; the review screen and "some" quantities absorb errors. Manual entry is the fallback if scans disappoint. |
| Pricing changes | Supabase and Claude prices were checked on 2026-06-02; re-check before budgeting. |
