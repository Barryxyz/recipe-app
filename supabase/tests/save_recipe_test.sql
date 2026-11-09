-- F3.1 acceptance test: app.save_recipe writes the recipe and its ingredients atomically,
-- only for the caller, and soft delete / restore work under RLS. Rolled back.
--
--   ./scripts/test.sh db
-- Prints one row: PASS, or FAIL followed by the failed checks.

begin;

do $$
declare
  a uuid := gen_random_uuid();
  b uuid := gen_random_uuid();
  failures text[] := '{}';
  rid uuid;
  n int;
  r record;
begin
  insert into auth.users (id, aud, role) values (a, 'authenticated', 'authenticated'),
                                                (b, 'authenticated', 'authenticated');
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);

  rid := app.save_recipe(jsonb_build_object(
    'title', '  Garlic chicken  ', 'description', 'Quick.', 'servings', 2, 'prep_min', 10, 'cook_min', 20,
    'steps', jsonb_build_array('Heat the oil.', 'Cook the chicken.'),
    'macros_per_serving', jsonb_build_object('kcal', 520, 'estimated', false),
    'macros_total', jsonb_build_object('kcal', 1040, 'estimated', false),
    'model_version', 'claude-haiku-5-5',
    'ingredients', jsonb_build_array(
      jsonb_build_object('name', 'chicken breast', 'ingredient_id', 52, 'quantity', 300, 'unit', 'g', 'grams', 300,
                         'pantry_item_id', gen_random_uuid()),
      jsonb_build_object('name', 'lime', 'quantity', 1, 'unit', 'each', 'note', 'juiced'),
      jsonb_build_object('name', 'parsley', 'is_optional', true))));

  select * into r from app.recipes where id = rid;
  if r.title <> 'Garlic chicken' or r.source <> 'ai' or r.servings <> 2 or r.model_version <> 'claude-haiku-5-5'
     or jsonb_array_length(r.steps) <> 2 or (r.macros_per_serving->>'kcal')::int <> 520 then
    failures := array_append(failures, format('recipe row wrong: %s', row_to_json(r)));
  end if;
  select count(*) into n from app.recipe_ingredients where recipe_id = rid;
  if n <> 3 then failures := array_append(failures, format('%s ingredient rows, expected 3', n)); end if;
  select count(*) into n from app.recipe_ingredients
   where recipe_id = rid and position = 0 and ingredient_id = 52 and grams = 300;
  if n <> 1 then failures := array_append(failures, 'first ingredient not stored in order with its id'::text); end if;
  select count(*) into n from app.recipe_ingredients where recipe_id = rid and name = 'parsley' and is_optional;
  if n <> 1 then failures := array_append(failures, 'optional flag lost'::text); end if;

  -- Atomic: a bad ingredient leaves nothing behind.
  select count(*) into n from app.recipes;
  begin
    perform app.save_recipe(jsonb_build_object('title', 'Broken', 'steps', '[]'::jsonb,
      'ingredients', jsonb_build_array(jsonb_build_object('name', 'ok'), jsonb_build_object('name', ' '))));
    failures := array_append(failures, 'blank ingredient name accepted'::text);
  exception when invalid_parameter_value then null;
  end;
  if (select count(*) from app.recipes) <> n then
    failures := array_append(failures, 'a failed save left a recipe behind'::text);
  end if;

  -- Soft delete and undo (F3.3).
  update app.recipes set deleted_at = now() where id = rid;
  if (select count(*) from app.recipes where id = rid and deleted_at is not null) <> 1 then
    failures := array_append(failures, 'soft delete failed'::text);
  end if;
  update app.recipes set deleted_at = null where id = rid;

  -- B can't see or change A's recipe.
  perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated')::text, true);
  select count(*) into n from app.recipes where id = rid;
  if n <> 0 then failures := array_append(failures, 'B can see A''s recipe'::text); end if;
  update app.recipes set deleted_at = now() where id = rid;
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  if (select deleted_at from app.recipes where id = rid) is not null then
    failures := array_append(failures, 'B deleted A''s recipe'::text);
  end if;

  perform set_config('fridge.test_result',
    case when cardinality(failures) = 0 then 'PASS'
         else 'FAIL: ' || array_to_string(failures, '; ') end, true);
end
$$;

select current_setting('fridge.test_result') as result;

rollback;
