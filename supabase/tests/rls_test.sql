-- F0.3 acceptance test: row-level security with two users, A and B.
-- Everything runs in one transaction that is rolled back, so it leaves no data behind.
--
-- Run against the hosted project:
--   supabase db query --remote --yes -f supabase/tests/rls_test.sql
-- Prints one row: PASS, or FAIL followed by the failed checks.

begin;

do $$
declare
  a  uuid := gen_random_uuid();
  b  uuid := gen_random_uuid();
  ha uuid;
  hb uuid;
  recipe_a uuid := gen_random_uuid();
  pantry_a uuid := gen_random_uuid();
  ing_id   bigint;
  n        int;
  failures text[] := '{}';
begin
  ------------------------------------------------------------------ setup (as postgres)
  insert into auth.users (id, aud, role) values (a, 'authenticated', 'authenticated'),
                                                (b, 'authenticated', 'authenticated');
  -- The sign-up trigger (F0.2) creates each user's household, app.users row and prefs.
  select household_id into ha from app.users where id = a;
  select household_id into hb from app.users where id = b;
  if ha is null or hb is null or ha = hb then
    failures := array_append(failures, 'sign-up trigger did not create separate households'::text);
  end if;
  select count(*) into n from app.user_prefs where user_id in (a, b) and default_servings = 2;
  if n <> 2 then failures := array_append(failures, 'sign-up trigger did not create default prefs'::text); end if;
  insert into catalog.ingredients (name) values ('rls-test-egg') returning id into ing_id;

  ------------------------------------------------------------------ act as A
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);

  -- Defaults fill in user_id / household_id from the session.
  update app.user_prefs set default_servings = 4;  -- own prefs are writable
  get diagnostics n = row_count; if n <> 1 then failures := array_append(failures, 'A cannot update own prefs'::text); end if;
  insert into app.recipes (id, title, source) values (recipe_a, 'A recipe', 'manual');
  insert into app.recipe_ingredients (recipe_id, position, name) values (recipe_a, 0, 'egg'), (recipe_a, 1, 'salt');
  insert into app.pantry_items (id, display_name, source) values (pantry_a, 'A eggs', 'manual');
  insert into app.shopping_list_items (name) values ('A milk');
  insert into app.ingredients_private (name) values ('A hot sauce');
  insert into app.user_shelf_life_overrides (ingredient_id, location, days) values (ing_id, 'fridge', 9);

  select count(*) into n from app.pantry_items where household_id = ha;
  if n <> 1 then failures := array_append(failures, 'A cannot see own pantry item'::text); end if;

  begin
    update app.users set subscription_expires_at = now() + interval '1 year' where id = a;
    failures := array_append(failures, 'A could give itself a subscription'::text);
  exception when insufficient_privilege then null;
  end;

  begin
    update app.users set household_id = hb where id = a;
    failures := array_append(failures, 'A could move itself into B''s household'::text);
  exception when insufficient_privilege then null;
  end;

  ------------------------------------------------------------------ act as B
  perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated')::text, true);

  -- B can't see any of A's rows.
  select count(*) into n from app.users where id = a;                       if n > 0 then failures := array_append(failures, 'B sees A in users'::text); end if;
  select count(*) into n from app.households where id = ha;                 if n > 0 then failures := array_append(failures, 'B sees A''s household'::text); end if;
  select count(*) into n from app.user_prefs where user_id = a;             if n > 0 then failures := array_append(failures, 'B sees A''s prefs'::text); end if;
  select count(*) into n from app.recipes where user_id = a;                if n > 0 then failures := array_append(failures, 'B sees A''s recipes'::text); end if;
  select count(*) into n from app.recipe_ingredients where recipe_id = recipe_a; if n > 0 then failures := array_append(failures, 'B sees A''s recipe ingredients'::text); end if;
  select count(*) into n from app.pantry_items where household_id = ha;     if n > 0 then failures := array_append(failures, 'B sees A''s pantry'::text); end if;
  select count(*) into n from app.shopping_list_items where household_id = ha; if n > 0 then failures := array_append(failures, 'B sees A''s shopping list'::text); end if;
  select count(*) into n from app.ingredients_private where user_id = a;    if n > 0 then failures := array_append(failures, 'B sees A''s private ingredients'::text); end if;
  select count(*) into n from app.user_shelf_life_overrides where user_id = a; if n > 0 then failures := array_append(failures, 'B sees A''s shelf-life overrides'::text); end if;

  -- B can't update or delete A's rows (RLS makes them invisible, so 0 rows change).
  update app.recipes set title = 'hacked' where id = recipe_a;              get diagnostics n = row_count; if n > 0 then failures := array_append(failures, 'B updated A''s recipe'::text); end if;
  update app.pantry_items set quantity = 0 where id = pantry_a;            get diagnostics n = row_count; if n > 0 then failures := array_append(failures, 'B updated A''s pantry item'::text); end if;
  update app.recipe_ingredients set name = 'x' where recipe_id = recipe_a; get diagnostics n = row_count; if n > 0 then failures := array_append(failures, 'B updated A''s recipe ingredients'::text); end if;
  delete from app.recipes where id = recipe_a;                              get diagnostics n = row_count; if n > 0 then failures := array_append(failures, 'B deleted A''s recipe'::text); end if;
  delete from app.pantry_items where id = pantry_a;                        get diagnostics n = row_count; if n > 0 then failures := array_append(failures, 'B deleted A''s pantry item'::text); end if;
  delete from app.shopping_list_items where household_id = ha;             get diagnostics n = row_count; if n > 0 then failures := array_append(failures, 'B deleted A''s shopping items'::text); end if;

  -- B can't write into A's household or attach rows to A's recipe.
  begin
    insert into app.pantry_items (household_id, display_name, source) values (ha, 'planted', 'manual');
    failures := array_append(failures, 'B inserted into A''s pantry'::text);
  exception when insufficient_privilege then null;
  end;
  begin
    insert into app.recipe_ingredients (recipe_id, position, name) values (recipe_a, 9, 'planted');
    failures := array_append(failures, 'B added an ingredient to A''s recipe'::text);
  exception when insufficient_privilege then null;
  end;
  begin
    insert into app.recipes (user_id, title, source) values (a, 'planted', 'manual');
    failures := array_append(failures, 'B created a recipe owned by A'::text);
  exception when insufficient_privilege then null;
  end;

  -- ai_usage_log is service-role only.
  begin
    insert into app.ai_usage_log (user_id, kind, model, input_tokens, output_tokens) values (b, 'scan', 'x', 1, 1);
    failures := array_append(failures, 'B wrote ai_usage_log'::text);
  exception when insufficient_privilege then null;
  end;

  -- B can read the catalog but not write it.
  select count(*) into n from catalog.ingredients where id = ing_id;
  if n <> 1 then failures := array_append(failures, 'B cannot read catalog'::text); end if;
  select count(*) into n from catalog.ingredients
   where catalog.aliases_text(aliases) is not null and id = ing_id;
  if n <> 1 then failures := array_append(failures, 'B cannot use catalog.aliases_text'::text); end if;
  begin
    insert into catalog.ingredients (name) values ('planted');
    failures := array_append(failures, 'B inserted into catalog'::text);
  exception when insufficient_privilege then null;
  end;
  begin
    update catalog.ingredients set name = 'hacked' where id = ing_id;
    failures := array_append(failures, 'B updated catalog'::text);
  exception when insufficient_privilege then null;
  end;
  begin
    delete from catalog.ingredients where id = ing_id;
    failures := array_append(failures, 'B deleted from catalog'::text);
  exception when insufficient_privilege then null;
  end;

  ------------------------------------------------------------------ cascade, as A
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  select count(*) into n from app.recipes where id = recipe_a and title = 'A recipe';
  if n <> 1 then failures := array_append(failures, 'A''s recipe was changed by B'::text); end if;
  delete from app.recipes where id = recipe_a;
  select count(*) into n from app.recipe_ingredients where recipe_id = recipe_a;
  if n > 0 then failures := array_append(failures, 'deleting a recipe did not cascade to recipe_ingredients'::text); end if;

  ------------------------------------------------------------------ report
  perform set_config('fridge.rls_result',
    case when cardinality(failures) = 0 then 'PASS'
         else 'FAIL: ' || array_to_string(failures, '; ') end, true);
end
$$;

select current_setting('fridge.rls_result') as result;

rollback;
