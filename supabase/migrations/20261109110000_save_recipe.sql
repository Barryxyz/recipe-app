-- F3.1: save a generated recipe (recipe + ingredients in one transaction).
-- The 50-recipe limit of the original spec is dropped (subscription model); a safety cap of
-- 1,000 saved recipes per user remains. Deleting is a soft delete (deleted_at), see F3.3.

create function app.save_recipe(recipe jsonb)
returns uuid
language plpgsql
volatile
set search_path = ''
as $$
declare
  new_id uuid;
  ing jsonb;
  pos int := 0;
begin
  if coalesce(btrim(recipe->>'title'), '') = '' then
    raise exception 'a recipe needs a title' using errcode = '22023';
  end if;
  if jsonb_typeof(recipe->'steps') <> 'array' or jsonb_typeof(recipe->'ingredients') <> 'array' then
    raise exception 'steps and ingredients must be arrays' using errcode = '22023';
  end if;
  if jsonb_array_length(recipe->'ingredients') > 100 or jsonb_array_length(recipe->'steps') > 100 then
    raise exception 'too many ingredients or steps' using errcode = '22023';
  end if;
  if (select count(*) from app.recipes r where r.user_id = auth.uid() and r.deleted_at is null) >= 1000 then
    raise exception 'recipe_limit_reached' using errcode = 'P0001', hint = 'You can save up to 1,000 recipes.';
  end if;

  insert into app.recipes (title, description, servings, prep_min, cook_min, steps,
                           macros_per_serving, macros_total, source, model_version)
  values (btrim(recipe->>'title'), nullif(btrim(recipe->>'description'), ''),
          nullif(recipe->>'servings', '')::int, nullif(recipe->>'prep_min', '')::int,
          nullif(recipe->>'cook_min', '')::int, recipe->'steps',
          recipe->'macros_per_serving', recipe->'macros_total',
          coalesce(recipe->>'source', 'ai'), recipe->>'model_version')
  returning id into new_id;

  -- pantry_item_id isn't stored: pantry items change (F3.1).
  for ing in select * from jsonb_array_elements(recipe->'ingredients') loop
    if coalesce(btrim(ing->>'name'), '') = '' then
      raise exception 'every ingredient needs a name' using errcode = '22023';
    end if;
    insert into app.recipe_ingredients (recipe_id, position, ingredient_id, name, quantity, unit, grams, note, is_optional)
    values (new_id, pos, nullif(ing->>'ingredient_id', '')::bigint, btrim(ing->>'name'),
            nullif(ing->>'quantity', '')::numeric, nullif(ing->>'unit', ''),
            nullif(ing->>'grams', '')::numeric, nullif(btrim(ing->>'note'), ''),
            coalesce((ing->>'is_optional')::boolean, false));
    pos := pos + 1;
  end loop;
  return new_id;
end;
$$;

revoke execute on function app.save_recipe(jsonb) from public, anon;
grant execute on function app.save_recipe(jsonb) to authenticated;
