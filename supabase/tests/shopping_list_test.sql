-- F3.5 acceptance test: app.add_shopping_items merges into unchecked rows and adds the rest;
-- app.move_bought_to_pantry makes pantry items (custom ingredients for free text, expiry
-- from F1.6) and removes the rows; everything is limited to the household.
--
--   ./scripts/test.sh db

begin;

do $$
declare
  a uuid := gen_random_uuid();
  b uuid := gen_random_uuid();
  failures text[] := '{}';
  chicken uuid; herbs uuid; checked_row uuid;
  n int;
  r record;
begin
  insert into auth.users (id, aud, role) values (a, 'authenticated', 'authenticated'),
                                                (b, 'authenticated', 'authenticated');
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);

  -- First add: two new rows, one with a recipe title only (an unsaved idea).
  n := app.add_shopping_items(jsonb_build_array(
    jsonb_build_object('ingredient_id', 52, 'name', 'chicken breast', 'quantity', 250, 'unit', 'g',
                       'source_recipe_title', 'Lemon chicken'),
    jsonb_build_object('name', 'za''atar mix', 'quantity', null, 'unit', null)));
  select id into chicken from app.shopping_list_items where name = 'chicken breast';
  select id into herbs from app.shopping_list_items where name = 'za''atar mix';
  if n <> 2 or chicken is null or herbs is null then
    failures := array_append(failures, format('first add: %s rows', n));
  end if;
  if (select source_recipe_title from app.shopping_list_items where id = chicken) <> 'Lemon chicken' then
    failures := array_append(failures, 'recipe title not kept'::text);
  end if;

  -- Same recipe again: merged into the unchecked row, no duplicate.
  perform app.add_shopping_items(jsonb_build_array(
    jsonb_build_object('merge_id', chicken, 'ingredient_id', 52, 'name', 'chicken breast', 'quantity', 250, 'unit', 'g')));
  select count(*) into n from app.shopping_list_items where ingredient_id = 52;
  if n <> 1 or (select quantity from app.shopping_list_items where id = chicken) <> 500 then
    failures := array_append(failures, format('merge wrong: %s rows, %s g', n,
      (select quantity from app.shopping_list_items where id = chicken)));
  end if;

  -- Merging into a checked row adds a new row instead.
  insert into app.shopping_list_items (ingredient_id, name, quantity, unit, checked)
       values (39, 'milk', 1, 'l', true) returning id into checked_row;
  perform app.add_shopping_items(jsonb_build_array(
    jsonb_build_object('merge_id', checked_row, 'ingredient_id', 39, 'name', 'milk', 'quantity', 1, 'unit', 'l')));
  select count(*) into n from app.shopping_list_items where ingredient_id = 39;
  if n <> 2 then failures := array_append(failures, 'merged into a bought (checked) row'::text); end if;

  begin
    perform app.add_shopping_items(jsonb_build_array(jsonb_build_object('name', '  ')));
    failures := array_append(failures, 'accepted an empty name'::text);
  exception when invalid_parameter_value then null;
  end;

  -- B can't see or move A's rows.
  perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated')::text, true);
  select count(*) into n from app.shopping_list_items;
  if n <> 0 then failures := array_append(failures, format('B sees %s of A''s rows', n)); end if;
  if app.move_bought_to_pantry(jsonb_build_array(jsonb_build_object('id', chicken, 'location', 'fridge'))) <> 0 then
    failures := array_append(failures, 'B moved A''s row'::text);
  end if;
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);

  -- Move to pantry: catalog item keeps its id and gets an expiry; free text becomes custom.
  n := app.move_bought_to_pantry(jsonb_build_array(
    jsonb_build_object('id', chicken, 'location', 'fridge', 'quantity', 450, 'unit', 'g'),
    jsonb_build_object('id', herbs, 'location', 'pantry')));
  if n <> 2 then failures := array_append(failures, format('moved %s, expected 2', n)); end if;
  select * into r from app.pantry_items where display_name = 'chicken breast';
  if r.ingredient_id <> 52 or r.quantity <> 450 or r.unit <> 'g' or r.source <> 'shopping_list'
     or r.status <> 'active' or r.expires_at is null or r.location <> 'fridge' then
    failures := array_append(failures, format('pantry chicken wrong: %s', row_to_json(r)));
  end if;
  select * into r from app.pantry_items where display_name = 'za''atar mix';
  if r.ingredient_id is null or r.ingredient_id < 1000000000000 or r.quantity is not null or r.unit <> 'each' then
    failures := array_append(failures, format('free-text item not custom: %s', row_to_json(r)));
  end if;
  if exists (select 1 from app.shopping_list_items where id in (chicken, herbs)) then
    failures := array_append(failures, 'moved rows still on the list'::text);
  end if;

  begin
    perform app.move_bought_to_pantry(jsonb_build_array(jsonb_build_object('id', checked_row, 'location', 'garage')));
    failures := array_append(failures, 'accepted a bad location'::text);
  exception when invalid_parameter_value then null;
  end;

  perform set_config('fridge.test_result',
    case when cardinality(failures) = 0 then 'PASS'
         else 'FAIL: ' || array_to_string(failures, '; ') end, true);
end
$$;

select current_setting('fridge.test_result') as result;

rollback;
