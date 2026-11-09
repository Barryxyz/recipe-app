-- F3.2 acceptance test: app.update_recipe replaces fields and ingredients atomically, sets
-- source 'edited' for AI recipes (manual stays manual), validates, and is limited to the owner.
--
--   ./scripts/test.sh db

begin;

do $$
declare
  a uuid := gen_random_uuid();
  b uuid := gen_random_uuid();
  failures text[] := '{}';
  ai_id uuid;
  manual_id uuid;
  n int;
  r record;
  good jsonb := jsonb_build_object(
    'title', ' Chicken for four ', 'description', 'Doubled.', 'servings', 4, 'prep_min', 15, 'cook_min', 25,
    'steps', jsonb_build_array('Heat.', ' Cook. '),
    'ingredients', jsonb_build_array(
      jsonb_build_object('name', 'chicken breast', 'ingredient_id', 52, 'quantity', 600, 'unit', 'g', 'grams', 600),
      jsonb_build_object('name', 'gochujang paste', 'quantity', 2, 'unit', 'tbsp', 'is_optional', true)));
begin
  insert into auth.users (id, aud, role) values (a, 'authenticated', 'authenticated'),
                                                (b, 'authenticated', 'authenticated');
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);

  ai_id := app.save_recipe(jsonb_build_object('title', 'Chicken', 'servings', 2, 'steps', jsonb_build_array('Cook.'),
    'ingredients', jsonb_build_array(jsonb_build_object('name', 'chicken breast', 'ingredient_id', 52, 'quantity', 300, 'unit', 'g'),
                                     jsonb_build_object('name', 'lime'), jsonb_build_object('name', 'salt'))));
  manual_id := app.save_recipe(jsonb_build_object('title', 'Mine', 'source', 'manual', 'servings', 1,
    'steps', jsonb_build_array('Do it.'), 'ingredients', jsonb_build_array(jsonb_build_object('name', 'egg'))));

  perform app.update_recipe(ai_id, good);
  select * into r from app.recipes where id = ai_id;
  if r.title <> 'Chicken for four' or r.servings <> 4 or r.prep_min <> 15 or r.cook_min <> 25
     or r.source <> 'edited' or r.steps <> '["Heat.", "Cook."]'::jsonb then
    failures := array_append(failures, format('updated recipe wrong: %s', row_to_json(r)));
  end if;
  select count(*) into n from app.recipe_ingredients where recipe_id = ai_id;
  if n <> 2 then failures := array_append(failures, format('%s ingredient rows, expected 2 (replaced)', n)); end if;
  select count(*) into n from app.recipe_ingredients
   where recipe_id = ai_id and position = 1 and name = 'gochujang paste' and is_optional and ingredient_id is null;
  if n <> 1 then failures := array_append(failures, 'free-text ingredient not stored as typed'::text); end if;

  perform app.update_recipe(manual_id, good);
  if (select source from app.recipes where id = manual_id) <> 'manual' then
    failures := array_append(failures, 'manual recipe changed source'::text);
  end if;

  -- Validation: each bad edit fails and changes nothing.
  declare
    bad jsonb;
    cases jsonb[] := array[
      good || jsonb_build_object('title', ''),
      good || jsonb_build_object('title', repeat('x', 81)),
      good || jsonb_build_object('description', repeat('x', 301)),
      good || jsonb_build_object('servings', 13),
      good || jsonb_build_object('cook_min', 601),
      good || jsonb_build_object('ingredients', '[]'::jsonb),
      good || jsonb_build_object('steps', jsonb_build_array('ok', '  ')),
      good || jsonb_build_object('ingredients', jsonb_build_array(jsonb_build_object('name', ' ')))];
  begin
    foreach bad in array cases loop
      begin
        perform app.update_recipe(ai_id, bad || jsonb_build_object('description', coalesce(bad->>'description', 'X')));
        failures := array_append(failures, format('accepted bad edit %s', left(bad::text, 80)));
      exception when invalid_parameter_value then null;
      end;
    end loop;
  end;
  if (select description from app.recipes where id = ai_id) <> 'Doubled.' then
    failures := array_append(failures, 'a failed edit changed the recipe'::text);
  end if;
  select count(*) into n from app.recipe_ingredients where recipe_id = ai_id;
  if n <> 2 then failures := array_append(failures, 'a failed edit changed the ingredients'::text); end if;

  -- B can't edit A's recipe.
  perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated')::text, true);
  begin
    perform app.update_recipe(ai_id, good || jsonb_build_object('title', 'Hacked'));
    failures := array_append(failures, 'B edited A''s recipe'::text);
  exception when no_data_found then null;
  end;

  perform set_config('fridge.test_result',
    case when cardinality(failures) = 0 then 'PASS'
         else 'FAIL: ' || array_to_string(failures, '; ') end, true);
end
$$;

select current_setting('fridge.test_result') as result;

rollback;
