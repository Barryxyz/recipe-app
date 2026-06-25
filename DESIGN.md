# Fridge App — Design Document

**Status:** Draft v1.1 · **Last updated:** 2026-06-24 · **Platform:** iOS only

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

### Non-goals (v1)
- Android or web app (a web page exists only to view shared recipes).
- Barcode scanning (deferred, see §11).
- Household / shared fridges (deferred; the schema is ready for it, see §5).
- Meal planning, recipe images, paid tiers.

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

---

## 3. Decisions

| # | Decision | Choice | Rejected alternatives |
|---|---|---|---|
| D1 | Database separation | **One Postgres database with two schemas:** `catalog` (shared ingredient/nutrition data) and `app` (per-user data) | Two physical databases (no joins, ~+$10/month); Postgres + search engine (extra system) |
| D2 | Backend platform | **Supabase.** Free tier for the prototype, Pro ($25/month) for production | EC2 (days–weeks of setup and ongoing maintenance), Firebase (NoSQL conflicts with D1), CloudKit (can't run AI calls) |
| D3 | AI models | **Hybrid:** Claude Sonnet 5.5 for photo scans, Claude Haiku 5.5 for recipe generation. Model is a config value. | Sonnet for everything (~6x cost), Haiku for everything (weaker scans), Opus 5.5 (~11x cost) |
| D4 | v1 scope | **Shopping list included.** Barcode scanning and household sharing deferred. | — |
| D5 | Business model | **Completely free, no per-user caps** | Free with caps, freemium subscription, one-time purchase |

### Rationale
- **D1:** Joins between recipes, ingredients and nutrition stay in one query. Each schema has its own permissions. Either schema can move to its own database later without changing app code.
- **D2:** Postgres matches D1. Supabase provides auth (anonymous now, Sign in with Apple later), row-level security, and Edge Functions to relay AI calls. Prototype code carries straight into production.
- **D3:** Scans are infrequent and accuracy is what users notice first, so they get the stronger vision model. Recipe generation is the frequent call. Server-side checks (§6.2) catch Haiku mistakes, with one retry on Sonnet if checks fail.
- **D5:** Accepted risk: AI costs grow with usage and have no per-user ceiling. **Mitigation:** set a monthly spend limit on the Anthropic account before inviting anyone besides the developer, and log token usage per user so abuse is visible.

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
│  (offline viewing)   │        │   • share-page (public HTML)    │                     │
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
  is_common_staple         boolean default false     -- salt, oil, pepper
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
  created_at timestamptz,
  deleted_at timestamptz
)

app.user_prefs (
  user_id uuid primary key references app.users,
  diets text[], allergens text[],
  staple_ingredient_ids bigint[],  -- always treated as available
  default_servings int default 2
)

app.user_shelf_life_overrides (    -- "customizable expiry" per ingredient type
  user_id uuid, ingredient_id bigint, days int,
  primary key (user_id, ingredient_id)
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
  source text check (source in ('ai','edited')),
  model_version text,
  share_token text unique,         -- null = not shared
  created_at timestamptz, updated_at timestamptz
)
-- Trigger: reject inserts when the user already has 50 recipes.

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
7. Unknown items become `ingredients_private` rows with model-estimated nutrition, marked "estimated".

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
1. User picks options: servings, max time, meal type, cuisine (optional), "use expiring items first" (on by default).
2. `generate-recipes` loads the pantry, staples, preferences and allergens, and nutrition data for those ingredients.
3. Calls **Haiku 5.5** with structured output for 2–3 recipes. Ingredients must reference pantry item IDs, staples, or be marked `missing`.
4. **Validation:** ingredients exist, quantities don't exceed what's on hand (except `missing` items), no allergens appear, required fields are present.
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
- **Without the app:** the link opens a read-only web page served by `share-page`.
- **With the app:** the Universal Link opens the recipe in the app with **"Save to my recipes"**.
- The link shows a snapshot of the recipe. The owner can revoke it (clears `share_token`).
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
| Diets and allergies | Collected during onboarding; in the prompt and checked in code |
| Inventory never decreases | Used/discarded actions; "Cooked this" subtracts ingredients |
| Expiry alerts | Daily local notification digest; pantry sorted by expiry |
| Generated vs. saved recipes | Generated recipes are temporary; saving counts toward 50 |
| Macro accuracy | Calculated on the server from the catalog, never by the model |
| Unknown ingredients | Private ingredient with estimated nutrition |
| Share link behavior | Web page + Universal Link, snapshot, revocable |
| AI cost and abuse | No per-user caps (D5); account spend limit + per-user usage log |
| Photo privacy | Never stored or logged; stated in the privacy policy and App Store privacy labels |
| Account deletion | In-app deletion removes all `app` rows and revokes share links |
| Food safety | Safe-temperature rules in the prompt + disclaimer |
| Storage locations | Fridge, freezer, pantry, each with its own shelf life |
| Offline | Cached viewing and editing; scan and generate need a network connection |
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

Per call: scan ≈ $0.03, recipe set ≈ $0.003. **AI is the largest cost at every scale.** With no per-user caps (D5), revisit the business model before growing toward 10,000 users.

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
**Out of scope:** sharing, Sign in with Apple, 50-recipe limit, offline cache, full USDA import, account deletion.

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
| F2.1 Request options | Servings, time, meal type, cuisine, use expiring first | S |
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
| F4.2 Public page | Read-only web page via Edge Function | M |
| F4.3 Universal Links | Open in app, "Save to my recipes" | M |
| F4.4 Export | Copy as text, export PDF | S |

### Phase 5 — Polish & launch
| Feature | Stories | Size |
|---|---|---|
| F5.1 Expiry notifications | Daily local digest, settings | S |
| F5.2 Observability | Crash reporting, product events, AI cost dashboard from `ai_usage_log` | S |
| F5.3 App Store readiness | Privacy policy, privacy labels, disclaimer, TestFlight, account spend limit | M |

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
8. Revisit the business model (caps or freemium) before scaling toward 10,000 users

---

## 12. Risks and open questions
| Risk / question | Notes |
|---|---|
| Scan accuracy on cluttered fridges | Main thing the prototype tests. Fallback: switch scans to a stronger model, or ask for photos per shelf. |
| Haiku recipe quality | Prototype tests it; the retry on Sonnet limits bad output. Can switch recipes to Sonnet (~6x AI cost). |
| Uncapped AI cost (D5) | Account spend limit + usage log; revisit before growth. |
| Quantity estimation from photos | Expected to be rough; the review screen and "some" quantities absorb errors. Manual entry is the fallback if scans disappoint. |
| Pricing changes | Supabase and Claude prices were checked on 2026-06-02; re-check before budgeting. |
