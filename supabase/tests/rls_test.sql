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
  ha uuid := gen_random_uuid();
  hb uuid := gen_random_uuid();
  recipe_a uuid := gen_random_uuid();
  pantry_a uuid := gen_random_uuid();
  ing_id   bigint;
  n        int;
  failures text[] := '{}';
begin
  ------------------------------------------------------------------ setup (as postgres)
  insert into auth.users (id, aud, role) values (a, 'authenticated', 'authenticated'),
                                                (b, 'authenticated', 'authenticated');
  insert into app.households (id) values (ha), (hb);
  insert into app.users (id, household_id) values (a, ha), (b, hb);
  insert into catalog.ingredients (name) values ('rls-test-egg') returning id into ing_id;

  ------------------------------------------------------------------ act as A
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);

  -- Defaults fill in user_id / household_id from the session.
  insert into app.user_prefs default values;
  insert into app.recipes (id, title, source) values (recipe_a, 'A recipe', 'manual');
  insert into app.recipe_ingredients (recipe_id, position, name) values (recipe_a, 0, 'egg'), (recipe_a, 1, 'salt');
  insert into app.pantry_items (id, display_name, source) values (pantry_a, 'A eggs', 'manual');
  insert into app.shopping_list_items (name) values ('A milk');
  insert into app.ingredients_private (name) values ('A hot sauce');
  insert into app.user_shelf_life_overrides (ingredient_id, location, days) values (ing_id, 'fridge', 9);

  select count(*) into n from app.pantry_items where household_id = ha;
  if n <> 1 then failures := failures || 'A cannot see own pantry item'; end if;

  begin
    update app.users set purchase_verified_at = now() where id = a;
    failures := failures || 'A could mark itself purchase-verified';
  exception when insufficient_privilege then null;
  end;

  begin
    update app.users set household_id = hb where id = a;
    failures := failures || 'A could move itself into B''s household';
  exception when insufficient_privilege then null;
  end;

  ------------------------------------------------------------------ act as B
  perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated')::text, true);

  -- B can't see any of A's rows.
  select count(*) into n from app.users where id = a;                       if n > 0 then failures := failures || 'B sees A in users'; end if;
  select count(*) into n from app.households where id = ha;                 if n > 0 then failures := failures || 'B sees A''s household'; end if;
  select count(*) into n from app.user_prefs where user_id = a;             if n > 0 then failures := failures || 'B sees A''s prefs'; end if;
  select count(*) into n from app.recipes where user_id = a;                if n > 0 then failures := failures || 'B sees A''s recipes'; end if;
  select count(*) into n from app.recipe_ingredients where recipe_id = recipe_a; if n > 0 then failures := failures || 'B sees A''s recipe ingredients'; end if;
  select count(*) into n from app.pantry_items where household_id = ha;     if n > 0 then failures := failures || 'B sees A''s pantry'; end if;
  select count(*) into n from app.shopping_list_items where household_id = ha; if n > 0 then failures := failures || 'B sees A''s shopping list'; end if;
  select count(*) into n from app.ingredients_private where user_id = a;    if n > 0 then failures := failures || 'B sees A''s private ingredients'; end if;
  select count(*) into n from app.user_shelf_life_overrides where user_id = a; if n > 0 then failures := failures || 'B sees A''s shelf-life overrides'; end if;

  -- B can't update or delete A's rows (RLS makes them invisible, so 0 rows change).
  update app.recipes set title = 'hacked' where id = recipe_a;              get diagnostics n = row_count; if n > 0 then failures := failures || 'B updated A''s recipe'; end if;
  update app.pantry_items set quantity = 0 where id = pantry_a;            get diagnostics n = row_count; if n > 0 then failures := failures || 'B updated A''s pantry item'; end if;
  update app.recipe_ingredients set name = 'x' where recipe_id = recipe_a; get diagnostics n = row_count; if n > 0 then failures := failures || 'B updated A''s recipe ingredients'; end if;
  delete from app.recipes where id = recipe_a;                              get diagnostics n = row_count; if n > 0 then failures := failures || 'B deleted A''s recipe'; end if;
  delete from app.pantry_items where id = pantry_a;                        get diagnostics n = row_count; if n > 0 then failures := failures || 'B deleted A''s pantry item'; end if;
  delete from app.shopping_list_items where household_id = ha;             get diagnostics n = row_count; if n > 0 then failures := failures || 'B deleted A''s shopping items'; end if;

  -- B can't write into A's household or attach rows to A's recipe.
  begin
    insert into app.pantry_items (household_id, display_name, source) values (ha, 'planted', 'manual');
    failures := failures || 'B inserted into A''s pantry';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into app.recipe_ingredients (recipe_id, position, name) values (recipe_a, 9, 'planted');
    failures := failures || 'B added an ingredient to A''s recipe';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into app.recipes (user_id, title, source) values (a, 'planted', 'manual');
    failures := failures || 'B created a recipe owned by A';
  exception when insufficient_privilege then null;
  end;

  -- ai_usage_log is service-role only.
  begin
    insert into app.ai_usage_log (user_id, kind, model, input_tokens, output_tokens) values (b, 'scan', 'x', 1, 1);
    failures := failures || 'B wrote ai_usage_log';
  exception when insufficient_privilege then null;
  end;

  -- B can read the catalog but not write it.
  select count(*) into n from catalog.ingredients where id = ing_id;
  if n <> 1 then failures := failures || 'B cannot read catalog'; end if;
  select count(*) into n from catalog.ingredients
   where catalog.aliases_text(aliases) is not null and id = ing_id;
  if n <> 1 then failures := failures || 'B cannot use catalog.aliases_text'; end if;
  begin
    insert into catalog.ingredients (name) values ('planted');
    failures := failures || 'B inserted into catalog';
  exception when insufficient_privilege then null;
  end;
  begin
    update catalog.ingredients set name = 'hacked' where id = ing_id;
    failures := failures || 'B updated catalog';
  exception when insufficient_privilege then null;
  end;
  begin
    delete from catalog.ingredients where id = ing_id;
    failures := failures || 'B deleted from catalog';
  exception when insufficient_privilege then null;
  end;

  ------------------------------------------------------------------ cascade, as A
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  select count(*) into n from app.recipes where id = recipe_a and title = 'A recipe';
  if n <> 1 then failures := failures || 'A''s recipe was changed by B'; end if;
  delete from app.recipes where id = recipe_a;
  select count(*) into n from app.recipe_ingredients where recipe_id = recipe_a;
  if n > 0 then failures := failures || 'deleting a recipe did not cascade to recipe_ingredients'; end if;

  ------------------------------------------------------------------ report
  perform set_config('fridge.rls_result',
    case when cardinality(failures) = 0 then 'PASS'
         else 'FAIL: ' || array_to_string(failures, '; ') end, true);
end
$$;

select current_setting('fridge.rls_result') as result;

rollback;
