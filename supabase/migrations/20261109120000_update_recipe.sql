-- F3.2: edit a saved recipe. Replaces the scalar fields and every ingredient row in one
-- transaction. AI and shared recipes become 'edited'; manual ones stay 'manual'. Macros are
-- recalculated afterwards by recompute-macros (F2.3). Security invoker: RLS = own recipes only.

create function app.update_recipe(p_id uuid, recipe jsonb)
returns void
language plpgsql
volatile
set search_path = ''
as $$
declare
  ing jsonb;
  pos int := 0;
  v_title text := btrim(coalesce(recipe->>'title', ''));
  descr text := nullif(btrim(coalesce(recipe->>'description', '')), '');
  n int;
begin
  if v_title = '' or length(v_title) > 80 then
    raise exception 'title must be 1-80 characters' using errcode = '22023';
  end if;
  if length(coalesce(descr, '')) > 300 then
    raise exception 'description must be at most 300 characters' using errcode = '22023';
  end if;
  if coalesce((recipe->>'servings')::int, 0) not between 1 and 12 then
    raise exception 'servings must be 1-12' using errcode = '22023';
  end if;
  if coalesce((recipe->>'prep_min')::int, 0) not between 0 and 600
     or coalesce((recipe->>'cook_min')::int, 0) not between 0 and 600 then
    raise exception 'times must be 0-600 minutes' using errcode = '22023';
  end if;
  if jsonb_typeof(recipe->'ingredients') <> 'array' or jsonb_array_length(recipe->'ingredients') = 0
     or jsonb_array_length(recipe->'ingredients') > 100 then
    raise exception 'a recipe needs 1-100 ingredients' using errcode = '22023';
  end if;
  if jsonb_typeof(recipe->'steps') <> 'array' or jsonb_array_length(recipe->'steps') = 0
     or jsonb_array_length(recipe->'steps') > 100
     or exists (select 1 from jsonb_array_elements_text(recipe->'steps') s where btrim(s) = '') then
    raise exception 'a recipe needs 1-100 steps, none empty' using errcode = '22023';
  end if;

  update app.recipes r
     set title = v_title,
         description = descr,
         servings = (recipe->>'servings')::int,
         prep_min = nullif(recipe->>'prep_min', '')::int,
         cook_min = nullif(recipe->>'cook_min', '')::int,
         steps = (select coalesce(jsonb_agg(btrim(s)), '[]'::jsonb) from jsonb_array_elements_text(recipe->'steps') s),
         source = case when r.source in ('ai', 'shared') then 'edited' else r.source end
   where r.id = p_id and r.deleted_at is null;
  get diagnostics n = row_count;
  if n <> 1 then
    raise exception 'recipe not found' using errcode = 'P0002';
  end if;

  delete from app.recipe_ingredients where recipe_id = p_id;
  for ing in select * from jsonb_array_elements(recipe->'ingredients') loop
    if coalesce(btrim(ing->>'name'), '') = '' then
      raise exception 'every ingredient needs a name' using errcode = '22023';
    end if;
    insert into app.recipe_ingredients (recipe_id, position, ingredient_id, name, quantity, unit, grams, note, is_optional)
    values (p_id, pos, nullif(ing->>'ingredient_id', '')::bigint, btrim(ing->>'name'),
            nullif(ing->>'quantity', '')::numeric, nullif(ing->>'unit', ''),
            nullif(ing->>'grams', '')::numeric, nullif(btrim(ing->>'note'), ''),
            coalesce((ing->>'is_optional')::boolean, false));
    pos := pos + 1;
  end loop;
end;
$$;

revoke execute on function app.update_recipe(uuid, jsonb) from public, anon;
grant execute on function app.update_recipe(uuid, jsonb) to authenticated;
