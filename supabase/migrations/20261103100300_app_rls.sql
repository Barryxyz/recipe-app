-- F0.3: row-level security and grants for the app schema (NFR-4).
-- Users only ever see their own rows, or their household's for pantry and shopping list.
-- The service role bypasses RLS (Edge Functions, sign-up trigger, admin).

alter table app.households                enable row level security;
alter table app.users                     enable row level security;
alter table app.user_prefs                enable row level security;
alter table app.user_shelf_life_overrides enable row level security;
alter table app.ingredients_private       enable row level security;
alter table app.pantry_items              enable row level security;
alter table app.recipes                   enable row level security;
alter table app.recipe_ingredients        enable row level security;
alter table app.shopping_list_items       enable row level security;
alter table app.ai_usage_log              enable row level security;

-- households: read your own; rows are created by the sign-up trigger (F0.2).
create policy "read own household" on app.households
  for select to authenticated
  using (id = (select app.current_household_id()));

-- users: read your own row. No client writes at all: household_id must not be
-- changeable (it would grant access to another household) and the purchase columns
-- are set only by verify-purchase (F0.6). Account deletion runs server-side (F0.2).
create policy "read own user" on app.users
  for select to authenticated
  using (id = (select auth.uid()));

-- Own-row tables: full access to your own rows.
create policy "own rows" on app.user_prefs
  for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "own rows" on app.user_shelf_life_overrides
  for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "own rows" on app.ingredients_private
  for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "own rows" on app.recipes
  for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- Household tables.
create policy "household rows" on app.pantry_items
  for all to authenticated
  using (household_id = (select app.current_household_id()))
  with check (household_id = (select app.current_household_id()));
create policy "household rows" on app.shopping_list_items
  for all to authenticated
  using (household_id = (select app.current_household_id()))
  with check (household_id = (select app.current_household_id()));

-- recipe_ingredients follow their parent recipe.
create policy "rows of own recipes" on app.recipe_ingredients
  for all to authenticated
  using (exists (select 1 from app.recipes r where r.id = recipe_id and r.user_id = (select auth.uid())))
  with check (exists (select 1 from app.recipes r where r.id = recipe_id and r.user_id = (select auth.uid())));

-- ai_usage_log: no policies, so clients can't read or write it. Service role only.

-- Grants. RLS decides which rows; grants decide which operations.
grant select on app.households, app.users to authenticated;
grant select, insert, update, delete on
  app.user_prefs, app.user_shelf_life_overrides, app.ingredients_private,
  app.pantry_items, app.recipes, app.recipe_ingredients, app.shopping_list_items
  to authenticated;
grant usage, select on sequence app.ingredients_private_id_seq to authenticated;
grant execute on function app.current_household_id() to authenticated;

grant all on all tables in schema app to service_role;
grant usage, select on all sequences in schema app to service_role;
grant execute on all functions in schema app to service_role;

-- Functions are executable by PUBLIC by default; keep the helper away from `anon`.
revoke execute on function app.current_household_id() from public, anon;
revoke execute on function app.set_updated_at() from public, anon, authenticated;
